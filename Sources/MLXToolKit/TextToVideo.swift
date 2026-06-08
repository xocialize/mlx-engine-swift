/// Canonical text-to-video (T2V) surface. Canonical output is a **Video** artifact
/// (`T2VResponse.video`), serialized round-trip form (C3).
///
/// T2V optionally accepts an **input `Image`** (image-to-video) — a canonical artifact in,
/// canonical artifact out, which is exactly what lets a T2I→T2V pipeline compose: the T2I
/// `Image` output drops straight into `initImage` here (architecture §7).

/// Canonical T2V request.
public struct T2VRequest: CapabilityRequest {
    public static var capability: Capability { .textToVideo }

    public let prompt: String
    public let negativePrompt: String?
    /// Optional first-frame / conditioning image (image-to-video). Canonical `Image` artifact.
    public let initImage: Image?
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

/// Canonical descriptor shape for a T2V tool (C11).
public enum T2VContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .textToVideo,
            summary: summary,
            parameters: [
                ParameterSchema(name: "prompt", kind: .string, required: true,
                                summary: "The text prompt."),
                ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                                summary: "What to steer away from."),
                ParameterSchema(name: "initImage", kind: .image, required: false,
                                summary: "Optional conditioning image (image-to-video)."),
                ParameterSchema(name: "numFrames", kind: .integer, required: false, summary: "Frame count."),
                ParameterSchema(name: "fps", kind: .number, required: false, summary: "Frames per second."),
                ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
                ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
                ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false, summary: "RNG seed."),
            ],
            supportedModes: modes
        )
    }
}
