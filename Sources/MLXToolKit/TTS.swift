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
    public let mode: Mode?
    public let metaData: MetaData

    public init(text: String,
                voice: VoiceSelector = VoiceSelector(),
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.text = text
        self.voice = voice
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical TTS response. Always returns `.wav` audio in serialized round-trip form.
public struct TTSResponse: CapabilityResponse {
    public let audio: Audio
    public init(audio: Audio) { self.audio = audio }
}

/// The canonical descriptor shape for a TTS tool. A package fills in `name`/`summary` and
/// may extend `supportedModes`; the parameter schema is the canonical TTS surface.
public enum TTSContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .tts,
            summary: summary,
            parameters: [
                ParameterSchema(name: "text", kind: .string, required: true,
                                summary: "The text to speak."),
                ParameterSchema(name: "voice", kind: .object, required: false,
                                summary: "Canonical voice selection (named / referenceAudio / auto)."),
            ],
            supportedModes: modes
        )
    }
}
