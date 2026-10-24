import Foundation

// MARK: - The music (lyrics-to-song) surface — contract 1.56.0 (AB-A-0201 / AB-A-0202)
//
// One capability for three models that do not share a protocol: YuE2-3B (plans an editable ABC
// score, then sings it), ACE-Step 1.5 (a planner LM emits BPM / key / duration anchors, a flow DiT
// renders; covers, repaints and extensions of a source clip; timbre from a reference clip; LRC
// timestamps out) and MiniMax Music 3 (caption + lyrics, up to five minutes, nothing else). The
// canonical core is what all three understand — caption, lyrics with section tags, a length, a seed,
// a guidance scale → one stereo `.wav` and whether it was cut short — and everything one or two of
// them add is a PACKAGE-DECLARED FEATURE (`MusicControls.features`): a host renders the form the
// declaration describes, and the engine refuses an undeclared feature before admission, so a
// supplied score or source clip is never silently dropped (the a2v / speechEdit rule).

/// How a music surface plans before it sings (YuE2's `cot`). Nil on a request = the package's
/// default. A surface declares the modes it honors in `MusicControls.planningModes`.
public enum MusicPlanningMode: String, Sendable, Codable, CaseIterable {
    /// A chord-annotated ABC score first, then the song from it. The score comes back on
    /// `MusicResponse.score` — the editable artifact a consumer re-renders after changing it.
    case full
    /// A melody-only score first.
    case melody
    /// No score: lyrics and caption straight to audio.
    case off
}

/// What to do with a source clip (ACE-Step 1.5's `src_audio` modes). Each case maps 1:1 onto the
/// `MusicEditMode` a surface declares, the `SpeechEditOperation.kind` pattern. Switch over this with
/// `@unknown default`: a later mode arrives as a new case at a minor version.
public enum MusicEditOperation: Sendable, Codable, Equatable {
    /// Re-render the source as a new performance of the same song. `strength` 0…1: how far from the
    /// source the result may drift (0 = keep it, 1 = free).
    case cover(strength: Double)
    /// Regenerate the stretch between `start` and `end` seconds of the source, keeping the rest.
    case repaint(start: Double, end: Double)
    /// Continue the source: `leading` seconds before it, `trailing` seconds after it.
    case extend(leading: Double = 0, trailing: Double)

    /// The declaration this operation requires a surface to have made.
    public var kind: MusicEditMode {
        switch self {
        case .cover: .cover
        case .repaint: .repaint
        case .extend: .extend
        }
    }
}

/// The edit kinds a music surface can honor, one per `MusicEditOperation` case.
public enum MusicEditMode: String, Sendable, Codable, CaseIterable {
    case cover, repaint, extend
}

/// A source clip together with what to do to it. One value, so a request cannot carry a source
/// without an operation or an operation without a source — the invalid combinations do not exist.
public struct MusicEdit: Sendable, Codable, Equatable {
    /// The clip to cover, repaint or extend (canonical `Audio`).
    public let source: Audio
    public let operation: MusicEditOperation

    public init(source: Audio, operation: MusicEditOperation) {
        self.source = source
        self.operation = operation
    }
}

/// Musical anchors a planner honors instead of inventing (ACE-Step 1.5's planner CoT emits BPM, key
/// and time signature; a caller may pin any of them). Every field optional; an all-nil value asks for
/// nothing (`isEmpty`). Strings, not enums, because key and signature spellings are a model's
/// vocabulary ("F# minor", "Gb minor", "6/8") and the contract carries the plane, not the vocabulary.
public struct MusicAnchors: Sendable, Codable, Equatable {
    /// Beats per minute.
    public let bpm: Double?
    /// The key, as the model spells it ("C major", "A minor").
    public let key: String?
    /// The time signature ("4/4", "6/8").
    public let timeSignature: String?

    public init(bpm: Double? = nil, key: String? = nil, timeSignature: String? = nil) {
        self.bpm = bpm
        self.key = key
        self.timeSignature = timeSignature
    }

    public var isEmpty: Bool { bpm == nil && key == nil && timeSignature == nil }
}

/// One timed stretch of the sung lyrics (ACE-Step 1.5's LRC output). Granularity is the package's:
/// a word or a line per entry, documented on the package. `end` is nil where the model times starts
/// only, as LRC does.
public struct MusicLyricTimestamp: Sendable, Codable, Equatable {
    public let text: String
    /// Seconds from the start of `MusicResponse.audio`.
    public let start: Double
    public let end: Double?

