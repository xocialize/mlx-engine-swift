/// Canonical image- and video-analysis surfaces (VLM-style "look at this and answer").
/// Canonical output is **structured text** — a `String` that may carry structure (e.g. JSON
/// the caller asked for). V1 keeps it `String`-typed; a typed structured form is an additive
/// V2 concern behind the same surface.
///
/// These are two distinct capabilities (distinct input artifact: `Image` vs `Video`), so a
/// package that does both registers **two** surfaces (C1) against its one loaded model.

// MARK: Image analysis

public struct ImageAnalysisRequest: CapabilityRequest {
    public static var capability: Capability { .imageAnalysis }

    public let image: Image
    /// The instruction / question about the image.
    public let prompt: String
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, prompt: String, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.prompt = prompt
        self.mode = mode
        self.metaData = metaData
    }
}

public struct ImageAnalysisResponse: CapabilityResponse {
    /// Structured text (plain prose, or JSON/markdown if the prompt asked for it).
    public let text: String
    public init(text: String) { self.text = text }
}

// MARK: Video analysis

public struct VideoAnalysisRequest: CapabilityRequest {
    public static var capability: Capability { .videoAnalysis }

    public let video: Video
    public let prompt: String
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video, prompt: String, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.video = video
        self.prompt = prompt
        self.mode = mode
        self.metaData = metaData
    }
}

public struct VideoAnalysisResponse: CapabilityResponse {
    public let text: String
    public init(text: String) { self.text = text }
}

// MARK: Descriptors (C11)

public enum ImageAnalysisContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageAnalysis,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true, summary: "The image to analyze."),
                ParameterSchema(name: "prompt", kind: .string, required: true, summary: "Instruction / question."),
            ],
            supportedModes: modes
        )
    }
}

public enum VideoAnalysisContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .videoAnalysis,
            summary: summary,
            parameters: [
                ParameterSchema(name: "video", kind: .video, required: true, summary: "The video to analyze."),
                ParameterSchema(name: "prompt", kind: .string, required: true, summary: "Instruction / question."),
            ],
            supportedModes: modes
        )
    }
}
