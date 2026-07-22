/// A minimal, introspectable parameter schema so MCPBridge can describe a tool without
/// reverse-engineering it (C11).
///
/// **Deliberately an MCP-*like* subset, not JSON Schema** (decided 2026-07-22; C11 asserts
/// introspectability, not wire compatibility). Missing versus JSON Schema: value constraints
/// (`minimum`/`maximum`/`enum`/`default`), `properties`/`items` for the `object`/`array` kinds, and
/// a declared JSON encoding for the binary kinds (`image`/`audio`/`video`/`mesh`). Closing that gap
/// is **purely additive** — optional fields on this type plus a serializer — so it is left to
/// **integration time**, when a real non-LLM MCP consumer exists to settle the binary-encoding
/// convention rather than us guessing it. See `EngineeringDocs/MLXEngineDocs/
/// mcp-wire-fidelity-spike.md` for the per-surface gap list and ordering.
public struct ParameterSchema: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case string
        case integer
        case number
        case boolean
        case image
        case audio
        case video
        case object
        case array
        /// A 3D mesh input (GLB bytes). First used by `meshRig` (contract 1.19.0) — the first
        /// capability whose INPUT is a mesh (`imageTo3D` only OUTPUTs one, from an image input).
        case mesh
    }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let summary: String?

    public init(name: String, kind: Kind, required: Bool, summary: String? = nil) {
        self.name = name
        self.kind = kind
        self.required = required
        self.summary = summary
    }
}

/// Self-description a package publishes so the registry and MCPBridge can expose the tool
/// as a discrete, introspectable, intent-named surface (capability-as-tool).
public struct ToolDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let capability: Capability
    public let summary: String
    public let parameters: [ParameterSchema]
    public let supportedModes: [Mode]
    /// Minimum quantization this **surface** is usable at (contract 1.23.0, additive).
    ///
    /// Quant gating is otherwise per-package, but a model can be int4-fine for analysis and
    /// int4-bad for generation — the same weights, different quality floors per surface. Declaring
    /// a floor here lets a configuration below it stop backing *this* capability while still
    /// backing the package's other surfaces (the engine's `register` skips it and
    /// `admissibility(for:configuration:capability:)` reports
    /// `.quantBelowSurfaceFloor`). `nil` = no per-surface constraint, which is every existing
    /// conformer.
    public let quantFloor: Quant?

    public init(name: String,
                capability: Capability,
                summary: String,
                parameters: [ParameterSchema] = [],
                supportedModes: [Mode] = [],
                quantFloor: Quant? = nil) {
        self.name = name
        self.capability = capability
        self.summary = summary
        self.parameters = parameters
        self.supportedModes = supportedModes
        self.quantFloor = quantFloor
    }
}
