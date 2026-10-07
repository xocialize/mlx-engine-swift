import Foundation

/// One edit of an existing speech take (contract 1.50.0, AB-A-0137).
///
/// Shaped like `TTSEmotion`: several genuinely different operations through one canonical field, each
/// mapping 1:1 onto the `SpeechEditControls.Operation` a package declares (`kind`), so a consumer checks
/// supportability without learning a second vocabulary.
///
/// Labels are OPEN strings. Which emotions and styles exist is the package's documented vocabulary,
/// declared in `SpeechEditControls` (Step-Audio-EditX: 15 emotions including `remove`, 33 styles); the
/// contract carries the plane, not the vocabulary — the `TTSEmotion.categorical` rule.
///
/// Deliberately absent: speed (E19 V0 measured a DSP time-stretch beating the model's categorical speed)
/// and content replacement (not something the first provider can do). A kind added later arrives as a new
/// case at a minor version, so switch over this with `@unknown default` — the tolerance C12 asks of
/// `Capability`. The engine never routes an undeclared kind to a package.
public enum SpeechEditOperation: Sendable, Codable, Equatable {
    /// Re-deliver with this emotion: a label from the surface's `emotionLabels`. A package that can
    /// neutralise an emotion declares a label for it (Step-Audio-EditX's is `remove`).
    case emotion(String)
    /// Re-deliver in this speaking style (whisper, shout, older, …): a label from `styleLabels`.
    case style(String)
    /// Insert non-verbal sounds. `targetTranscript` is the take's transcript with the surface's
    /// `paralinguisticTags` inline where the sounds go: `"Great[Laughter], the weather…"`.
    case paralinguistic(targetTranscript: String)
    /// Remove background noise, keeping the voice and the words.
    case denoise
    /// Remove silent stretches, keeping the voice and the words.
    case trimSilence

    /// The declaration this edit requires a surface to have made.
    public var kind: SpeechEditControls.Operation {
        switch self {
        case .emotion: .emotion
        case .style: .style
        case .paralinguistic: .paralinguistic
        case .denoise: .denoise
        case .trimSilence: .trimSilence
        }
    }

    /// The label an `.emotion` or `.style` edit carries; nil for the others.
    public var label: String? {
        switch self {
        case .emotion(let label), .style(let label): label
        case .paralinguistic, .denoise, .trimSilence: nil
        }
    }
}

/// Canonical **speech-edit** request (contract 1.50.0, AB-A-0137): an existing take + what it says → the
/// same words in the same voice, re-delivered per `edit`. Introduced by Step-Audio-EditX
/// (`mlx-step-audio-editx-swift`, E19 / AB-T-0202).
///
/// The output is REGENERATED, not filtered. Unlike `audioPolish`, nothing guarantees the words survive,
/// so a consumer that must keep them compares an ASR pass of the result against
/// `SpeechEditResponse.transcript` (AB-L-0119). Its length generally differs from the input's: a
/// consumer fitting a cue re-fits afterwards.
public struct SpeechEditRequest: CapabilityRequest {
    public static var capability: Capability { .speechEdit }

    /// The take to re-deliver (canonical `Audio`). A surface declaring
    /// `SpeechEditControls.maxInputSeconds` refuses a longer one rather than truncating it.
    public let audio: Audio
    /// What the take says. The model conditions on it; an `stt` pass can supply it.
    public let transcript: String
    /// The one edit to make.
    public let edit: SpeechEditOperation
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio,
                transcript: String,
                edit: SpeechEditOperation,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.audio = audio
        self.transcript = transcript
        self.edit = edit
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical speech-edit response: the re-delivered take (`.wav`) and the text it should carry — the
/// request's `transcript`, or a `.paralinguistic` edit's target with its tags. That text is what a
/// content check compares an ASR pass of `audio` against.
public struct SpeechEditResponse: CapabilityResponse {
    public let audio: Audio
    public let transcript: String

