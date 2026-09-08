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

/// How an emotion is handed to a TTS surface (contract 1.38.0, E12).
///
/// Deliberately shaped like `VoiceSelector.Selection`, its sibling in this file, because the
/// problem is the same one: a single canonical field several genuinely different mechanisms have
/// to fit through, one of them a canonical `Audio` artifact. The case a value carries maps 1:1
/// onto the `TTSControls.EmotionMode` a package declares (see `mode`), so a consumer checks
/// supportability without learning a second vocabulary.
///
/// **The contract carries the plane, not the vocabulary.** `categorical` is an open `String`
/// because the emotion CATEGORIES are the audio packages' to agree on (E12's 9→8 map is their
/// work), governed the way `Mode`/`Specialty`/`RunPhase` are. A closed enum here would freeze one
/// model family's taxonomy into the contract, and the first model with a ninth emotion would
/// need a contract revision to say so.
public enum TTSEmotion: Sendable, Codable, Equatable {
    /// A named category — "happy", "angry". Vocabulary is package-defined and open.
    case categorical(String)
    /// A numeric emotion vector; dimensionality and axis meaning are model-defined (IndexTTS2's
    /// emotion head, or a valence/arousal/dominance triple from an annotation stage).
    case vector([Float])
    /// Copy the emotion from a clip, decoupled from timbre — this is NOT voice cloning
    /// (`VoiceSelector.referenceAudio` is that, and the two compose: clone A, emote like B).
    case referenceAudio(Audio)
    /// Natural-language direction ("sound exhausted") — Qwen3-TTS `instruct`.
    case textDescription(String)

    /// The declaration this value requires a surface to have made.
    public var mode: TTSControls.EmotionMode {
        switch self {
        case .categorical: .categorical
        case .vector: .vector
        case .referenceAudio: .referenceAudio
        case .textDescription: .textDescription
        }
    }
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
    /// Optional emotion steering (contract 1.38.0, E12). Promoted from `metaData` on exactly the
    /// rule `referenceTranscript` records above — a second adopter arrived. IndexTTS2 shipped the
    /// first realization via `metaData` 2026-07-09; ML[X] Audio Studio's Dub section became the
    /// second 2026-09-01, and the untyped path had made it hardcode which engine reads which key.
    ///
    /// Send only a mode the surface DECLARES (`ToolDescriptor.ttsControls?.emotionModes`).
    /// `MLXServeEngine.run` refuses an undeclared one with
    /// `PackageError.unsupportedRequestFeature` before admission — silently ignoring a canonical
    /// request field is a contract violation (the rule 1.16.0 set for `responseFormat`).
    public let emotion: TTSEmotion?
    /// Optional target output length in seconds — synthesize to fit a cue window (contract
    /// 1.38.0, E12). Only for a surface declaring `TTSControls.supportsTargetDuration`; a
    /// consumer routed to one that does not should time-stretch the result instead, which is the
    /// decision the flag exists to make routable. **Not a hard guarantee**: a package fits as
    /// closely as its native duration control allows, and the returned `.wav` is the truth.
    public let targetDuration: TimeInterval?
    public let mode: Mode?
    public let metaData: MetaData

    public init(text: String,
                voice: VoiceSelector = VoiceSelector(),
                referenceTranscript: String? = nil,
                emotion: TTSEmotion? = nil,
                targetDuration: TimeInterval? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.text = text
        self.voice = voice
        self.referenceTranscript = referenceTranscript
        self.emotion = emotion
        self.targetDuration = targetDuration
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
                                  streaming: StreamGranularity? = nil,
                                  controls: TTSControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "text", kind: .string, required: true,
                            summary: "The text to speak."),
            ParameterSchema(name: "voice", kind: .object, required: false,
                            summary: "Canonical voice selection (named / referenceAudio / auto)."),
            ParameterSchema(name: "referenceTranscript", kind: .string, required: false,
                            summary: "Transcript of the referenceAudio clip (ICL-grade cloning)."),
        ]
        // The E12 controls appear on the surface only when the package DECLARES them, so a
        // planner is never offered a knob that is ignored (the `supportsStrength` precedent,
        // 1.30.0). One source of truth: the schema entries are derived from the declaration, so
        // the advertised parameters and `ttsControls` cannot drift apart.
        if let controls, !controls.emotionModes.isEmpty {
            parameters.append(ParameterSchema(
                name: "emotion", kind: .object, required: false,
                summary: "Emotion steering; modes honored: "
                    + controls.emotionModes.map(\.rawValue).joined(separator: " / ") + "."))
        }
        if controls?.supportsTargetDuration == true {
            parameters.append(ParameterSchema(
                name: "targetDuration", kind: .number, required: false,
                summary: "Target output length in seconds (native duration control)."))
        }
        return ToolDescriptor(
            name: name,
            capability: .tts,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            streaming: streaming,
            controls: controls.map(SurfaceControls.tts)
        )
    }
}
