import Foundation

/// One edit of an existing speech take (contract 1.50.0, AB-A-0137; the AuK kinds 1.59.0, AB-A-0188).
///
/// Shaped like `TTSEmotion`: several genuinely different operations through one canonical field, each
/// mapping 1:1 onto the `SpeechEditControls.Operation` a package declares (`kind`), so a consumer checks
/// supportability without learning a second vocabulary.
///
/// Labels are OPEN strings. Which emotions, styles and nonverbal sounds exist is the package's documented
/// vocabulary, declared in `SpeechEditControls` (Step-Audio-EditX: 15 emotions including `remove`, 33
/// styles; AuK: 8 emotions, `whisper` / `normal`); the contract carries the plane, not the vocabulary —
/// the `TTSEmotion.categorical` rule. Whisper ↔ normal is `.style("whisper")` / `.style("normal")`.
///
/// 1.50.0 left out speed and content replacement because the first provider (Step-Audio-EditX) could not
/// do them well; AuK leads every editing benchmark it reports on exactly those kinds (SpeechEditBench
/// content 91.8 vs EditX 16.5), so 1.59.0 adds them. A kind added later arrives as a new case at a minor
/// version, so switch over this with `@unknown default` — the tolerance C12 asks of `Capability`. The
/// engine never routes an undeclared kind to a package.
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

    // 1.59.0 (AB-A-0188) — content edits. Each changes the take's length (see `changesLength`).
    /// Say `new` where the take says `original`, in the same voice.
    case replaceWords(original: String, new: String)
    /// Add `text` immediately before (or after) `anchor`, words the take already says.
    case insertWords(text: String, anchor: String, before: Bool)
    /// Remove `text`. With an `anchor`, the occurrence just before (or after) it; without one, the
    /// package removes the occurrence it finds and `before` is ignored.
    case removeWords(text: String, anchor: String?, before: Bool)

    // 1.59.0 — acoustic edits, on the surface's declared grids.
    /// Faster (> 1) or slower (< 1), keeping the words: a factor from `speedFactors`.
    case speed(factor: Double)
    /// Higher (+) or lower (−) by whole semitones: a step from `pitchSemitones`.
    case pitch(semitones: Int)
    /// Louder (+) or quieter (−) by whole decibels: a step from `volumeDecibels`.
    case volume(dB: Int)

    // 1.59.0 — voice and room edits.
    /// Keep the words, change the voice to match a description in words ("a deep, older male voice").
    case timbre(description: String)
    /// Toward a standard accent, keeping the speaker's voice and the words.
    case deAccent
    /// Remove room reverberation, keeping the voice and the words — the sibling of `.denoise`.
    case dereverberate

    // 1.59.0 — nonverbal sounds at the take's edges. Unlike `.paralinguistic`, there is no position
    // inside the words to name: the model adds at the start or the end only, and removes everywhere.
    /// Add one nonverbal sound (a label from `nonverbalSounds`) at the start, or at the end.
    case addNonverbal(sound: String, atEnd: Bool)
    /// Remove every occurrence of a nonverbal sound (a label from `nonverbalSounds`); nil removes them all.
    case removeNonverbal(sound: String?)

    /// The declaration this edit requires a surface to have made.
    public var kind: SpeechEditControls.Operation {
        switch self {
        case .emotion: .emotion
        case .style: .style
        case .paralinguistic: .paralinguistic
        case .denoise: .denoise
        case .trimSilence: .trimSilence
        case .replaceWords: .replaceWords
        case .insertWords: .insertWords
        case .removeWords: .removeWords
        case .speed: .speed
        case .pitch: .pitch
        case .volume: .volume
        case .timbre: .timbre
        case .deAccent: .deAccent
        case .dereverberate: .dereverberate
        case .addNonverbal: .addNonverbal
        case .removeNonverbal: .removeNonverbal
        }
    }

    /// The vocabulary label this edit carries — an emotion, a style or a nonverbal sound — checked
    /// against `SpeechEditControls.vocabulary(for: kind)`; nil for the others.
    public var label: String? {
        switch self {
        case .emotion(let label), .style(let label): label
        case .addNonverbal(let sound, _): sound
        case .removeNonverbal(let sound): sound
        case .paralinguistic, .denoise, .trimSilence, .replaceWords, .insertWords, .removeWords,
             .speed, .pitch, .volume, .timbre, .deAccent, .dereverberate: nil
        }
    }

    /// Whether this edit changes how long the take is by its nature — the words change, the rate
    /// changes, or a sound is added or taken away. These are the edits a `SpeechEditRequest.targetDuration`
    /// is for. Every edit of a REGENERATING model may still drift in length (Step-Audio-EditX's do).
    public var changesLength: Bool {
        switch self {
        case .replaceWords, .insertWords, .removeWords, .speed, .addNonverbal, .removeNonverbal: true
        case .emotion, .style, .paralinguistic, .denoise, .trimSilence, .pitch, .volume, .timbre,
             .deAccent, .dereverberate: false
        }
    }
}

