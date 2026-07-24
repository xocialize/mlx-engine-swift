import Foundation

/// Voice selection for TTS.
///
/// Voice is *canonical* — every TTS model has the concept — so it lives in the schema, not
/// in `metaData` (C5). How a package realizes the voice (its strengths, prosody engine,
/// internal voice ids) is its own business and may use `metaData` for those extras.
public struct VoiceSelector: Sendable, Codable, Equatable {
    public enum Selection: Sendable, Codable, Equatable {
        case named(String)         // a package-known voice id
        case referenceAudio(Audio) // clone from a reference clip (canonical Audio artifact)
        case auto                  // let the package choose its default
    }

    public let selection: Selection
    public init(_ selection: Selection = .auto) { self.selection = selection }
}

extension Mode {
    // Example TTS modes a package may honor. Modes are open/extensible.
    public static let expressive: Mode = "expressive"
    public static let neutral: Mode = "neutral"
}

/// Canonical TTS request. Canonical output is always `.wav` (see `TTSResponse`).
public struct TTSRequest: CapabilityRequest {
    public static var capability: Capability { .tts }

    public let text: String
    public let voice: VoiceSelector
    /// Transcript of the `.referenceAudio` clip, for ICL-grade cloning. Canonical because
    /// every ICL-style cloning TTS (Qwen3-TTS, VoxCPM2, CosyVoice, VibeVoice) conditions on
    /// (reference audio, reference text) as a pair — promoted from `metaData` when the second
    /// package needed it (contract 1.1.0). Ignored unless `voice` is `.referenceAudio`;
    /// packages without an ICL path may ignore it (their cloning quality tier is theirs).
    public let referenceTranscript: String?
    public let mode: Mode?
    public let metaData: MetaData

    public init(text: String,
                voice: VoiceSelector = VoiceSelector(),
                referenceTranscript: String? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.text = text
        self.voice = voice
        self.referenceTranscript = referenceTranscript
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical TTS response. Always returns `.wav` audio in serialized round-trip form.
public struct TTSResponse: CapabilityResponse {
    public let audio: Audio
    public init(audio: Audio) { self.audio = audio }
}

/// One PCM slice of an in-flight TTS synthesis (contract 1.25.0, ENGINE-NEEDS N2).
///
/// Deliberately NOT an `Audio` artifact: a per-chunk .wav container would be waste and a lie
/// (no valid standalone header semantics). The canonical artifact contract is untouched — the
/// aggregated response a streaming run also returns is still always `.wav`. No timing field:
/// timing is observability and rides `RunProgress` (the observability plane), not the data plane.
public struct TTSStreamChunk: Sendable, Codable, Equatable {
    /// Mono PCM samples, normalized to [-1, 1].
    public let samples: [Float]
    public let sampleRate: Int
    /// 0-based chunk ordinal; strictly monotonic, no gaps.
    public let index: Int
    /// Exactly one chunk carries `true`, and it is the last.
    public let isFinal: Bool

    public init(samples: [Float], sampleRate: Int, index: Int, isFinal: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.index = index
        self.isFinal = isFinal
    }
}

/// The canonical descriptor shape for a TTS tool. A package fills in `name`/`summary` and
/// may extend `supportedModes`; the parameter schema is the canonical TTS surface.
public enum TTSContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  streaming: StreamGranularity? = nil) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .tts,
            summary: summary,
            parameters: [
                ParameterSchema(name: "text", kind: .string, required: true,
                                summary: "The text to speak."),
                ParameterSchema(name: "voice", kind: .object, required: false,
                                summary: "Canonical voice selection (named / referenceAudio / auto)."),
                ParameterSchema(name: "referenceTranscript", kind: .string, required: false,
                                summary: "Transcript of the referenceAudio clip (ICL-grade cloning)."),
            ],
            supportedModes: modes,
            streaming: streaming
        )
    }
}
