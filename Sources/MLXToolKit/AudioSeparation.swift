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
}

/// Canonical audio-separation request: split one mixture into named source stems.
///
/// Canonical output is `.wav` audio per stem (see `AudioSeparationResponse`). `stems` requests a
/// subset; an empty set means "every stem this package produces". A package may derive a
/// requested stem by complement (e.g. `instrumental = mixture - vocals`) when it can.
public struct AudioSeparationRequest: CapabilityRequest {
    public static var capability: Capability { .audioSeparation }

    /// The mixture to separate (canonical `Audio` artifact).
    public let audio: Audio
    /// Requested stems. Empty means all stems the package produces.
    public let stems: [Stem]
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio,
                stems: [Stem] = [],
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.audio = audio
        self.stems = stems
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical audio-separation response. Returns one `.wav` audio artifact per produced stem,
/// keyed by `Stem`, in serialized round-trip form.
public struct AudioSeparationResponse: CapabilityResponse {
    public let stems: [Stem: Audio]
    public init(stems: [Stem: Audio]) { self.stems = stems }

    /// Convenience access to a single produced stem.
    public subscript(_ stem: Stem) -> Audio? { stems[stem] }
}

/// The canonical descriptor shape for an audio-separation tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical
/// separation surface.
public enum AudioSeparationContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .audioSeparation,
            summary: summary,
            parameters: [
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The mixture audio to separate."),
                ParameterSchema(name: "stems", kind: .array, required: false,
                                summary: "Requested stems (e.g. vocals, instrumental); empty means all the model produces."),
            ],
            supportedModes: modes
        )
    }
}