/// Canonical **speech-edit** request (contract 1.50.0, AB-A-0137): an existing take + what it says → the
/// same voice, re-delivered per `edit`. Introduced by Step-Audio-EditX (`mlx-step-audio-editx-swift`,
/// E19 / AB-T-0202); the content, acoustic and voice edits and `targetDuration` by AuK (`mlx-auk-swift`,
/// E18 / AB-T-0325, contract 1.59.0).
///
/// The output is REGENERATED, not filtered. Unlike `audioPolish`, nothing guarantees the words survive,
/// so a consumer that must keep them compares an ASR pass of the result against
/// `SpeechEditResponse.transcript` (AB-L-0119). Its length generally differs from the input's: a
/// consumer fitting a cue re-fits afterwards, or asks for a length with `targetDuration`.
public struct SpeechEditRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .speechEdit }

    /// The take to re-deliver (canonical `Audio`). A surface declaring
    /// `SpeechEditControls.maxInputSeconds` refuses a longer one rather than truncating it.
    public let audio: Audio
    /// What the take says; an `stt` pass can supply it. Empty means none was given, which the engine
    /// admits only for a surface whose `SpeechEditControls.transcript` is `.optional` or `.unused`
    /// (contract 1.59.0; AuK conditions on the audio alone).
    public let transcript: String
    /// The one edit to make.
    public let edit: SpeechEditOperation
    /// How long the edited take should be, in seconds (contract 1.59.0) — for the edits that change
    /// length (`SpeechEditOperation.changesLength`). Only for a surface declaring
    /// `SpeechEditControls.supportsTargetDuration`; the engine refuses it elsewhere, since an ignored
    /// length is a take that does not fit its cue. nil = the package's own estimate.
    public let targetDuration: TimeInterval?
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio,
                transcript: String = "",
                edit: SpeechEditOperation,
                targetDuration: TimeInterval? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.audio = audio
        self.transcript = transcript
        self.edit = edit
        self.targetDuration = targetDuration
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }

    private enum CodingKeys: String, CodingKey {
        case audio, transcript, edit, targetDuration, seed, mode, metaData
    }

    /// A request with no transcript may omit the key (1.59.0); pre-1.59 JSON always carries it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audio = try container.decode(Audio.self, forKey: .audio)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        edit = try container.decode(SpeechEditOperation.self, forKey: .edit)
        targetDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .targetDuration)
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode)
        metaData = try container.decode(MetaData.self, forKey: .metaData)
    }
}

/// Canonical speech-edit response: the re-delivered take (`.wav`) and the text it should carry — the
/// request's `transcript`, a `.paralinguistic` edit's target with its tags, or, for a content edit,
/// the transcript with the words changed. That text is what a content check compares an ASR pass of
/// `audio` against. Empty when the request carried no transcript and the package cannot know the whole
/// text (an AuK content edit on an untranscribed take).
public struct SpeechEditResponse: CapabilityResponse, Codable {
    public let audio: Audio
    public let transcript: String

    public init(audio: Audio, transcript: String) {
        self.audio = audio
        self.transcript = transcript
    }
}

