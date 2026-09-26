/// Canonical text-to-image (T2I) surface. Canonical output is an **Image** artifact
/// (`T2IResponse.image`), serialized round-trip form (C3).
///
/// The fields here are the diffusion controls every T2I model understands — they are
/// canonical, not `metaData`. Scheduler choice, LoRA stacks, refiner passes and other
/// package-specific levers ride `metaData` (C5).

/// The requested background of a T2I image (contract 1.48.0).
///
/// `.transparent` asks for **native alpha**: the model generates the subject on a transparent canvas
/// and returns an RGBA PNG (straight alpha) whose alpha is the model's own output, not a post-hoc
/// matte. It is **declaration-gated** (`T2IControls.supportsTransparentBackground`): a surface that
/// ignored it would return an opaque image a caller then composites as a full-canvas rectangle —
/// wrong output, visible only by inspecting alpha — so the engine refuses it for undeclared surfaces.
/// `.opaque` is every model's behaviour and is never gated.
public enum T2IBackground: String, Sendable, Codable {
    case opaque
    case transparent
}

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
    /// Requested background (contract 1.48.0). nil = the model's default (opaque). `.transparent` is
    /// admitted only by a surface declaring `T2IControls.supportsTransparentBackground`.
    public let background: T2IBackground?
    public let mode: Mode?
    public let metaData: MetaData

    public init(prompt: String,
                negativePrompt: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                background: T2IBackground? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.background = background
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical T2I response — one `Image` artifact.
public struct T2IResponse: CapabilityResponse {
    public let image: Image
    public init(image: Image) { self.image = image }
}

/// Routing-time declaration for a `textToImage` surface (contract 1.48.0), carried on
/// `ToolDescriptor.controls` as `.textToImage`. Mirrors `T2VControls`: nil-by-default, and a
/// consumer reads it to choose a package BEFORE running one.
public struct T2IControls: Sendable, Codable, Equatable {
    /// The surface generates native alpha for `T2IRequest.background == .transparent`. `false` = the
    /// field is refused by the engine pre-flight, never silently dropped.
    public let supportsTransparentBackground: Bool

    public init(supportsTransparentBackground: Bool = false) {
        self.supportsTransparentBackground = supportsTransparentBackground
    }
}

/// Canonical descriptor shape for a T2I tool (C11).
public enum T2IContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: T2IControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "prompt", kind: .string, required: true,
                            summary: "The text prompt."),
            ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                            summary: "What to steer away from."),
            ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
            ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
            ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
            ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
            ParameterSchema(name: "seed", kind: .integer, required: false, summary: "RNG seed for reproducibility."),
        ]
        // Advertised ONLY when declared: an undeclared background is refused, so offering it would
        // describe a knob the surface does not have (1.48.0).
        if controls?.supportsTransparentBackground == true {
            parameters.append(ParameterSchema(
                name: "background", kind: .string, required: false,
                summary: "\"transparent\" = native RGBA alpha (straight); \"opaque\" = the default."))
        }
        return ToolDescriptor(
            name: name,
            capability: .textToImage,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map { .textToImage($0) }
        )
    }
}
