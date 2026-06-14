/// Canonical audio-driven **lip-sync / face reenactment** surface (contract 1.4.0). Canonical
/// output is one **Video** artifact (`TalkingHeadResponse.video`), serialized round-trip form (C3).
///
/// A `source` face video is re-rendered so the mouth/lower-face matches the driving `audio` —
/// a canonical Video + Audio in, canonical Video out, which lets a TTS→talkingHead pipeline
/// compose (the TTS `Audio` output drops straight into `audio` here). Introduced by MuseTalk.
/// (A still portrait is driven by passing a looped/single-frame video as `source`.)
/// Package-specific levers — crop bbox shift, blend mode, batch size — ride `metaData` (C5).
public struct TalkingHeadRequest: CapabilityRequest {
    public static var capability: Capability { .talkingHead }

    /// The source face video to re-lip-sync.
    public let source: Video
    /// The driving speech audio (the new lip motion).
    public let audio: Audio
    /// Output frames per second (defaults to the source video's fps).
    public let fps: Double?
    public let mode: Mode?
    public let metaData: MetaData

    public init(source: Video,
                audio: Audio,
                fps: Double? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.source = source
        self.audio = audio
        self.fps = fps
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical talkingHead response — one `Video` artifact.
public struct TalkingHeadResponse: CapabilityResponse {
    public let video: Video
    public init(video: Video) { self.video = video }
}

/// Canonical descriptor shape for a talkingHead tool (C11).
public enum TalkingHeadContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .talkingHead,
            summary: summary,
            parameters: [
                ParameterSchema(name: "source", kind: .video, required: true,
                                summary: "The source face video to re-lip-sync."),
                ParameterSchema(name: "audio", kind: .audio, required: true,
                                summary: "The driving speech audio."),
                ParameterSchema(name: "fps", kind: .number, required: false,
                                summary: "Output frames per second (defaults to source fps)."),
            ],
            supportedModes: modes
        )
    }
}
