import Foundation

/// A separated source within a mixture.
///
/// Stem is *canonical* — every separator names the sources it produces — so it lives in the
/// schema, not in `metaData` (C5). It is open/extensible (like `Mode`) because the stem set is
/// model-specific: a vocal separator yields `.vocals` / `.instrumental`, a 4-stem model yields
/// `.drums` / `.bass` / `.other` too, a soundtrack model yields `.music` / `.speech` / `.sfx`.
public struct Stem: RawRepresentable, Sendable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension Stem {
    // Common stems. Open set — a package documents the stems it produces.
    public static let vocals: Stem = "vocals"
    public static let instrumental: Stem = "instrumental"
    public static let drums: Stem = "drums"
    public static let bass: Stem = "bass"
    public static let other: Stem = "other"
    public static let music: Stem = "music"
    public static let speech: Stem = "speech"
    public static let sfx: Stem = "sfx"
    /// Singing only, every other sound removed (contract 1.59.0; AuK).
    public static let singing: Stem = "singing"
    /// Every human voice, speech and singing, everything else removed (contract 1.59.0; AuK).
    public static let voices: Stem = "voices"
    /// The one speaker a `SpeakerSelection` picks (contract 1.59.0).
    public static let speaker: Stem = "speaker"
    /// The sound a `targetDescription` names (contract 1.62.0; SAM-Audio).
    public static let target: Stem = "target"
    /// Everything except the described target (contract 1.62.0). Not `other`, which a fixed-stem
    /// model uses for "none of my named stems".
    public static let residual: Stem = "residual"
}

/// A stretch of the mixture where the described target is, or is not, sounding (contract 1.62.0,
/// AB-A-0268; SAM-Audio's `+` / `-` anchors). Seconds from the start of the mixture, `startSeconds`
/// inclusive, `endSeconds` exclusive. Valid ⇔ finite, `startSeconds >= 0`, `endSeconds >
/// startSeconds` (`isValid`). Nothing is clamped: a span past the end of the audio is refused by
/// whoever knows the length (`AudioSeparationControls.refusal(for:audioDurationSeconds:)`).
public struct AudioSeparationSpan: Sendable, Codable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    /// `true`: the target sounds here. `false`: it does not (a negative anchor).
    public let present: Bool

    public init(startSeconds: Double, endSeconds: Double, present: Bool = true) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.present = present
    }

    public var isValid: Bool {
        startSeconds.isFinite && endSeconds.isFinite && startSeconds >= 0 && endSeconds > startSeconds
    }

    func overlaps(_ other: AudioSeparationSpan) -> Bool {
        startSeconds < other.endSeconds && other.startSeconds < endSeconds
    }

    private enum CodingKeys: String, CodingKey { case startSeconds, endSeconds, present }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startSeconds = try c.decode(Double.self, forKey: .startSeconds)
        endSeconds = try c.decode(Double.self, forKey: .endSeconds)
        present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? true
    }
}

/// Which one speaker to keep from a multi-speaker mixture (contract 1.59.0, AB-A-0188; AuK). The kept
/// voice comes back as the `.speaker` stem.
public enum SpeakerSelection: Sendable, Codable, Equatable {
    /// The n-th speaker to start talking, from 1.
    case ordinal(Int)
    /// The speaker who says these words.
    case saying(String)

    /// The kinds a surface declares in `AudioSeparationControls.speakerSelection`.
    public enum Kind: String, Sendable, Codable {
        case ordinal, saying
    }

    public var kind: Kind {
        switch self {
        case .ordinal: .ordinal
        case .saying: .saying
        }
    }
}

