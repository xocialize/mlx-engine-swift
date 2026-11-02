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
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio,
                stems: [Stem] = [],
                speaker: SpeakerSelection? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.audio = audio
        self.stems = stems
        self.speaker = speaker
        self.mode = mode
        self.metaData = metaData
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

/// What an **`audioSeparation`** surface can do beyond naming stems (contract 1.59.0, AB-A-0188): the
/// stems it produces and the speaker picks it honors. Optional — a surface without one separates by
/// stem exactly as before 1.59.0, and the engine refuses any `speaker` sent to it.
public struct AudioSeparationControls: Sendable, Codable, Equatable {
    /// The stems this surface produces, advertised for a consumer to choose from. Not enforced: a
    /// package may derive a requested stem by complement.
    public let stems: [Stem]
    /// The speaker picks this surface honors. The engine refuses any other before admission.
    public let speakerSelection: [SpeakerSelection.Kind]

    public init(stems: [Stem] = [], speakerSelection: [SpeakerSelection.Kind] = []) {
        self.stems = stems
        self.speakerSelection = speakerSelection
    }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it as
    /// `PackageError.unsupportedRequestFeature` before admission (the `MusicControls.refusal(for:)`
    /// pattern).
    public func refusal(for request: AudioSeparationRequest) -> String? {
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
}

/// The canonical descriptor shape for an audio-separation tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical
/// separation surface. A surface that declares `controls` with speaker picks also advertises
/// `speaker` (contract 1.59.0).
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