/// What a **`speechEdit`** surface can do (contract 1.50.0; extended 1.59.0): the routing-time
/// declaration a consumer reads BEFORE it offers "re-deliver as …" — which operations, which labels and
/// grids, whether it needs the transcript, whether it takes a length, how long a take.
///
/// Not here, by the `SurfaceControls` governing rule: a default sampling temperature or step count. They
/// steer a single run of one model family, so they are the package's `metaData`.
public struct SpeechEditControls: Sendable, Codable, Equatable {
    /// The edit kinds a surface can honor, one per `SpeechEditOperation` case.
    public enum Operation: String, Sendable, Codable {
        case emotion, style, paralinguistic, denoise, trimSilence
        // 1.59.0 (AB-A-0188)
        case replaceWords, insertWords, removeWords
        case speed, pitch, volume
        case timbre, deAccent, dereverberate
        case addNonverbal, removeNonverbal
    }

    /// How a surface uses `SpeechEditRequest.transcript` (contract 1.59.0).
    public enum TranscriptUse: String, Sendable, Codable {
        /// The model conditions on it; an empty transcript is refused (Step-Audio-EditX).
        case required
        /// Used when given, not needed.
        case optional
        /// The model conditions on the audio alone; a transcript given is only echoed (AuK).
        case unused
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
    /// The sounds `.addNonverbal` / `.removeNonverbal` name (`breath`, `laugh`, `cough`, …), on the
    /// emotion rule: non-empty = the only ones admitted (1.59.0).
    public let nonverbalSounds: [String]
    /// The `.speed` factors this surface was trained on (AuK: 0.5 / 0.75 / 1.25 / 1.5 / 2.0). Non-empty =
    /// the only factors admitted; empty = any positive factor, the package judges (1.59.0).
    public let speedFactors: [Double]
    /// The `.pitch` steps in semitones (AuK: ±1…3), on the same rule (1.59.0).
    public let pitchSemitones: [Int]
    /// The `.volume` steps in decibels (AuK: ±5 / 10 / 15), on the same rule (1.59.0).
    public let volumeDecibels: [Int]
    /// Whether this surface needs the take's transcript (1.59.0). `.required` — every pre-1.59
    /// declaration — refuses an empty one before admission.
    public let transcript: TranscriptUse
    /// Whether this surface honors `SpeechEditRequest.targetDuration` (1.59.0). The engine refuses a
    /// length sent to a surface that does not declare it.
    public let supportsTargetDuration: Bool
    /// The longest take this surface accepts, in seconds — for Step-Audio-EditX its LM's context window.
    /// nil = unstated. Enforced by the package: a longer take is refused, never truncated.
    public let maxInputSeconds: Double?

    public init(operations: [Operation],
                emotionLabels: [String] = [],
                styleLabels: [String] = [],
                paralinguisticTags: [String] = [],
                nonverbalSounds: [String] = [],
                speedFactors: [Double] = [],
                pitchSemitones: [Int] = [],
                volumeDecibels: [Int] = [],
                transcript: TranscriptUse = .required,
                supportsTargetDuration: Bool = false,
                maxInputSeconds: Double? = nil) {
        self.operations = operations
        self.emotionLabels = emotionLabels
        self.styleLabels = styleLabels
        self.paralinguisticTags = paralinguisticTags
        self.nonverbalSounds = nonverbalSounds
        self.speedFactors = speedFactors
        self.pitchSemitones = pitchSemitones
        self.volumeDecibels = volumeDecibels
        self.transcript = transcript
        self.supportsTargetDuration = supportsTargetDuration
        self.maxInputSeconds = maxInputSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case operations, emotionLabels, styleLabels, paralinguisticTags, nonverbalSounds, speedFactors,
             pitchSemitones, volumeDecibels, transcript, supportsTargetDuration, maxInputSeconds
    }