    public init(text: String, start: Double, end: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The optional parts of the music surface a package declares (`MusicControls.features`). A host
/// renders a form element per declared feature; the engine refuses an undeclared INPUT feature
/// before admission (every case but `.timestamps` and `.guidanceScale`, see each).
public enum MusicFeature: String, Sendable, Codable, CaseIterable {
    /// `MusicRequest.planning` is honored, and `MusicResponse.score` carries the plan (YuE2). Declared
    /// together with a non-empty `planningModes`. Engine-enforced.
    case planning
    /// `MusicRequest.score` is accepted: a supplied ABC score is rendered rather than planned (YuE2;
    /// re-render an edited plan, or a cover transcribed upstream). Engine-enforced.
    case score
    /// `MusicRequest.referenceAudio` is honored for timbre (ACE-Step). Engine-enforced.
    case referenceAudio
    /// `MusicRequest.edit` is honored: a source clip is covered, repainted or extended per the
    /// declared `editModes` (ACE-Step). Engine-enforced, per mode.
    case sourceAudio
    /// `MusicRequest.anchors` is honored (ACE-Step's planner). Engine-enforced.
    case anchors
    /// `MusicRequest.vocalLanguage` is honored, within `vocalLanguages` when declared (ACE-Step).
    /// Engine-enforced.
    case vocalLanguage
    /// `MusicResponse.timestamps` is produced (ACE-Step's LRC). OUTPUT-side: a host knows to render a
    /// lyric timeline. Nothing to refuse.
    case timestamps
    /// `MusicRequest.guidanceScale` steers the run. A surface without CFG (ACE-Step turbo: eight fixed
    /// steps) omits it, so a host hides the slider. NOT refused when sent anyway: an ignored scale
    /// still yields the song asked for (the `steps` precedent on fixed-step image surfaces), unlike
    /// an ignored score or source clip.
    case guidanceScale
}

/// What a **`music`** surface can do (contract 1.56.0): the routing-time declaration a host reads to
/// build the form, and the engine reads to refuse what the form should not have offered.
///
/// Required on every music surface (`MusicContract.descriptor(controls:)` will not build one without
/// it), as `SpeechEditControls` is: the three first providers differ in almost every optional lever,
/// so an undeclared surface tells a host nothing it can render.
public struct MusicControls: Sendable, Codable, Equatable {
    /// The optional features this surface honors. The core (caption, lyrics, durationSeconds, seed) is
    /// always honored and never declared.
    public let features: Set<MusicFeature>
    /// The planning modes honored (non-empty ⇔ `.planning` declared). A request naming another is
    /// refused before admission.
    public let planningModes: [MusicPlanningMode]
    /// The source-clip edits honored (non-empty ⇔ `.sourceAudio` declared). A request asking for
    /// another is refused before admission.
    public let editModes: [MusicEditMode]
    /// The vocal languages honored, BCP-47 ("en", "zh", "ja"), compared case-insensitively. Non-empty =
    /// the only tags admitted; empty with `.vocalLanguage` declared = open, and the package judges the
    /// tag. Declaring tags without the feature is a declaration bug (`declarationProblems`).
    public let vocalLanguages: [String]
    /// The longest song this surface renders, in seconds (YuE2: 360; ACE-Step 1.5: 600; MiniMax
    /// Music 3: 300). Engine-enforced: a `durationSeconds` above it is refused before admission. nil =
    /// unstated, nothing refused.
    public let maxDurationSeconds: Double?

    public init(features: Set<MusicFeature>,
                planningModes: [MusicPlanningMode] = [],
                editModes: [MusicEditMode] = [],
                vocalLanguages: [String] = [],
                maxDurationSeconds: Double? = nil) {
        self.features = features
        self.planningModes = planningModes
        self.editModes = editModes
        self.vocalLanguages = vocalLanguages
        self.maxDurationSeconds = maxDurationSeconds
    }

    public func declares(_ feature: MusicFeature) -> Bool { features.contains(feature) }

    /// Internal inconsistencies of the declaration — a feature whose vocabulary is missing, or a
    /// vocabulary whose feature is not declared. Empty for a coherent declaration. A package's manifest
    /// test asserts this is empty (the C11 "honest descriptor" expectation).
    public var declarationProblems: [String] {
        var problems: [String] = []
        if declares(.planning), planningModes.isEmpty {
            problems.append("planning is declared with no planningModes")
        }
        if !declares(.planning), !planningModes.isEmpty {
            problems.append("planningModes are declared without the planning feature")
        }
        if declares(.sourceAudio), editModes.isEmpty {
            problems.append("sourceAudio is declared with no editModes")
        }
        if !declares(.sourceAudio), !editModes.isEmpty {
            problems.append("editModes are declared without the sourceAudio feature")
        }
        if !declares(.vocalLanguage), !vocalLanguages.isEmpty {
            problems.append("vocalLanguages are declared without the vocalLanguage feature")
        }
        if let limit = maxDurationSeconds, !(limit > 0) {
            problems.append("maxDurationSeconds must be positive")
        }
        return problems
    }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it as
    /// `PackageError.unsupportedRequestFeature` before admission; a package driven directly may call it
    /// first for the same refusal. Checks only what an ignored field would make WRONG — a supplied
    /// score, clip, anchor or language, a planning mode, a length past the declared maximum — never
    /// `guidanceScale` (see `MusicFeature.guidanceScale`).
    public func refusal(for request: MusicRequest) -> String? {
        if let planning = request.planning {
            guard declares(.planning) else {
                return "planning(.\(planning.rawValue)) — this surface declares no planning "
                    + "(MusicControls.features); drop it, or choose a package that plans a score"
            }
            guard planningModes.contains(planning) else {
                return "planning(.\(planning.rawValue)) — not one of the planning modes this surface "
                    + "declares (MusicControls.planningModes: "
                    + planningModes.map(\.rawValue).joined(separator: " / ") + ")"
            }
        }
        if request.score != nil, !declares(.score) {
            return "score — this surface declares no score input (MusicControls.features); it would "
                + "plan its own, so choose a package that renders a supplied score"
        }
        if request.referenceAudio != nil, !declares(.referenceAudio) {
            return "referenceAudio — this surface declares no timbre reference (MusicControls.features); "
                + "drop the clip, or choose a package that declares referenceAudio"
        }
        if let edit = request.edit {
            let kind = edit.operation.kind
            guard declares(.sourceAudio) else {
                return "edit(.\(kind.rawValue)) — this surface declares no source-clip editing "
                    + "(MusicControls.features); it would write a new song instead, so choose a package "
                    + "that declares sourceAudio"
            }
            guard editModes.contains(kind) else {
                return "edit(.\(kind.rawValue)) — not one of the edit modes this surface declares "
                    + "(MusicControls.editModes: " + editModes.map(\.rawValue).joined(separator: " / ") + ")"
            }
        }
        if let anchors = request.anchors, !anchors.isEmpty, !declares(.anchors) {
            return "anchors — this surface declares no bpm / key / time-signature anchors "
                + "(MusicControls.features); put them in the caption, or choose a package that declares anchors"
        }
        if let language = request.vocalLanguage {
            guard declares(.vocalLanguage) else {
                return "vocalLanguage(\"\(language)\") — this surface declares no vocal-language control "
                    + "(MusicControls.features); it sings the lyrics' script as written"
            }
            if !vocalLanguages.isEmpty,
               !vocalLanguages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
                return "vocalLanguage(\"\(language)\") — not one of the languages this surface declares "
                    + "(MusicControls.vocalLanguages: " + vocalLanguages.joined(separator: " / ") + ")"
            }
        }
        if let limit = maxDurationSeconds, let seconds = request.durationSeconds, seconds > limit {
            return "durationSeconds(\(Self.format(seconds))) — this surface renders at most "
                + "\(Self.format(limit)) s (MusicControls.maxDurationSeconds)"
        }
        return nil
    }

    static func format(_ value: Double) -> String { String(format: "%g", value) }
}

/// Canonical **music** (lyrics-to-song) request (contract 1.56.0, AB-A-0201 / AB-A-0202). Introduced
/// for YuE2-3B (`mlx-yue2-swift`, AB-T-0350), ACE-Step 1.5 (E25) and MiniMax Music 3 (AB-T-0351).
///
/// The core — `caption`, `lyrics`, `durationSeconds`, `seed` — is honored by every music surface.
/// Everything else is honored only where the surface declares the matching `MusicFeature`; the engine
/// refuses the rest before admission (`MusicControls.refusal(for:)`). Package levers that steer one
/// model family — sampling temperatures, ODE step counts, the LM tier — ride `metaData` (C5).
public struct MusicRequest: CapabilityRequest {
    public static var capability: Capability { .music }

