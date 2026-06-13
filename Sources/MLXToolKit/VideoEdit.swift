/// Canonical instruction-driven **video** editing surface (contract 1.3.0). Canonical
/// output is one **Video** artifact (`VEditResponse.video`), serialized round-trip form (C3).
///
/// A source `video` is edited toward `prompt`; optional `referenceImages` steer the result
/// toward reference subject(s) (Bernini-R's rv2v — "edit this clip so the character looks like
/// these references"). v2v = source video + prompt; rv2v = source video + prompt + references.
/// (Reference-conditioned *generation* with no source video is `textToVideo` +
/// `referenceImages`, not this surface.) Package-specific levers ride `metaData` (C5).
public struct VEditRequest: CapabilityRequest {
    public static var capability: Capability { .videoEdit }

    /// The source video to edit.
    public let video: Video
    /// The edit instruction.
    public let prompt: String
    /// Optional reference image(s) steering the edit toward their subject(s) (rv2v).
    public let referenceImages: [Image]?
    public let negativePrompt: String?
    public let width: Int?
    public let height: Int?
    public let numFrames: Int?
    public let fps: Double?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video,
                prompt: String,
                referenceImages: [Image]? = nil,
                negativePrompt: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                numFrames: Int? = nil,
                fps: Double? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.video = video
        self.prompt = prompt
        self.referenceImages = referenceImages
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.numFrames = numFrames
        self.fps = fps
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical video-edit response — one `Video` artifact.
public struct VEditResponse: CapabilityResponse {
    public let video: Video
    public init(video: Video) { self.video = video }
}

/// Canonical descriptor shape for a video-edit tool (C11).
public enum VEditContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .videoEdit,
            summary: summary,
            parameters: [
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
            ],
            supportedModes: modes
        )
    }
}
