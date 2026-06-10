import Foundation

/// Canonical audio-polish (mastering) request: clean up + loudness-normalize an audio clip — the
/// audio analog of an image/video "optimize" pass, applied to the **output** of a TTS/mix stage.
/// Canonical output is `.wav` audio (see `AudioPolishResponse`).
///
/// The loudness/mastering target is a per-request `mode` (e.g. `.broadcast` -23 LUFS, `.streaming`
/// -16 LUFS) — the audio analog of a visual quality target. Package-specific stage knobs ride
/// `metaData`.
public struct AudioPolishRequest: CapabilityRequest {
    public static var capability: Capability { .audioPolish }

    /// The audio to polish/master (canonical `Audio` artifact).
    public let audio: Audio
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.audio = audio
        self.mode = mode
        self.metaData = metaData
    }
}

extension Mode {
    // Common audio-mastering targets a package may honor. Open/extensible.
    public static let broadcast: Mode = "broadcast"     // EBU R128, -23 LUFS
    public static let streaming: Mode = "streaming"     // -16 LUFS
    public static let transparent: Mode = "transparent" // minimal processing
}

/// Canonical audio-polish response: the mastered audio (`.wav`), plus the measured integrated
/// loudness before/after so a caller (or the pipeline planner) can verify the target was hit.
public struct AudioPolishResponse: CapabilityResponse {
    public let audio: Audio
    /// Integrated loudness (LUFS) of the input, if measured.
    public let inputLUFS: Double?
    /// Integrated loudness (LUFS) of the output, if measured.
    public let outputLUFS: Double?

    public init(audio: Audio, inputLUFS: Double? = nil, outputLUFS: Double? = nil) {
        self.audio = audio
        self.inputLUFS = inputLUFS
        self.outputLUFS = outputLUFS
    }
}

/// The canonical descriptor shape for an audio-polish tool. A package fills in `name`/`summary` and
/// may extend `supportedModes` (mastering targets); the parameter schema is the canonical surface.
public enum AudioPolishContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .audioPolish,
            summary: summary,
            parameters: [
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The audio to polish / loudness-normalize."),
            ],
            supportedModes: modes
        )
    }
}