/// Canonical audio-separation request: split one mixture into named source stems.
///
/// Canonical output is `.wav` audio per stem (see `AudioSeparationResponse`). `stems` requests a
/// subset; an empty set means "every stem this package produces". A package may derive a
/// requested stem by complement (e.g. `instrumental = mixture - vocals`) when it can.
public struct AudioSeparationRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .audioSeparation }

    /// The mixture to separate (canonical `Audio` artifact).
    public let audio: Audio
    /// Requested stems. Empty means all stems the package produces.
    public let stems: [Stem]
    /// Keep one speaker (contract 1.59.0): the response carries it as `.speaker`. Only for a surface
    /// declaring the kind in `AudioSeparationControls.speakerSelection`; the engine refuses it elsewhere,
    /// since a separator that ignored it would return every voice.
    public let speaker: SpeakerSelection?
    /// The sound to separate, in words (contract 1.62.0, AB-A-0268): "speech", "dog barking". The
    /// response carries it as `.target` and everything else as `.residual`; `stems` may narrow to
    /// one of the two. Only for a surface declaring `AudioSeparationControls.describedTarget`, whose
    /// `phrasing` says what wording the model was trained on; the engine refuses it elsewhere, since
    /// a fixed-stem separator that ignored it would return its own stems. Not `description`: that
    /// name belongs to `CustomStringConvertible`.
    public let targetDescription: String?
    /// Where the described target is or is not sounding (contract 1.62.0). Optional help for the
    /// model, valid only with `targetDescription` on a surface declaring
    /// `describedTarget.supportsSpans`. Empty = none.
    public let spans: [AudioSeparationSpan]
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio,
                stems: [Stem] = [],
                speaker: SpeakerSelection? = nil,
                targetDescription: String? = nil,
                spans: [AudioSeparationSpan] = [],
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.audio = audio
        self.stems = stems
        self.speaker = speaker
        self.targetDescription = targetDescription
        self.spans = spans
        self.mode = mode
        self.metaData = metaData
    }

    private enum CodingKeys: String, CodingKey {
        case audio, stems, speaker, targetDescription, spans, mode, metaData
    }

    /// Pre-1.62 JSON carries neither `targetDescription` nor `spans`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio = try c.decode(Audio.self, forKey: .audio)
        stems = try c.decode([Stem].self, forKey: .stems)
        speaker = try c.decodeIfPresent(SpeakerSelection.self, forKey: .speaker)
        targetDescription = try c.decodeIfPresent(String.self, forKey: .targetDescription)
        spans = try c.decodeIfPresent([AudioSeparationSpan].self, forKey: .spans) ?? []
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode)
        metaData = try c.decode(MetaData.self, forKey: .metaData)
    }

    /// Whether the request uses a lever a surface must declare (a speaker pick, a described target,
    /// spans). The engine refuses such a request to a surface with no `AudioSeparationControls`.
    public var declaredLever: String? {
        if let speaker { return "speaker(.\(speaker.kind.rawValue))" }
        if targetDescription != nil { return "targetDescription" }
        if !spans.isEmpty { return "spans" }
        return nil
    }
}

/// Canonical audio-separation response. Returns one `.wav` audio artifact per produced stem,
/// keyed by `Stem`, in serialized round-trip form.
public struct AudioSeparationResponse: CapabilityResponse, Codable {
    public let stems: [Stem: Audio]
    public init(stems: [Stem: Audio]) { self.stems = stems }

    /// Convenience access to a single produced stem.
    public subscript(_ stem: Stem) -> Audio? { stems[stem] }
}

/// A surface that separates the sound a caller describes (contract 1.62.0, AB-A-0268; SAM-Audio).
/// One value rather than two flags, so "spans without a described target" cannot be declared.
public struct DescribedTargetControls: Sendable, Codable, Equatable {
    /// Whether the surface takes `AudioSeparationRequest.spans`.
    public let supportsSpans: Bool
    /// What wording works, for a host to show beside the field and an agent to read in the
    /// descriptor — SAM-Audio: "a short lowercase noun phrase ('speech', 'dog barking'); sentences
    /// do not work". Guidance, not enforced: the engine cannot judge a phrase.
    public let phrasing: String?

    public init(supportsSpans: Bool = false, phrasing: String? = nil) {
        self.supportsSpans = supportsSpans
        self.phrasing = phrasing
    }

    private enum CodingKeys: String, CodingKey { case supportsSpans, phrasing }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportsSpans = try c.decodeIfPresent(Bool.self, forKey: .supportsSpans) ?? false
        phrasing = try c.decodeIfPresent(String.self, forKey: .phrasing)
    }
}

/// What an **`audioSeparation`** surface can do beyond naming stems (contract 1.59.0, AB-A-0188;
/// 1.62.0, AB-A-0268): the stems it produces, the speaker picks it honors, and whether it separates
/// a described target. Optional — a surface without one separates by stem exactly as before 1.59.0,
/// and the engine refuses any `speaker`, `targetDescription` or `spans` sent to it.
public struct AudioSeparationControls: Sendable, Codable, Equatable {
    /// The stems this surface produces, advertised for a consumer to choose from. Not enforced: a
    /// package may derive a requested stem by complement.
    public let stems: [Stem]
    /// The speaker picks this surface honors. The engine refuses any other before admission.
    public let speakerSelection: [SpeakerSelection.Kind]
    /// Non-nil: the surface separates a described target (contract 1.62.0). Nil = it does not, which
    /// is every pre-1.62 declaration; synthesized decoding reads a missing key as nil.
    public let describedTarget: DescribedTargetControls?

    public init(stems: [Stem] = [], speakerSelection: [SpeakerSelection.Kind] = [],
                describedTarget: DescribedTargetControls? = nil) {
        self.stems = stems
        self.speakerSelection = speakerSelection
        self.describedTarget = describedTarget
    }

    /// The stems this surface produces without being told what to listen for — `stems` less
    /// `.target` / `.residual`. Empty on a description-only surface (SAM-Audio), which therefore has
    /// nothing to return for a request that names no target.
    public var fixedStems: [Stem] { stems.filter { $0 != .target && $0 != .residual } }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it as
    /// `PackageError.unsupportedRequestFeature` before admission (the `MusicControls.refusal(for:)`
    /// pattern).
    ///
    /// `audioDurationSeconds` is the mixture's length where the caller knows it. `Audio` does not
    /// state one, so the engine passes nil and judges span order only; a package, which decodes the
    /// audio anyway, calls this again with the length and refuses a span past the end with the same
    /// words.
    public func refusal(for request: AudioSeparationRequest,
                        audioDurationSeconds: Double? = nil) -> String? {
        if let reason = describedTargetRefusal(for: request, audioDurationSeconds: audioDurationSeconds) {
            return reason
        }
        guard let speaker = request.speaker else { return nil }
        guard speakerSelection.contains(speaker.kind) else {
            return "speaker(.\(speaker.kind.rawValue)) — this surface declares no such speaker pick "
                + "(AudioSeparationControls.speakerSelection: "
                + (speakerSelection.isEmpty ? "none" : speakerSelection.map(\.rawValue).joined(separator: " / "))
                + ")"
        }
        switch speaker {
        case .ordinal(let n) where n < 1:
            return "speaker(.ordinal(\(n))) — the first speaker to start talking is 1"
        case .saying(let words) where words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "speaker(.saying) — name words the speaker says"
        default:
            return nil
        }
    }

