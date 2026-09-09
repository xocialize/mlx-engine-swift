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
    /// Model-assigned speaker label for this span, when the surface attributes speakers
    /// (contract 1.38.0). `nil` when it does not — and a `nil` says NOTHING about the audio:
    /// `ToolDescriptor.sttControls?.attributesSpeakers` is where a consumer learns whether this
    /// package can diarize at all, because "one person spoke" and "this model cannot tell" are
    /// otherwise indistinguishable.
    ///
    /// **Opaque and session-scoped.** Stable within one response; "Speaker 0" in two different
    /// responses is not the same person. Cross-request identity needs enrollment, which is a
    /// separate capability, not this field.
    ///
    /// A `String?` rather than an `Int?` for the reason `Mode`/`Specialty`/`RunPhase` are open
    /// strings: models that emit named rather than numbered speakers stay representable, and
    /// enrolled-speaker naming later needs no second migration.
    public let speaker: String?
    public init(text: String, start: TimeInterval, duration: TimeInterval,
                speaker: String? = nil) {
        self.text = text
        self.start = start
        self.duration = duration
        self.speaker = speaker
    }
}

/// Canonical speech-to-text request: transcribe one complete spoken utterance.
/// Canonical output is **text** (the transcript; see `STTResponse`). Multilingual models
/// auto-detect when `language` is nil.
///
/// **One-shot by design, and still so after 1.39.0.** Audio that is still arriving is a
/// SESSION, not a request: `StreamEmitting.runStream` cannot model it, because it holds
/// `@InferenceActor` for the length of the run and a live microphone session would hold the
/// fleet's serialized inference for as long as someone keeps talking. That case has its own
/// plane since 1.39.0 — `LiveTranscribing` + `STTSession` + `MLXServeEngine.transcribeLive`
/// (`LiveSTT.swift`, the LIV-1..6 gate) — and this request type is unchanged by it. File and
/// utterance transcription still come here.
public struct STTRequest: CapabilityRequest {
    public static var capability: Capability { .stt }

    /// The speech audio to transcribe (canonical `Audio` artifact; any rate/channels —
    /// the package resamples as needed).
    public let audio: Audio
    /// Optional BCP-47 language-locale hint (e.g. "en-US"). nil = model auto-detect.
    /// The vocabulary of supported locales is model-defined.
    public let language: String?
    /// Optional recognition-biasing terms — names, jargon, product vocabulary the model should
    /// prefer (contract 1.38.0). Model-defined interpretation, and the highest-leverage knob for
    /// the domain tokens a general LM gets wrong.
    ///
    /// A `[String]` rather than free prose because a vocabulary list is the shape callers
    /// actually hold, and each package joins/formats it for its own prompt convention
    /// (VibeVoice's `context_info`; the Python mlx-audio STT family's shared `merge_hotwords`).
    ///
    /// Advertised only by a surface declaring `STTControls.supportsContextBiasing`;
    /// `MLXServeEngine.run` refuses it against one that does not, rather than letting a caller
    /// believe biasing happened when the terms were dropped.
    public let context: [String]?
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio, language: String? = nil, context: [String]? = nil,
                mode: Mode? = nil, metaData: MetaData = [:]) {
        self.audio = audio
        self.language = language
        self.context = context
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
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: STTControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "audio", kind: .audio, required: true,
                            summary: "The speech audio to transcribe."),
            ParameterSchema(name: "language", kind: .string, required: false,
                            summary: "BCP-47 language-locale hint; omit for auto-detect."),
        ]
        // `context` appears on the surface only when the package DECLARES a biasing surface, so
        // a planner is never offered a knob that is ignored (the `supportsStrength` precedent,
        // 1.30.0). Deriving the schema entry from the declaration keeps one source of truth: the
        // advertised parameters and `sttControls` cannot drift apart.
        if controls?.supportsContextBiasing == true {
            parameters.append(ParameterSchema(
                name: "context", kind: .array, required: false,
                summary: "Recognition-biasing terms (names, jargon, product vocabulary)."))
        }
        // `liveDiscipline` derives NO schema entry, and that is not an oversight: live
        // transcription is a different ENTRY POINT (`MLXServeEngine.transcribeLive`), not a knob
        // on this one-shot surface. The parameter list describes `run(STTRequest)`; advertising
        // a live-only field here would offer a planner something `run` cannot honor.
        return ToolDescriptor(
            name: name,
            capability: .stt,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map(SurfaceControls.stt)
        )
    }
}