    public init(audio: Audio, transcript: String) {
        self.audio = audio
        self.transcript = transcript
    }
}

/// What a **`speechEdit`** surface can do (contract 1.50.0): the routing-time declaration a consumer
/// reads BEFORE it offers "re-deliver as …" — which operations, which labels, how long a take.
///
/// Not here, by the `SurfaceControls` governing rule: a default sampling temperature. It steers a
/// single run of one model family, so it is the package's `metaData`.
public struct SpeechEditControls: Sendable, Codable, Equatable {
    /// The edit kinds a surface can honor, one per `SpeechEditOperation` case.
    public enum Operation: String, Sendable, Codable {
        case emotion, style, paralinguistic, denoise, trimSilence
    }

    /// Operations this surface honors. The engine refuses any other before admission.
    public let operations: [Operation]
    /// The emotion vocabulary for `.emotion` edits. Non-empty = the only labels admitted (the engine
    /// refuses another before admission); empty = open, and the package judges the label.
    public let emotionLabels: [String]
    /// The style vocabulary for `.style` edits, on the same rule.
    public let styleLabels: [String]
    /// The inline tags a `.paralinguistic` target may carry (`[Laughter]`, `[Breathing]`, …). Advertised
    /// for a planner to write with; the engine does not parse transcripts, so a package refuses a tag it
    /// cannot render.
    public let paralinguisticTags: [String]
    /// The longest take this surface accepts, in seconds — for Step-Audio-EditX its LM's context window.
    /// nil = unstated. Enforced by the package: a longer take is refused, never truncated.
    public let maxInputSeconds: Double?

    public init(operations: [Operation],
                emotionLabels: [String] = [],
                styleLabels: [String] = [],
                paralinguisticTags: [String] = [],
                maxInputSeconds: Double? = nil) {
        self.operations = operations
        self.emotionLabels = emotionLabels
        self.styleLabels = styleLabels
        self.paralinguisticTags = paralinguisticTags
        self.maxInputSeconds = maxInputSeconds
    }

    /// The declared vocabulary an operation draws on: labels for `.emotion` / `.style`, tags for
    /// `.paralinguistic`, nothing for the rest.
    public func vocabulary(for operation: Operation) -> [String] {
        switch operation {
        case .emotion: emotionLabels
        case .style: styleLabels
        case .paralinguistic: paralinguisticTags
        case .denoise, .trimSilence: []
        }
    }
}

/// Canonical descriptor shape for a speech-edit tool (C11).
///
/// The declaration is REQUIRED here, unlike the optional controls of `tts` / `stt`: the engine admits only
/// declared edits, so a speechEdit surface without one could run nothing. A surface is born declared, and
/// the `edit` parameter's summary is derived from the declaration, so the advertised schema cannot drift
/// from it.
public enum SpeechEditContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: SpeechEditControls) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .speechEdit,
            summary: summary,
            parameters: [
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The take to re-deliver."),
                ParameterSchema(name: "transcript", kind: .string, required: true,
                                summary: "What the take says."),
                ParameterSchema(name: "edit", kind: .object, required: true,
                                summary: editSummary(controls)),
                ParameterSchema(name: "seed", kind: .integer, required: false,
                                summary: "RNG seed for reproducibility."),
            ],
            supportedModes: modes,
            controls: .speechEdit(controls)
        )
    }

    /// One line per declared operation, with its vocabulary, so a planner sees exactly what it may send.
    static func editSummary(_ controls: SpeechEditControls) -> String {
        let operations = controls.operations.map { operation -> String in
            let vocabulary = controls.vocabulary(for: operation)
            switch operation {
            case .emotion, .style:
                return "\(operation.rawValue) ("
                    + (vocabulary.isEmpty ? "any label" : vocabulary.joined(separator: " / ")) + ")"
            case .paralinguistic:
                return "paralinguistic (targetTranscript with inline tags"
                    + (vocabulary.isEmpty ? ")" : ": " + vocabulary.joined(separator: " / ") + ")")
            case .denoise, .trimSilence:
                return operation.rawValue
            }
        }
        var summary = "One edit: " + operations.joined(separator: "; ") + "."
        if let limit = controls.maxInputSeconds {
            summary += " Takes up to " + String(format: "%g", limit) + " s."
        }
        return summary
    }
}
