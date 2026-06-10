import Foundation

/// A single emotion category and its probability, within a speech-emotion prediction.
public struct EmotionScore: Sendable, Codable, Equatable {
    public let label: String   // model-defined category, e.g. "happy", "angry", "neutral"
    public let score: Float    // 0...1
    public init(label: String, score: Float) {
        self.label = label
        self.score = score
    }
}

/// Canonical speech-emotion request: classify the emotion expressed in a speech clip.
/// Canonical output is **structured text** (a label distribution; see `SpeechEmotionResponse`).
/// The label vocabulary is model-defined (kept open, like image/video analysis prose), so the
/// contract does not fix a taxonomy.
public struct SpeechEmotionRequest: CapabilityRequest {
    public static var capability: Capability { .speechEmotion }

    /// The speech audio to analyze (canonical `Audio` artifact; any rate/channels).
    public let audio: Audio
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.audio = audio
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical speech-emotion response: the dominant label plus the full score distribution.
public struct SpeechEmotionResponse: CapabilityResponse {
    /// Most likely emotion label.
    public let label: String
    /// Confidence of the dominant label (0...1).
    public let confidence: Float
    /// Full probability distribution over the model's categories.
    public let scores: [EmotionScore]

    public init(label: String, confidence: Float, scores: [EmotionScore]) {
        self.label = label
        self.confidence = confidence
        self.scores = scores
    }
}

/// The canonical descriptor shape for a speech-emotion tool. A package fills in `name`/`summary`
/// and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum SpeechEmotionContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .speechEmotion,
            summary: summary,
            parameters: [
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The speech audio to classify."),
            ],
            supportedModes: modes
        )
    }
}
