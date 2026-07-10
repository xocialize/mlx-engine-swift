import Foundation

/// A timestamped span of the transcript, within a speech-to-text response.
/// Segment granularity is model-defined (sentence-level for the first provider);
/// the contract fixes only the shape, not the segmentation policy.
public struct STTSegment: Sendable, Codable, Equatable {
    public let text: String
    /// Start of the segment, seconds from the beginning of the request audio.
    public let start: TimeInterval
    /// Duration of the segment in seconds.
    public let duration: TimeInterval
    public init(text: String, start: TimeInterval, duration: TimeInterval) {
        self.text = text
        self.start = start
        self.duration = duration
    }
}

/// Canonical speech-to-text request: transcribe one complete spoken utterance.
/// Canonical output is **text** (the transcript; see `STTResponse`). One-shot by design —
/// live partial hypotheses are the deferred token-streaming contract (companion N2), not
/// this surface. Multilingual models auto-detect when `language` is nil.
public struct STTRequest: CapabilityRequest {
    public static var capability: Capability { .stt }

    /// The speech audio to transcribe (canonical `Audio` artifact; any rate/channels —
    /// the package resamples as needed).
    public let audio: Audio
    /// Optional BCP-47 language-locale hint (e.g. "en-US"). nil = model auto-detect.
    /// The vocabulary of supported locales is model-defined.
    public let language: String?
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio, language: String? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.audio = audio
        self.language = language
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical speech-to-text response: the full transcript plus timestamped segments.
public struct STTResponse: CapabilityResponse {
    /// The complete transcript, with the model's native punctuation and capitalization.
    public let text: String
    /// Timestamped spans covering the transcript, in order. May be empty for models
    /// without timing output.
    public let segments: [STTSegment]
    /// The BCP-47 locale the model detected (or was told). nil when the model does not
    /// report one.
    public let detectedLanguage: String?

    public init(text: String, segments: [STTSegment] = [], detectedLanguage: String? = nil) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
    }
}

/// The canonical descriptor shape for a speech-to-text tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the
/// canonical surface.
public enum STTContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .stt,
            summary: summary,
            parameters: [
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The speech audio to transcribe."),
                ParameterSchema(name: "language", kind: .string, required: false,
                                summary: "BCP-47 language-locale hint; omit for auto-detect."),
            ],
            supportedModes: modes
        )
    }
}