    /// The style text: genre, mood, instrumentation, vocal description. YuE2 calls it the style tags,
    /// ACE-Step the caption, MiniMax a structured caption (global / vocal / arrangement); each package
    /// documents the phrasing it responds to best.
    public let caption: String
    /// The words, with the section tags the model expects inline — `[verse]`, `[chorus]`, `[bridge]`,
    /// `[outro]` — each package documents its tag set. Empty for an instrumental where the package
    /// supports one (it documents how; ACE-Step: an `[Instrumental]` tag).
    public let lyrics: String
    /// The length the song should run to, in seconds. A package that renders to a length (ACE-Step,
    /// MiniMax) renders to it; one whose length the song itself decides (YuE2) treats it as a cap and
    /// reports `MusicResponse.truncated` when the cap cut the song. Nil = the package's default.
    /// Refused above the surface's `maxDurationSeconds`.
    public let durationSeconds: Double?
    public let seed: UInt64?
    /// Classifier-free guidance scale. Ignored, not refused, by a surface that declares no
    /// `.guidanceScale` (the turbo tiers).
    public let guidanceScale: Double?
    /// Plan a score first (`.full` / `.melody`) or not (`.off`); nil = the package's default. Needs
    /// `.planning`.
    public let planning: MusicPlanningMode?
    /// A supplied ABC score to render instead of planning one. Needs `.score`.
    public let score: String?
    /// A clip whose timbre the vocals should take. Needs `.referenceAudio`.
    public let referenceAudio: Audio?
    /// A source clip and what to do to it (cover / repaint / extend). Needs `.sourceAudio` and the
    /// operation's mode in `editModes`.
    public let edit: MusicEdit?
    /// BPM / key / time signature the planner must honor. Needs `.anchors` (an empty value asks for
    /// nothing and is not refused).
    public let anchors: MusicAnchors?
    /// BCP-47 tag of the language to sing in; nil = the lyrics' own script. Needs `.vocalLanguage`.
    public let vocalLanguage: String?
    public let mode: Mode?
    public let metaData: MetaData