    /// Pre-1.59 descriptor JSON decodes unchanged: every 1.59.0 member defaults to the 1.50.0 behaviour.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operations = try container.decode([Operation].self, forKey: .operations)
        emotionLabels = try container.decodeIfPresent([String].self, forKey: .emotionLabels) ?? []
        styleLabels = try container.decodeIfPresent([String].self, forKey: .styleLabels) ?? []
        paralinguisticTags = try container.decodeIfPresent([String].self, forKey: .paralinguisticTags) ?? []
        nonverbalSounds = try container.decodeIfPresent([String].self, forKey: .nonverbalSounds) ?? []
        speedFactors = try container.decodeIfPresent([Double].self, forKey: .speedFactors) ?? []
        pitchSemitones = try container.decodeIfPresent([Int].self, forKey: .pitchSemitones) ?? []
        volumeDecibels = try container.decodeIfPresent([Int].self, forKey: .volumeDecibels) ?? []
        transcript = try container.decodeIfPresent(TranscriptUse.self, forKey: .transcript) ?? .required
        supportsTargetDuration = try container.decodeIfPresent(Bool.self, forKey: .supportsTargetDuration)
            ?? false
        maxInputSeconds = try container.decodeIfPresent(Double.self, forKey: .maxInputSeconds)
    }

    /// The declared label vocabulary an operation draws on: labels for `.emotion` / `.style`, tags for
    /// `.paralinguistic`, sounds for the nonverbal edits, nothing for the rest (the numeric grids are
    /// `speedFactors` / `pitchSemitones` / `volumeDecibels`).
    public func vocabulary(for operation: Operation) -> [String] {
        switch operation {
        case .emotion: emotionLabels
        case .style: styleLabels
        case .paralinguistic: paralinguisticTags
        case .addNonverbal, .removeNonverbal: nonverbalSounds
        case .denoise, .trimSilence, .replaceWords, .insertWords, .removeWords, .speed, .pitch, .volume,
             .timbre, .deAccent, .dereverberate: []
        }
    }

    /// Why this surface cannot take `request`, or nil when it can (contract 1.59.0; the 1.50.0 checks
    /// moved here from the engine). The engine's pre-flight throws it as
    /// `PackageError.unsupportedRequestFeature` before admission; a package driven directly may call it
    /// first for the same refusal — the `MusicControls.refusal(for:)` pattern. Checks what an ignored or
    /// off-grid field would make WRONG: an undeclared operation, a label or step outside a declared set,
    /// a missing required transcript, an undeclared length.
    public func refusal(for request: SpeechEditRequest) -> String? {
        let edit = request.edit
        let kind = edit.kind
        guard operations.contains(kind) else {
            return "edit(.\(kind.rawValue)) — this surface declares no such speech edit "
                + "(SpeechEditControls.operations: " + operations.map(\.rawValue).joined(separator: " / ") + ")"
        }
        let vocabulary = vocabulary(for: kind)
        if let label = edit.label, !vocabulary.isEmpty, !vocabulary.contains(label) {
            return "edit(.\(kind.rawValue)(\"\(label)\")) — not one of the \(kind.rawValue) labels this "
                + "surface declares (SpeechEditControls: " + vocabulary.joined(separator: " / ") + ")"
        }
        switch edit {
        case .speed(let factor):
            guard factor.isFinite, factor > 0 else {
                return "edit(.speed(\(Self.format(factor)))) — a speed factor is a positive number"
            }
            if !speedFactors.isEmpty, !speedFactors.contains(where: { abs($0 - factor) < 1e-9 }) {
                return "edit(.speed(\(Self.format(factor)))) — not one of the factors this surface declares "
                    + "(SpeechEditControls.speedFactors: " + speedFactors.map(Self.format).joined(separator: " / ")
                    + "); time-stretch the result for another rate"
            }
        case .pitch(let semitones):
            if !pitchSemitones.isEmpty, !pitchSemitones.contains(semitones) {
                return "edit(.pitch(\(semitones))) — not one of the semitone steps this surface declares "
                    + "(SpeechEditControls.pitchSemitones: " + pitchSemitones.map(String.init).joined(separator: " / ") + ")"
            }
        case .volume(let dB):
            if !volumeDecibels.isEmpty, !volumeDecibels.contains(dB) {
                return "edit(.volume(\(dB))) — not one of the decibel steps this surface declares "
                    + "(SpeechEditControls.volumeDecibels: " + volumeDecibels.map(String.init).joined(separator: " / ")
                    + "); apply the gain to the result for another step"
            }
        default:
            break
        }
        if transcript == .required,
           request.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "transcript — this surface conditions on what the take says "
                + "(SpeechEditControls.transcript: required); supply it, from an stt pass if need be"
        }
        if let seconds = request.targetDuration {
            guard supportsTargetDuration else {
                return "targetDuration(\(Self.format(seconds))) — this surface declares no length control "
                    + "(SpeechEditControls.supportsTargetDuration); drop it and re-fit the result"
            }
            guard seconds.isFinite, seconds > 0 else {
                return "targetDuration(\(Self.format(seconds))) — a length is a positive number of seconds"
            }
        }
        return nil
    }

    static func format(_ value: Double) -> String { String(format: "%g", value) }
}

