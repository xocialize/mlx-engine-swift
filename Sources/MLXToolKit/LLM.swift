/// Canonical LLM surface. Canonical output is **text** (`LLMResponse.text`).
///
/// One `llm` surface, never one-per-mode: `thinking` / `direct` / `companion` ride the
/// request as a `Mode` tag (C4), they are not separate tools. Sampling knobs that every LLM
/// understands (temperature, top-p, max tokens, stop) are **canonical** and live on the
/// request; anything genuinely package-specific (a bespoke sampler trick, a repetition-penalty
/// dialect) rides `metaData` (C5).

/// A chat turn. The canonical LLM input is a message list; a bare prompt is
/// `[ChatMessage(role: .user, content: ...)]`.
public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Canonical, universally-understood LLM sampling controls. Package-specific sampling extras
/// belong in `metaData`, not here.
public struct LLMParameters: Sendable, Codable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var stop: [String]

    public init(temperature: Double? = nil, topP: Double? = nil,
                maxTokens: Int? = nil, stop: [String] = []) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stop = stop
    }
}

/// Canonical LLM request. Output is always text.
public struct LLMRequest: CapabilityRequest {
    public static var capability: Capability { .llm }

    public let messages: [ChatMessage]
    public let parameters: LLMParameters
    public let mode: Mode?
    public let metaData: MetaData

    public init(messages: [ChatMessage],
                parameters: LLMParameters = LLMParameters(),
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.messages = messages
        self.parameters = parameters
        self.mode = mode
        self.metaData = metaData
    }

    /// Convenience for a single user turn.
    public init(prompt: String,
                parameters: LLMParameters = LLMParameters(),
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.init(messages: [ChatMessage(role: .user, content: prompt)],
                  parameters: parameters, mode: mode, metaData: metaData)
    }
}

/// Why generation stopped. Additive; consumers should `@unknown default`.
public enum FinishReason: String, Sendable, Codable {
    case stop          // natural end / stop sequence
    case length        // hit maxTokens
    case cancelled     // preempted (e.g. governor eviction)
}

/// Canonical LLM response. The canonical artifact is text.
public struct LLMResponse: CapabilityResponse {
    public let text: String
    public let finishReason: FinishReason?
    public init(text: String, finishReason: FinishReason? = nil) {
        self.text = text
        self.finishReason = finishReason
    }
}

/// Canonical descriptor shape for an LLM tool (C11). Tool-use / fill-in-middle / grounding are
/// **contracted named extensions** a specialty may add (architecture §2.3), not part of this
/// base surface — a consumer that ignores them still gets canonical text.
public enum LLMContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .llm,
            summary: summary,
            parameters: [
                ParameterSchema(name: "messages", kind: .array, required: true,
                                summary: "Chat messages (role + content). A bare prompt is one user turn."),
                ParameterSchema(name: "parameters", kind: .object, required: false,
                                summary: "Canonical sampling: temperature, topP, maxTokens, stop."),
            ],
            supportedModes: modes
        )
    }
}