    public init(caption: String,
                lyrics: String,
                durationSeconds: Double? = nil,
                seed: UInt64? = nil,
                guidanceScale: Double? = nil,
                planning: MusicPlanningMode? = nil,
                score: String? = nil,
                referenceAudio: Audio? = nil,
                edit: MusicEdit? = nil,
                anchors: MusicAnchors? = nil,
                vocalLanguage: String? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.caption = caption
        self.lyrics = lyrics
        self.durationSeconds = durationSeconds
        self.seed = seed
        self.guidanceScale = guidanceScale
        self.planning = planning
        self.score = score
        self.referenceAudio = referenceAudio
        self.edit = edit
        self.anchors = anchors
        self.vocalLanguage = vocalLanguage
        self.mode = mode
        self.metaData = metaData
    }

    /// The declared features this request draws on — what the engine checks the surface for. The core
    /// fields contribute nothing; `guidanceScale` contributes nothing (not refused).
    public var requestedFeatures: Set<MusicFeature> {
        var features: Set<MusicFeature> = []
        if planning != nil { features.insert(.planning) }
        if score != nil { features.insert(.score) }
        if referenceAudio != nil { features.insert(.referenceAudio) }
        if edit != nil { features.insert(.sourceAudio) }
        if let anchors, !anchors.isEmpty { features.insert(.anchors) }
        if vocalLanguage != nil { features.insert(.vocalLanguage) }
        return features
    }
}

/// Canonical music response: the song as one `Audio` (`.wav`, `CanonicalOutput.audio`) plus what the
/// run planned and whether it was cut short.
///
/// **Conformance expectations (C2/C3).** `audio.sampleRate` and `audio.channels` are SET — a song's
/// rate is not a convention a consumer may assume (the fleet's three first providers render 48 kHz
/// stereo; MiniMax's card and its mlx-audio port disagree on its rate, which is exactly why the
/// response states it). `truncated` is honest: true whenever a token cap, a step cap or
/// `durationSeconds` cut the plan or the song before its natural end. `score` is present on every
/// run of a surface declaring `.planning` (the plan it made or the score it was given, in ABC);
/// `timestamps` on every run of one declaring `.timestamps`.
public struct MusicResponse: CapabilityResponse {
    public let audio: Audio
    /// The plan or the song hit a cap before its natural end.
    public let truncated: Bool
    /// The ABC score the model planned or was given — the editable artifact. Nil on a surface that
    /// does not plan.
    public let score: String?
    /// The anchors the planner settled on (ACE-Step's CoT) or was given; nil where nothing planned them.
    public let anchors: MusicAnchors?
    /// Timed lyrics, in order; nil on a surface that declares no `.timestamps`.
    public let timestamps: [MusicLyricTimestamp]?

