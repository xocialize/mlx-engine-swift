import Foundation

/// A content tag and its score, within a content-classification result.
public struct ContentScore: Sendable, Codable, Equatable {
    public let label: String   // model-defined vocabulary
    public let score: Float
    public init(label: String, score: Float) {
        self.label = label
        self.score = score
    }
}

/// Canonical content-classification request: classify/embed a video clip's content. The
/// *assessment* capability the optimization planner uses for routing (content type drives the
/// recipe: which enhancer chain, which SR variant). Canonical output is **structured text**
/// (tags + an embedding); the label vocabulary is model-defined (open).
public struct ContentClassifyRequest: CapabilityRequest {
    public static var capability: Capability { .contentClassify }

    /// The video to classify (canonical `Video` artifact).
    public let video: Video
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.video = video
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical content-classification response: top-k tags plus the clip embedding — the
/// embedding is the planner/router feature vector (usable even when the tag vocabulary
/// doesn't fit the routing question).
public struct ContentClassifyResponse: CapabilityResponse {
    /// Top-k content tags (model-defined vocabulary), highest score first.
    public let labels: [ContentScore]
    /// The pooled clip embedding (model-defined dimensionality).
    public let embedding: [Float]

    public init(labels: [ContentScore], embedding: [Float]) {
        self.labels = labels
        self.embedding = embedding
    }
}

/// The canonical descriptor shape for a content-classification tool.
public enum ContentClassifyContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .contentClassify,
            summary: summary,
            parameters: [
                ParameterSchema(name: "video", kind: .video, required: true,
                                summary: "The video clip to classify / embed."),
            ],
            supportedModes: modes
        )
    }
}
