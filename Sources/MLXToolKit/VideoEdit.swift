/// Canonical instruction-driven **video** editing surface (contract 1.3.0). Canonical
/// output is one **Video** artifact (`VEditResponse.video`), serialized round-trip form (C3).
///
/// A source `video` is edited toward `prompt`; optional `referenceImages` steer the result
/// toward reference subject(s) (Bernini-R's rv2v — "edit this clip so the character looks like
/// these references"). v2v = source video + prompt; rv2v = source video + prompt + references.
/// (Reference-conditioned *generation* with no source video is `textToVideo` +
/// `referenceImages`, not this surface.) Package-specific levers ride `metaData` (C5).
public struct VEditRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .videoEdit }

    /// The source video to edit.
    public let video: Video
    /// The edit instruction.
    public let prompt: String
    /// Optional reference image(s) steering the edit toward their subject(s) (rv2v).
    public let referenceImages: [Image]?
    /// Regenerate a stretch of the source and keep the rest (contract 1.61.0, AB-A-0236): the span,
    /// and which track (`VideoModality`). Replaces the `metaData` route (LTX's `retake.start` /
    /// `retake.duration`). **Declaration-gated** (`VEditControls.retakeModalities`) — an ignored span
    /// regenerates the whole clip. Mutually exclusive with `extend`.
    public let retake: VideoRetake?
    /// Grow the clip by a length, in a direction (contract 1.61.0): LTX's `extend.seconds`.
    /// **Declaration-gated** (`VEditControls.extendDirections`). Mutually exclusive with `retake`.
    public let extend: VideoExtend?
    public let negativePrompt: String?
    public let width: Int?
    public let height: Int?
    public let numFrames: Int?
    public let fps: Double?
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

    public init(video: Video,
                prompt: String,
                referenceImages: [Image]? = nil,
                retake: VideoRetake? = nil,
                extend: VideoExtend? = nil,
                negativePrompt: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                numFrames: Int? = nil,
                fps: Double? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                adapters: [AdapterRef] = [],
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.video = video
        self.prompt = prompt
        self.referenceImages = referenceImages
        self.retake = retake
        self.extend = extend
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.numFrames = numFrames
        self.fps = fps
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.adapters = adapters
        self.mode = mode
        self.metaData = metaData
    }

    private enum CodingKeys: String, CodingKey {
        case video, prompt, referenceImages, retake, extend, negativePrompt
        case width, height, numFrames, fps, steps, guidanceScale, seed
        case adapters, resolvedAdapters, mode, metaData
    }

    /// Tolerant of every earlier shape (contract 1.61.0): keys added at 1.53 / 1.61 default when absent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        video = try c.decode(Video.self, forKey: .video)
        prompt = try c.decode(String.self, forKey: .prompt)
        referenceImages = try c.decodeIfPresent([Image].self, forKey: .referenceImages)
        retake = try c.decodeIfPresent(VideoRetake.self, forKey: .retake)
        extend = try c.decodeIfPresent(VideoExtend.self, forKey: .extend)
        negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        numFrames = try c.decodeIfPresent(Int.self, forKey: .numFrames)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        guidanceScale = try c.decodeIfPresent(Double.self, forKey: .guidanceScale)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        adapters = try c.decodeIfPresent([AdapterRef].self, forKey: .adapters) ?? []
        resolvedAdapters = try c.decodeIfPresent([ResolvedAdapter].self, forKey: .resolvedAdapters) ?? []
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode)
        metaData = try c.decodeIfPresent(MetaData.self, forKey: .metaData) ?? [:]
    }
}

extension VEditRequest: AdapterCarrying {
    public func resolving(_ resolved: [ResolvedAdapter]) -> VEditRequest {
        var copy = self
        copy.resolvedAdapters = resolved
        return copy
    }
}

/// Canonical video-edit response — one `Video` artifact.
public struct VEditResponse: CapabilityResponse, Codable {
    public let video: Video
    public init(video: Video) { self.video = video }
}

/// Canonical descriptor shape for a video-edit tool (C11).
public enum VEditContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: VEditControls? = nil) -> ToolDescriptor {
        var parameters = [
                ParameterSchema(name: "video", kind: .video, required: true,
                                summary: "The source video to edit."),
                ParameterSchema(name: "prompt", kind: .string, required: true,
                                summary: "The edit instruction."),
                ParameterSchema(name: "referenceImages", kind: .image, required: false,
                                summary: "Optional reference image(s) to steer the edit's subject."),
                ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                                summary: "What to steer away from."),
                ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
                ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
                ParameterSchema(name: "numFrames", kind: .integer, required: false, summary: "Frame count."),
                ParameterSchema(name: "fps", kind: .number, required: false, summary: "Frames per second."),
                ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false,
                                summary: "RNG seed for reproducibility."),
        ]
        // Retake and extend (contract 1.61.0) are advertised only when DECLARED — a planner is never
        // offered a knob the engine would refuse.
        if let controls, controls.declaresRetake {
            parameters.append(ParameterSchema(
                name: "retake", kind: .object, required: false,
                summary: "Regenerate a stretch of the source, keep the rest: {span: {start, end, unit?}, "
                    + "modality?: " + controls.retakeModalities.map(\.rawValue).joined(separator: " / ")
                    + "}. Units: " + controls.spanUnits.map(\.rawValue).joined(separator: " / ") + "."))
        }
        if let controls, controls.declaresExtend {
            parameters.append(ParameterSchema(
                name: "extend", kind: .object, required: false,
                summary: "Grow the clip: {length, unit?, direction?: "
                    + controls.extendDirections.map(\.rawValue).joined(separator: " / ") + "}"
                    + (controls.maxExtendSeconds.map { " up to \(VEditControls.format($0)) s" } ?? "") + "."))
        }
        return ToolDescriptor(
            name: name,
            capability: .videoEdit,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map(SurfaceControls.videoEdit)
        )
    }
}
