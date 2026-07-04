import Foundation

/// Canonical **text-embedding** surface (contract 1.15.0). Canonical output is the vectors on the
/// response (`EmbedResponse.vectors`) — the `imageQualityScore` non-Artifact precedent; there is no
/// routed vector artifact.
///
/// Batch-first (`texts`; one text = `[text]`), order-preserving. Asymmetric retrieval rides
/// `inputType`: `.query` texts receive the model's instruction prefix (overridable via
/// `instruction`), `.document` texts are embedded verbatim — embed queries and stored documents
/// with the matching side or retrieval quality silently degrades. Optional Matryoshka `dimensions`
/// truncates the raw pooled vector **before** L2-normalization (nil = the model's native width) so
/// a consumer can shrink its index without re-embedding at a different model. Introduced by
/// Qwen3-Embedding-0.6B. (Distinct from `llm` — deterministic text → vector encoding, no
/// generation; package-specific levers ride `metaData` (C5).)
public struct EmbedRequest: CapabilityRequest {
    public static var capability: Capability { .embed }

    /// Which side of asymmetric retrieval a batch is embedded for.
    public enum InputType: String, Sendable, Codable {
        /// Query-side: the text is prefixed with a task instruction before encoding.
        case query
        /// Document-side: the stored text is encoded verbatim (no instruction).
        case document
    }

    /// The texts to embed. Batch-first; the response's `vectors` preserve this order.
    public let texts: [String]
    /// Query-side vs stored-document-side (asymmetric retrieval). Defaults to `.document`.
    public let inputType: InputType
    /// Optional task instruction applied to `.query` texts. `nil` = the model's default retrieval
    /// instruction. Ignored for `.document` (documents are never instruction-prefixed).
    public let instruction: String?
    /// Optional Matryoshka truncation width, applied before L2-normalization. `nil` = native.
    public let dimensions: Int?
    public let mode: Mode?
    public let metaData: MetaData

    public init(texts: [String],
                inputType: InputType = .document,
                instruction: String? = nil,
                dimensions: Int? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.texts = texts
        self.inputType = inputType
        self.instruction = instruction
        self.dimensions = dimensions
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical embed response — one dense vector per input text, order-preserving.
///
/// Carries index-safety provenance: an index must never mix models or dimensions, so every batch
/// is stamped with the `modelID` and `dimension` that produced it (consumers persist both next to
/// the stored vectors and treat a mismatch as "re-embed", never "compare anyway").
public struct EmbedResponse: CapabilityResponse {
    /// One vector per input text, in request order.
    public let vectors: [[Float]]
    /// The produced width (post-Matryoshka; equals the model's native width when the request's
    /// `dimensions` was nil).
    public let dimension: Int
    /// `true` = each vector is L2-normalized (dot product == cosine similarity).
    public let normalized: Bool
    /// Provenance of the producing model (e.g. the weights repo id).
    public let modelID: String

    public init(vectors: [[Float]], dimension: Int, normalized: Bool, modelID: String) {
        self.vectors = vectors
        self.dimension = dimension
        self.normalized = normalized
        self.modelID = modelID
    }
}

/// The canonical descriptor shape for an embedding tool (C11). A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum EmbedContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .embed,
            summary: summary,
            parameters: [
                ParameterSchema(name: "texts", kind: .array, required: true,
                                summary: "The texts to embed (order preserved in the response)."),
                ParameterSchema(name: "inputType", kind: .string, required: false,
                                summary: "query (instruction-prefixed) or document (verbatim); default document."),
                ParameterSchema(name: "instruction", kind: .string, required: false,
                                summary: "Task instruction for query-side texts; nil = model default."),
                ParameterSchema(name: "dimensions", kind: .integer, required: false,
                                summary: "Matryoshka truncation width (pre-normalization); nil = native."),
            ],
            supportedModes: modes
        )
    }
}