    public init(audio: Audio,
                truncated: Bool = false,
                score: String? = nil,
                anchors: MusicAnchors? = nil,
                timestamps: [MusicLyricTimestamp]? = nil) {
        self.audio = audio
        self.truncated = truncated
        self.score = score
        self.anchors = anchors
        self.timestamps = timestamps
    }
}

/// Canonical descriptor shape for a music tool (C11).
///
/// Born declared, like `speechEdit`: the declaration is a parameter, and the advertised schema is
/// derived from it — only a declared feature's parameter is offered, so a planner is never handed a
/// knob the engine would refuse (the `declaring(adapters:)` rule). The core parameters are always
/// present.
public enum MusicContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: MusicControls) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "caption", kind: .string, required: true,
                            summary: "Style text: genre, mood, instrumentation, vocal description."),
            ParameterSchema(name: "lyrics", kind: .string, required: true,
                            summary: "The words, with section tags inline ([verse], [chorus], …)."),
            ParameterSchema(name: "durationSeconds", kind: .number, required: false,
                            summary: durationSummary(controls)),
            ParameterSchema(name: "seed", kind: .integer, required: false,
                            summary: "RNG seed for reproducibility."),
        ]
        if controls.declares(.guidanceScale) {
            parameters.append(ParameterSchema(name: "guidanceScale", kind: .number, required: false,
                                              summary: "CFG scale."))
        }
        if controls.declares(.planning) {
            parameters.append(ParameterSchema(
                name: "planning", kind: .string, required: false,
                summary: "Plan a score first: "
                    + controls.planningModes.map(\.rawValue).joined(separator: " / ")
                    + ". The plan comes back as `score` (ABC)."))
        }
        if controls.declares(.score) {
            parameters.append(ParameterSchema(name: "score", kind: .string, required: false,
                                              summary: "An ABC score to render instead of planning one."))
        }
        if controls.declares(.referenceAudio) {
            parameters.append(ParameterSchema(name: "referenceAudio", kind: .audio, required: false,
                                              summary: "A clip whose timbre the vocals take."))
        }
        if controls.declares(.sourceAudio) {
            parameters.append(ParameterSchema(
                name: "edit", kind: .object, required: false,
                summary: "A source clip and what to do to it: "
                    + controls.editModes.map(Self.editSummary).joined(separator: "; ") + "."))
        }
        if controls.declares(.anchors) {
            parameters.append(ParameterSchema(name: "anchors", kind: .object, required: false,
                                              summary: "{bpm?, key?, timeSignature?} the planner must honor."))
        }
        if controls.declares(.vocalLanguage) {
            parameters.append(ParameterSchema(
                name: "vocalLanguage", kind: .string, required: false,
                summary: "BCP-47 tag of the language to sing in"
                    + (controls.vocalLanguages.isEmpty
                        ? "." : ": " + controls.vocalLanguages.joined(separator: " / ") + ".")))
        }
        return ToolDescriptor(
            name: name,
            capability: .music,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: .music(controls)
        )
    }

    static func durationSummary(_ controls: MusicControls) -> String {
        var summary = "Target length in seconds"
        if let limit = controls.maxDurationSeconds {
            summary += " (up to " + MusicControls.format(limit) + ")"
        }
        return summary + "; a package that plans its own length treats it as a cap and reports `truncated`."
    }

    static func editSummary(_ mode: MusicEditMode) -> String {
        switch mode {
        case .cover: "cover {strength 0…1}"
        case .repaint: "repaint {start, end} seconds"
        case .extend: "extend {leading?, trailing} seconds"
        }
    }
}
