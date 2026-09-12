/// Canonical text-to-video (T2V) surface. Canonical output is a **Video** artifact
/// (`T2VResponse.video`), serialized round-trip form (C3).
///
/// T2V optionally accepts an **input `Image`** (image-to-video) — a canonical artifact in,
/// canonical artifact out, which is exactly what lets a T2I→T2V pipeline compose: the T2I
/// `Image` output drops straight into `initImage` here (architecture §7). Since contract 1.40.0
/// it also accepts an **input `Audio`** (audio-to-video, `initAudio`) — the same composition
/// seam for a TTS or sound-generation output, gated by `T2VControls` (see below).

/// Canonical T2V request.
public struct T2VRequest: CapabilityRequest {
    public static var capability: Capability { .textToVideo }

    public let prompt: String
    public let negativePrompt: String?
    /// Optional first-frame / conditioning image (image-to-video). Canonical `Image` artifact.
    public let initImage: Image?
    /// Optional reference image(s) for **subject-consistent generation** (reference-to-video,
    /// r2v): generate a new video of these subject(s) following `prompt`. Distinct from
    /// `initImage` (a first frame) — references condition *identity*, not the opening frame.
    /// Contract 1.3.0; introduced by Bernini-R. Packages that don't support it ignore it.
    public let referenceImages: [Image]?
    /// Optional driving audio (**audio-to-video**, a2v): the whole clip is generated *against*
    /// this track — music, ambience, speech, anything — and the track comes back untouched in
    /// the output container. Contract 1.40.0 (AB-A-0023); introduced by LTX-2.5.
    ///
    /// **Declaration-gated, unlike `initImage` / `referenceImages`** — the implementer's own
    /// verdict (mlx-ltx, AB-A-0066). Those two degrade when ignored (a worse video); a silently
    /// ignored `initAudio` returns a video *unrelated to the track supplied*, which is wrong
    /// output a caller cannot detect from the result. So a package honors it only by declaring
    /// `T2VControls.supportsInitAudio`, and `MLXServeEngine.run` refuses it otherwise with
    /// `PackageError.unsupportedRequestFeature` (the `TTSRequest.targetDuration` rule, 1.38.0).
    /// Distinct from `talkingHead`, which regenerates a *source face's* mouth — a2v has no
    /// source video at all, which is also why it is not a `videoEdit` field.
    public let initAudio: Audio?
    public let numFrames: Int?
    public let fps: Double?
    public let width: Int?
    public let height: Int?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(prompt: String,
                negativePrompt: String? = nil,
                initImage: Image? = nil,
                referenceImages: [Image]? = nil,
                initAudio: Audio? = nil,
                numFrames: Int? = nil,
                fps: Double? = nil,
                width: Int? = nil,
                height: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.initImage = initImage
        self.referenceImages = referenceImages
        self.initAudio = initAudio
        self.numFrames = numFrames
        self.fps = fps
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical T2V response — one `Video` artifact.
public struct T2VResponse: CapabilityResponse {
    public let video: Video
    public init(video: Video) { self.video = video }
}

/// What a `textToVideo` surface honors natively beyond the ignorable conditioning inputs
/// (contract 1.40.0). Carried on `ToolDescriptor.controls` as `.textToVideo`, read through
/// `ToolDescriptor.t2vControls`; nil = every pre-1.40 conformer.
///
/// Earns its `SurfaceControls` case by the governing rule: a caller holding a soundtrack must
/// choose an a2v-capable package BEFORE running, and nothing in the response can tell it
/// afterwards whether the track was used.
public struct T2VControls: Sendable, Codable, Equatable {
    /// The surface generates video against `T2VRequest.initAudio` (a2v). `false` = the field is
    /// refused by the engine pre-flight, never silently dropped.
    public let supportsInitAudio: Bool

    public init(supportsInitAudio: Bool = false) {
        self.supportsInitAudio = supportsInitAudio
    }
}

/// Canonical descriptor shape for a T2V tool (C11).
public enum T2VContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: T2VControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "prompt", kind: .string, required: true,
                            summary: "The text prompt."),
            ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                            summary: "What to steer away from."),
            ParameterSchema(name: "initImage", kind: .image, required: false,
                            summary: "Optional conditioning image (image-to-video)."),
            ParameterSchema(name: "referenceImages", kind: .image, required: false,
                            summary: "Optional reference image(s) for subject-consistent generation (r2v)."),
            ParameterSchema(name: "numFrames", kind: .integer, required: false, summary: "Frame count."),
            ParameterSchema(name: "fps", kind: .number, required: false, summary: "Frames per second."),
            ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
            ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
            ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
            ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
            ParameterSchema(name: "seed", kind: .integer, required: false, summary: "RNG seed."),
        ]
        // `initAudio` is advertised only when DECLARED, so a planner is never offered a knob the
        // package would refuse (the `supportsStrength` / E12 precedent). One source of truth: the
        // schema entry is derived from the declaration, so the advertised parameters and
        // `t2vControls` cannot drift apart.
        if controls?.supportsInitAudio == true {
            parameters.insert(ParameterSchema(
                name: "initAudio", kind: .audio, required: false,
                summary: "Optional driving audio (audio-to-video): the clip is generated against "
                    + "this track, which is returned untouched in the output."), at: 4)
        }
        return ToolDescriptor(
            name: name,
            capability: .textToVideo,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map(SurfaceControls.textToVideo)
        )
    }
}
