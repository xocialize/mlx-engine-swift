/// Canonical instruction-driven image editing surface (contract 1.2.0). Canonical
/// output is one **Image** artifact (`IEditResponse.image`), serialized round-trip
/// form (C3).
///
/// Designed multi-image first: `images` carries one or more conditioning inputs
/// (Qwen-Image-Edit-2511's headline feature is multi-image fusion — "put the person
/// from Picture 1 into the scene of Picture 2"). Single-image editing passes one
/// element. Output dimensions derive from the (last) input image's aspect ratio
/// unless width/height pin them; package-specific levers ride `metaData` (C5).

/// Canonical image-edit request.
public struct IEditRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .imageEdit }

    /// Conditioning input image(s), in prompt order ("Picture 1", "Picture 2", …).
    public let images: [Image]
    /// The edit instruction.
    public let prompt: String
    public let negativePrompt: String?
    public let width: Int?
    public let height: Int?
    public let steps: Int?
    /// True-CFG scale (classifier-free guidance over the edit instruction).
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

    public init(images: [Image],
                prompt: String,
                negativePrompt: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                adapters: [AdapterRef] = [],
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.images = images
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.adapters = adapters
        self.mode = mode
        self.metaData = metaData
    }
}

extension IEditRequest: AdapterCarrying {
    public func resolving(_ resolved: [ResolvedAdapter]) -> IEditRequest {
        var copy = self
        copy.resolvedAdapters = resolved
        return copy
    }
}

/// Canonical image-edit response — one `Image` artifact.
public struct IEditResponse: CapabilityResponse, Codable {
    public let image: Image
    public init(image: Image) { self.image = image }
}

/// Canonical descriptor shape for an image-edit tool (C11).
public enum IEditContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageEdit,
            summary: summary,
            parameters: [
                ParameterSchema(name: "images", kind: .string, required: true,
                                summary: "Conditioning input image(s), in prompt order."),
                ParameterSchema(name: "prompt", kind: .string, required: true,
                                summary: "The edit instruction."),
                ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                                summary: "What to steer away from."),
                ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
                ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
                ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false,
                                summary: "True-CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false,
                                summary: "RNG seed for reproducibility."),
            ],
            supportedModes: modes
        )
    }
}
