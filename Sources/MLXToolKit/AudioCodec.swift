import Foundation

/// Canonical neural-audio-codec request: encode an audio clip into discrete codec tokens
/// (the inverse — decoding tokens back to audio — is a separate future capability). Canonical
/// output is **codes** (see `AudioCodecResponse`).
public struct AudioCodecRequest: CapabilityRequest {
    public static var capability: Capability { .audioCodec }

    /// The audio to encode (canonical `Audio` artifact; any rate/channels — the package resamples
    /// to the codec's expected rate).
    public let audio: Audio
    public let mode: Mode?
    public let metaData: MetaData

    public init(audio: Audio, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.audio = audio
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical neural-audio-codec response: the discrete token grid produced by the encoder.
/// `codes[q][t]` is the codebook index for quantizer `q` at frame `t` (residual/split RVQ).
public struct AudioCodecResponse: CapabilityResponse {
    /// Per-codebook token rows: `codes.count == numCodebooks`, each row length = number of frames.
    public let codes: [[Int32]]
    /// Number of codebooks / quantizers (== `codes.count`).
    public let numCodebooks: Int
    /// Token frame rate in Hz (e.g. 12.5).
    public let frameRate: Double

    public init(codes: [[Int32]], numCodebooks: Int, frameRate: Double) {
        self.codes = codes
        self.numCodebooks = numCodebooks
        self.frameRate = frameRate
    }
}

/// The canonical descriptor shape for an audio-codec (encode) tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum AudioCodecContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .audioCodec,
            summary: summary,
            parameters: [
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The audio to encode into discrete codec tokens."),
            ],
            supportedModes: modes
        )
    }
}
