/// A minimal, introspectable parameter schema so MCPBridge can describe a tool without
/// reverse-engineering it (C11).
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

    public init(name: String,
                capability: Capability,
                summary: String,
                parameters: [ParameterSchema] = [],
                supportedModes: [Mode] = []) {
        self.name = name
        self.capability = capability
        self.summary = summary
        self.parameters = parameters
        self.supportedModes = supportedModes
    }
}
