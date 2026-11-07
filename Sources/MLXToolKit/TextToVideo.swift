/// Canonical text-to-video (T2V) surface. Canonical output is a **Video** artifact
/// (`T2VResponse.video`), serialized round-trip form (C3).
///
/// T2V optionally accepts an **input `Image`** (image-to-video) — a canonical artifact in,
/// canonical artifact out, which is exactly what lets a T2I→T2V pipeline compose: the T2I
/// `Image` output drops straight into `initImage` here (architecture §7). Since contract 1.40.0
/// it also accepts an **input `Audio`** (audio-to-video, `initAudio`) — the same composition
/// seam for a TTS or sound-generation output, gated by `T2VControls` (see below).

/// Canonical T2V request.
public struct T2VRequest: CapabilityRequest, Codable {
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
    /// Images pinned to frames of the output, replacing the `metaData` file-path route (LTX's
    /// `kf.keyframes`): `[{image, frame, strength?}]`. Contract 1.61.0 (AB-A-0236). The final frame is
    /// the keyframe at `frame == -1` (`VideoKeyframe.last`). **Declaration-gated** — an ignored
    /// keyframe yields a clip that never reaches the frame pinned — through
    /// `T2VControls.keyframes`; empty = none, which is every pre-1.61 request.
    public let keyframes: [VideoKeyframe]
    /// Whether the output carries a soundtrack (contract 1.61.0): `true` = include, `false` = a
    /// silent clip, nil = the package's default (LTX muxes its audio today). Declaration-gated
    /// through `T2VControls.audioOutput` — see `VideoAudioOutput` for what each declaration refuses.
    public let includeAudio: Bool?
    public let numFrames: Int?
    public let fps: Double?
    public let width: Int?
    public let height: Int?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    /// Adapters (LoRA) to apply, by catalog id (contract 1.53.0). Admitted only on a surface
    /// declaring `ToolDescriptor.adapters`; the engine resolves them into `resolvedAdapters`.
    public let adapters: [AdapterRef]
    /// The engine-resolved form of `adapters`, in the same order — what a package reads
    /// (contract 1.53.0). Stamped by the engine before every run; see `AdapterCarrying`.
    public private(set) var resolvedAdapters: [ResolvedAdapter] = []
    public let mode: Mode?
    public let metaData: MetaData

    public init(prompt: String,
                negativePrompt: String? = nil,
                initImage: Image? = nil,
                referenceImages: [Image]? = nil,
                initAudio: Audio? = nil,
                keyframes: [VideoKeyframe] = [],
                includeAudio: Bool? = nil,
                numFrames: Int? = nil,
                fps: Double? = nil,
                width: Int? = nil,
                height: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                adapters: [AdapterRef] = [],
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.initImage = initImage
        self.referenceImages = referenceImages
        self.initAudio = initAudio
        self.keyframes = keyframes
        self.includeAudio = includeAudio
        self.numFrames = numFrames
        self.fps = fps
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.adapters = adapters
        self.mode = mode
        self.metaData = metaData
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, negativePrompt, initImage, referenceImages, initAudio, keyframes, includeAudio
        case numFrames, fps, width, height, steps, guidanceScale, seed
        case adapters, resolvedAdapters, mode, metaData
    }

    /// Tolerant of every earlier shape (contract 1.61.0): the keys added at 1.40 / 1.53 / 1.61
    /// default when absent, so a request encoded by an older host decodes unchanged.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt)
        initImage = try c.decodeIfPresent(Image.self, forKey: .initImage)
        referenceImages = try c.decodeIfPresent([Image].self, forKey: .referenceImages)
        initAudio = try c.decodeIfPresent(Audio.self, forKey: .initAudio)
        keyframes = try c.decodeIfPresent([VideoKeyframe].self, forKey: .keyframes) ?? []
        includeAudio = try c.decodeIfPresent(Bool.self, forKey: .includeAudio)
        numFrames = try c.decodeIfPresent(Int.self, forKey: .numFrames)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        guidanceScale = try c.decodeIfPresent(Double.self, forKey: .guidanceScale)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        adapters = try c.decodeIfPresent([AdapterRef].self, forKey: .adapters) ?? []
        resolvedAdapters = try c.decodeIfPresent([ResolvedAdapter].self, forKey: .resolvedAdapters) ?? []
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode)
        metaData = try c.decodeIfPresent(MetaData.self, forKey: .metaData) ?? [:]
    }
}

