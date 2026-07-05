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

/// Opt-in structured output: constrains decoding so the response is machine-parseable by
/// construction instead of "beg the model and regex the result" (contract 1.16.0, ENGINE-NEEDS
/// N6). A request-level knob, NOT a capability — canonical output stays text; the constraint
/// only narrows what that text can be.
///
/// `nil` (the default everywhere) is today's freeform generation — all existing consumers are
/// byte-for-byte unchanged.
///
/// A package that does not implement constrained decoding MUST reject a non-nil
/// `responseFormat` with `PackageError.unsupportedRequestFeature` — silently ignoring it and
/// returning freeform text is a contract violation (the caller was promised parseable output).
/// Packages that support it advertise via the `responseFormat` parameter in their surface
/// descriptor (`LLMContract.descriptor(... supportsStructuredOutput: true)`, C11).
public enum ResponseFormat: Sendable, Codable, Equatable {
    /// The top-level JSON value shape the caller expects. A hint the decoder enforces from the
    /// first non-whitespace token: `.object` requires `{`, `.array` requires `[`, `.any`
    /// accepts any single JSON value (object, array, string, number, boolean, null).
    public enum Container: String, Sendable, Codable {
        case any, object, array
    }

    /// Grammar-constrained, syntactically valid JSON: exactly one complete top-level value,
    /// then generation stops. Guarantees *syntax*, not schema — field names/types are still
    /// prompt-steered.
    case json(container: Container)

    /// Schema-guided JSON (a JSON Schema document, serialized). Lane-ready in 1.16.0:
    /// V1 packages MAY satisfy it as best-effort — enforce `.json` syntax with the container
    /// inferred from the schema root `"type"`, steering the rest by prompt. A package that
    /// enforces the full schema simply does better under the same case; consumers get at
    /// minimum valid JSON either way. Do not reject `.jsonSchema` if `.json` is supported.
    case jsonSchema(String)

    /// Convenience: valid JSON of any top-level shape.
    public static let json = ResponseFormat.json(container: .any)
}

/// Canonical LLM request. Output is always text.
public struct LLMRequest: CapabilityRequest {
    public static var capability: Capability { .llm }

    public let messages: [ChatMessage]
    public let parameters: LLMParameters
    public let mode: Mode?
    /// Opt-in structured output (contract 1.16.0). `nil` = freeform text (unchanged behavior).
    public let responseFormat: ResponseFormat?
    public let metaData: MetaData

    public init(messages: [ChatMessage],
                parameters: LLMParameters = LLMParameters(),
                mode: Mode? = nil,
                responseFormat: ResponseFormat? = nil,
                metaData: MetaData = [:]) {
        self.messages = messages
        self.parameters = parameters
        self.mode = mode
        self.responseFormat = responseFormat
        self.metaData = metaData
    }

    /// Convenience for a single user turn.
    public init(prompt: String,
                parameters: LLMParameters = LLMParameters(),
                mode: Mode? = nil,
                responseFormat: ResponseFormat? = nil,
                metaData: MetaData = [:]) {
        self.init(messages: [ChatMessage(role: .user, content: prompt)],
                  parameters: parameters, mode: mode,
                  responseFormat: responseFormat, metaData: metaData)
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
/// **deferred to Apple's FoundationModels** (`Tool` / `@Generable` / `GenerationSchema`), held
/// behind the `LanguageModelExecutor` boundary — not hand-rolled here, and FoundationModels types
/// never leak into this base surface, so a consumer that ignores them still gets canonical text.
public enum LLMContract {
    /// `supportsStructuredOutput: true` advertises constrained decoding by including the
    /// `responseFormat` parameter in the descriptor (C11) — the honest-manifest signal a
    /// router checks before sending a `responseFormat` request. Defaulted `false` so existing
    /// descriptors are unchanged (1.16.0, additive).
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  supportsStructuredOutput: Bool = false) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "messages", kind: .array, required: true,
                            summary: "Chat messages (role + content). A bare prompt is one user turn."),
            ParameterSchema(name: "parameters", kind: .object, required: false,
                            summary: "Canonical sampling: temperature, topP, maxTokens, stop."),
        ]
        if supportsStructuredOutput {
            parameters.append(
                ParameterSchema(name: "responseFormat", kind: .object, required: false,
                                summary: "Structured output: json (grammar-constrained, container hint object/array/any) or jsonSchema (best-effort). Omit for freeform text."))
        }
        return ToolDescriptor(
            name: name,
            capability: .llm,
            summary: summary,
            parameters: parameters,
            supportedModes: modes
        )
    }
}
