/// Canonical text-to-image (T2I) surface. Canonical output is an **Image** artifact
/// (`T2IResponse.image`), serialized round-trip form (C3).
///
/// The fields here are the diffusion controls every T2I model understands — they are
/// canonical, not `metaData`. Scheduler choice, LoRA stacks, refiner passes and other
/// package-specific levers ride `metaData` (C5).

/// Canonical T2I request.
public struct T2IRequest: CapabilityRequest {
    public static var capability: Capability { .textToImage }

    public let prompt: String
    public let negativePrompt: String?
    public let width: Int?
    public let height: Int?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(prompt: String,
                negativePrompt: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical T2I response — one `Image` artifact.
public struct T2IResponse: CapabilityResponse {
    public let image: Image
    public init(image: Image) { self.image = image }
}

/// Canonical descriptor shape for a T2I tool (C11).
public enum T2IContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .textToImage,
            summary: summary,
            parameters: [
                ParameterSchema(name: "prompt", kind: .string, required: true,
                                summary: "The text prompt."),
                ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                                summary: "What to steer away from."),
                ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
                ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
                ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false, summary: "RNG seed for reproducibility."),
            ],
            supportedModes: modes
        )
    }
}