extension T2VRequest: AdapterCarrying {
    public func resolving(_ resolved: [ResolvedAdapter]) -> T2VRequest {
        var copy = self
        copy.resolvedAdapters = resolved
        return copy
    }
}

/// Canonical T2V response — one `Video` artifact.
public struct T2VResponse: CapabilityResponse, Codable {
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
    /// The keyframes the surface honors (contract 1.61.0, AB-A-0236). nil = `T2VRequest.keyframes` is
    /// refused by the engine pre-flight (`refusal(for:)`).
    public let keyframes: VideoKeyframeSupport?
    /// Whether the surface returns a soundtrack and whether `T2VRequest.includeAudio` switches it
    /// (contract 1.61.0). nil = undeclared: `includeAudio` is refused. See `VideoAudioOutput`.
    public let audioOutput: VideoAudioOutput?
    /// The package emits `RunPreviewFrame`s (a decoded stage-one frame) while it runs — see
    /// `RunProgress.reportPreview`. OUTPUT-side: it tells a host to render a preview. Nothing to
    /// refuse. Contract 1.61.0.
    public let emitsFramePreviews: Bool

    public init(supportsInitAudio: Bool = false,
                keyframes: VideoKeyframeSupport? = nil,
                audioOutput: VideoAudioOutput? = nil,
                emitsFramePreviews: Bool = false) {
        self.supportsInitAudio = supportsInitAudio
        self.keyframes = keyframes
        self.audioOutput = audioOutput
        self.emitsFramePreviews = emitsFramePreviews
    }

    private enum CodingKeys: String, CodingKey {
        case supportsInitAudio, keyframes, audioOutput, emitsFramePreviews
    }

    /// Pre-1.61 descriptor JSON carries only `supportsInitAudio`; the rest default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportsInitAudio = try c.decodeIfPresent(Bool.self, forKey: .supportsInitAudio) ?? false
        keyframes = try c.decodeIfPresent(VideoKeyframeSupport.self, forKey: .keyframes)
        audioOutput = try c.decodeIfPresent(VideoAudioOutput.self, forKey: .audioOutput)
        emitsFramePreviews = try c.decodeIfPresent(Bool.self, forKey: .emitsFramePreviews) ?? false
    }

    /// Internal inconsistencies of the declaration; empty for a coherent one.
    public var declarationProblems: [String] {
        var problems: [String] = []
        if let keyframes {
            if keyframes.maxCount < 1 { problems.append("keyframes.maxCount must be at least 1") }
            if keyframes.placement == .endpoints, keyframes.maxCount > 2 {
                problems.append("an endpoints keyframe surface takes at most 2 keyframes")
            }
        }
        return problems
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
        // Keyframes and the audio switch (contract 1.61.0) are advertised only when DECLARED, by the
        // same rule — an `includeAudio` toggle is offered only on a `.switchable` surface (a silent
        // or always-muxed one has nothing to switch).
        if let support = controls?.keyframes {
            parameters.append(ParameterSchema(
                name: "keyframes", kind: .array, required: false,
                summary: "Images pinned to frames, each {image, frame, strength?}; up to \(support.maxCount), "
                    + (support.placement == .endpoints
                        ? "first (frame 0) and last (frame -1) only"
                        : "any frame (a negative index counts from the end; -1 is the last)")
                    + (support.supportsStrength ? "; strength 0…1." : ".")))
        }
        if controls?.audioOutput == .switchable {
            parameters.append(ParameterSchema(
                name: "includeAudio", kind: .boolean, required: false,
                summary: "Include the generated soundtrack in the output (false = a silent clip)."))
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