/// Canonical descriptor shape for a speech-edit tool (C11).
///
/// The declaration is REQUIRED here, unlike the optional controls of `tts` / `stt`: the engine admits only
/// declared edits, so a speechEdit surface without one could run nothing. A surface is born declared, and
/// the `edit` parameter's summary — and whether `transcript` is required, and whether `targetDuration` is
/// offered — is derived from the declaration, so the advertised schema cannot drift from it.
public enum SpeechEditContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: SpeechEditControls) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "audio", kind: .audio, required: true,
                            summary: "The take to re-deliver."),
            ParameterSchema(name: "transcript", kind: .string, required: controls.transcript == .required,
                            summary: transcriptSummary(controls.transcript)),
            ParameterSchema(name: "edit", kind: .object, required: true,
                            summary: editSummary(controls)),
        ]
        if controls.supportsTargetDuration {
            parameters.append(ParameterSchema(
                name: "targetDuration", kind: .number, required: false,
                summary: "Length of the edited take in seconds, for edits that change it; absent = the model's estimate."))
        }
        parameters.append(ParameterSchema(name: "seed", kind: .integer, required: false,
                                          summary: "RNG seed for reproducibility."))
        return ToolDescriptor(
            name: name,
            capability: .speechEdit,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: .speechEdit(controls)
        )
    }

    static func transcriptSummary(_ use: SpeechEditControls.TranscriptUse) -> String {
        switch use {
        case .required: "What the take says."
        case .optional: "What the take says, if known."
        case .unused: "What the take says, if known; the model does not need it."
        }
    }

    /// One line per declared operation, with its vocabulary or grid, so a planner sees exactly what it
    /// may send.
    static func editSummary(_ controls: SpeechEditControls) -> String {
        func list(_ values: [String], open: String) -> String {
            values.isEmpty ? open : values.joined(separator: " / ")
        }
        func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
        let operations = controls.operations.map { operation -> String in
            let vocabulary = controls.vocabulary(for: operation)
            switch operation {
            case .emotion, .style:
                return "\(operation.rawValue) (" + list(vocabulary, open: "any label") + ")"
            case .paralinguistic:
                return "paralinguistic (targetTranscript with inline tags"
                    + (vocabulary.isEmpty ? ")" : ": " + vocabulary.joined(separator: " / ") + ")")
            case .replaceWords:
                return "replaceWords (original, new)"
            case .insertWords:
                return "insertWords (text, anchor, before)"
            case .removeWords:
                return "removeWords (text, optional anchor, before)"
            case .speed:
                return "speed (factor: "
                    + list(controls.speedFactors.map { SpeechEditControls.format($0) + "x" }, open: "any") + ")"
            case .pitch:
                return "pitch (semitones: " + list(controls.pitchSemitones.map(signed), open: "any") + ")"
            case .volume:
                return "volume (dB: " + list(controls.volumeDecibels.map(signed), open: "any") + ")"
            case .timbre:
                return "timbre (description)"
            case .addNonverbal:
                return "addNonverbal (sound: " + list(vocabulary, open: "any") + "; atEnd)"
            case .removeNonverbal:
                return "removeNonverbal (sound: " + list(vocabulary, open: "any") + "; absent = all)"
            case .denoise, .trimSilence, .deAccent, .dereverberate:
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
