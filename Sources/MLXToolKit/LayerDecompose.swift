import Foundation

/// Canonical **layer-decomposition** request (contract 1.48.0): one flattened design image → an ordered
/// stack of RGBA layers that composites back to it. Introduced by Ming-Image-0.1-Design-Layer
/// (ming-image-swift, AB-T-0181), whose Swift path is parity-gated end to end.
///
/// The per-layer **spec** is canonical, not `metaData`: decomposition models are driven by an explicit
/// plan ("Decompose this image into 4 layers … Layer 1: the headline text …"), and a model without a
/// spec input still honours `layerCount`. Writing a precise spec from a rough plan is a VLM job — a host
/// composes it (e.g. `imageAnalysis` → `layerDecompose`); it is not this surface's.
public struct LayerDecomposeRequest: CapabilityRequest {
    public static var capability: Capability { .layerDecompose }

    /// The flattened design to decompose (RGB or RGBA; alpha, if any, is the package's to interpret).
    public let image: Image
    /// The per-layer specification, free text. nil = the package's default request for `layerCount` layers.
    public let spec: String?
    /// Layers to produce, excluding any composite. nil = the package default, or the count the spec states;
    /// a package that parses a count out of `spec` must not contradict an explicit `layerCount`.
    public let layerCount: Int?
    /// Working-resolution hint (long-side class, pixels). Packages snap it to what they support (Ming:
    /// the 512 | 1024 buckets); the returned layers' dimensions are authoritative.
    public let resolution: Int?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image,
                spec: String? = nil,
                layerCount: Int? = nil,
                resolution: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.image = image
        self.spec = spec
        self.layerCount = layerCount
        self.resolution = resolution
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical layer-decomposition response.
///
/// - `layers[0]` is the **front-most** layer and the last is the background: compositing back to front
///   (`layers.reversed()`, straight-alpha "over") reproduces the design.
/// - Every layer is an RGBA PNG with **straight (un-premultiplied) alpha**, all at the same dimensions —
///   the input's aspect ratio; the package may work at a smaller bucket.
/// - `composite` is the model's own full-canvas frame when it produces one (Ming emits it as a leading
///   frame) — useful as a recomposition check, never needed to rebuild the stack. nil when not produced.
public struct LayerDecomposeResponse: CapabilityResponse {
    public let layers: [Image]
    public let composite: Image?

    public init(layers: [Image], composite: Image? = nil) {
        self.layers = layers
        self.composite = composite
    }
}

/// Canonical descriptor shape for a layer-decomposition tool (C11).
public enum LayerDecomposeContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .layerDecompose,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The flattened design to decompose."),
                ParameterSchema(name: "spec", kind: .string, required: false,
                                summary: "Per-layer specification (front-most first). Omit for the package default."),
                ParameterSchema(name: "layerCount", kind: .integer, required: false,
                                summary: "Layers to produce, excluding the composite."),
                ParameterSchema(name: "resolution", kind: .integer, required: false,
                                summary: "Working-resolution hint (long-side class, px); snapped to the package's buckets."),
                ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false, summary: "RNG seed for reproducibility."),
            ],
            supportedModes: modes
        )
    }
}