    private func describedTargetRefusal(for request: AudioSeparationRequest,
                                        audioDurationSeconds: Double?) -> String? {
        let describedStems = request.stems.filter { $0 == .target || $0 == .residual }
        guard let description = request.targetDescription else {
            if !request.spans.isEmpty {
                return "spans — spans say where a described target sounds; send targetDescription with them"
            }
            if let stem = describedStems.first {
                return "stems(\(stem.rawValue)) — the \(stem.rawValue) stem exists only for a "
                    + "described target; send targetDescription"
            }
            if describedTarget != nil, fixedStems.isEmpty, request.speaker == nil {
                return "targetDescription — this surface separates only what is described and "
                    + "declares no fixed stems; name the sound to separate"
            }
            return nil
        }
        guard let declared = describedTarget else {
            return "targetDescription — this surface declares no described-target separation "
                + "(AudioSeparationControls.describedTarget)"
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "targetDescription — name the sound to separate"
        }
        if request.speaker != nil {
            return "targetDescription with speaker — two ways of naming the target; send one"
        }
        if let stem = request.stems.first(where: { $0 != .target && $0 != .residual }) {
            return "stems(\(stem.rawValue)) — a described target returns target and residual only"
        }
        guard !request.spans.isEmpty else { return nil }
        guard declared.supportsSpans else {
            return "spans — this surface declares no span anchors "
                + "(AudioSeparationControls.describedTarget.supportsSpans)"
        }
        for (index, span) in request.spans.enumerated() {
            let name = "spans[\(index)] (\(span.startSeconds)–\(span.endSeconds) s)"
            guard span.isValid else {
                return "\(name) — a span is finite, starts at 0 or later and ends after it starts"
            }
            if let length = audioDurationSeconds, span.endSeconds > length {
                return "\(name) — past the end of the audio (\(length) s)"
            }
            if let clash = request.spans[..<index].first(where: { $0.present != span.present && $0.overlaps(span) }) {
                return "\(name) — overlaps \(clash.startSeconds)–\(clash.endSeconds) s, which says the "
                    + "opposite about whether the target is present"
            }
        }
        return nil
    }
}

/// The canonical descriptor shape for an audio-separation tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical
/// separation surface. A surface that declares `controls` with speaker picks also advertises
/// `speaker` (contract 1.59.0); one that declares a described target advertises `targetDescription`
/// — required when it has no fixed stems — and, with `supportsSpans`, `spans` (contract 1.62.0).
public enum AudioSeparationContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: AudioSeparationControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "audio", kind: .audio, required: true,
                            summary: "The mixture audio to separate."),
            ParameterSchema(name: "stems", kind: .array, required: false,
                            summary: stemsSummary(controls)),
        ]
        if let picks = controls?.speakerSelection, !picks.isEmpty {
            parameters.append(ParameterSchema(
                name: "speaker", kind: .object, required: false,
                summary: "Keep one speaker, returned as the speaker stem: "
                    + picks.map { $0 == .ordinal ? "ordinal (the n-th to start talking, from 1)"
                                                 : "saying (words that speaker says)" }
                        .joined(separator: "; ") + "."))
        }
        if let described = controls?.describedTarget {
            parameters.append(ParameterSchema(
                name: "targetDescription", kind: .string,
                required: controls?.fixedStems.isEmpty == true && controls?.speakerSelection.isEmpty == true,
                summary: "The sound to separate, in words; returned as the target stem, with everything "
                    + "else as the residual stem." + (described.phrasing.map { " \($0)" } ?? "")))
            if described.supportsSpans {
                parameters.append(ParameterSchema(
                    name: "spans", kind: .array, required: false,
                    summary: "Where the described target is (present: true) or is not (present: false) "
                        + "sounding: {startSeconds, endSeconds, present}, seconds from the start of the audio."))
            }
        }
        return ToolDescriptor(
            name: name,
            capability: .audioSeparation,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map(SurfaceControls.audioSeparation)
        )
    }

    static func stemsSummary(_ controls: AudioSeparationControls?) -> String {
        guard let stems = controls?.stems, !stems.isEmpty else {
            return "Requested stems (e.g. vocals, instrumental); empty means all the model produces."
        }
        return "Requested stems (" + stems.map(\.rawValue).joined(separator: " / ")
            + "); empty means all the model produces."
    }
}
