import Foundation

/// Canonical **late-interaction (multi-vector) embedding** surface (contract 1.32.0). Canonical
/// output is the per-token matrices on the response (`MultiVectorEmbedResponse.multiVectors`) —
/// the `embed` non-Artifact precedent; there is no routed artifact.
///
/// Batch-first (`texts`; one text = `[text]`), order-preserving. Asymmetric retrieval rides
/// `inputType`, and the two sides differ STRUCTURALLY (not just by prefix): `.query` texts are
/// encoded with the model's trained fixed-length expansion (expansion-token vectors are kept
/// and scored — that is the ColBERT query-augmentation mechanism), `.document` texts are
/// variable-length with the model's token filtering applied (e.g. a punctuation skiplist).
/// Embed queries and stored documents with the matching side or retrieval quality silently
/// degrades. Scoring is MaxSim (`MultiVectorEmbedContract.maxSim`), NOT cosine over pooled
/// vectors. (Distinct from `embed` — one dense vector per text; the two vector spaces are not
/// interchangeable. Package-specific levers ride `metaData` (C5).)
public struct MultiVectorEmbedRequest: CapabilityRequest {
    public static var capability: Capability { .multiVectorEmbed }

    /// Which side of asymmetric late-interaction retrieval a batch is encoded for.
    public enum InputType: String, Sendable, Codable {
        /// Query-side: trained prefix + fixed-length expansion; expansion vectors are scored.
        case query
        /// Document-side: trained prefix, variable length, model-side token filtering.
        case document
    }

    /// The texts to encode. Batch-first; the response's `multiVectors` preserve this order.
    public let texts: [String]
    /// Query-side vs stored-document-side. Defaults to `.document`.
    public let inputType: InputType
    public let mode: Mode?
    public let metaData: MetaData

    public init(texts: [String],
                inputType: InputType = .document,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.texts = texts
        self.inputType = inputType
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical multi-vector response — one per-token matrix per input text, order-preserving.
///
/// Carries index-safety provenance: an index must never mix models or dimensions, so every batch
/// is stamped with the `modelID` and `dimension` that produced it (consumers persist both next to
/// the stored matrices and treat a mismatch as "re-encode", never "compare anyway").
public struct MultiVectorEmbedResponse: CapabilityResponse {
    /// One matrix per input text, in request order: `[tokenVector][dimension]`. Query-side
    /// matrices have the model's fixed trained length (expansion included); document-side
    /// matrices have variable length (filtered tokens excluded). Row counts are NOT comparable
    /// across sides.
    public let multiVectors: [[[Float]]]
    /// The per-token vector width (the model's projection dim, e.g. 128).
    public let dimension: Int
    /// `true` = every token vector is L2-normalized (per-token dot == cosine).
    public let normalized: Bool
    /// Provenance of the producing model (e.g. the weights repo id).
    public let modelID: String

    public init(multiVectors: [[[Float]]], dimension: Int, normalized: Bool, modelID: String) {
        self.multiVectors = multiVectors
        self.dimension = dimension
        self.normalized = normalized
        self.modelID = modelID
    }
}

/// The canonical descriptor shape for a multi-vector embedding tool (C11), plus the ONE shared
/// scoring helper — MaxSim lives here so every consumer scores identically (and offline tests
/// can pin it without a model).
public enum MultiVectorEmbedContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .multiVectorEmbed,
            summary: summary,
            parameters: [
                ParameterSchema(name: "texts", kind: .array, required: true,
                                summary: "The texts to encode (order preserved in the response)."),
                ParameterSchema(name: "inputType", kind: .string, required: false,
                                summary: "query (fixed-length expansion, scored) or document "
                                    + "(variable length, token-filtered); default document."),
            ],
            supportedModes: modes
        )
    }

    /// MaxSim late-interaction score: `Σ_i max_j (query_i · document_j)` — for each query token
    /// vector, the best-matching document token vector, summed over query tokens. With
    /// normalized rows (the canonical response) each dot is a cosine. Empty inputs score 0.
    /// Row widths must match; scoring across different `modelID`/`dimension` is a consumer bug
    /// the provenance fields exist to prevent.
    public static func maxSim(query: [[Float]], document: [[Float]]) -> Float {
        guard !query.isEmpty, !document.isEmpty else { return 0 }
        var total: Float = 0
        for q in query {
            var best = -Float.infinity
            for d in document {
                var dot: Float = 0
                for k in 0..<min(q.count, d.count) { dot += q[k] * d[k] }
                if dot > best { best = dot }
            }
            total += best
        }
        return total
    }
}
