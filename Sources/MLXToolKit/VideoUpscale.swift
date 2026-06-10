import Foundation

/// Canonical video super-resolution request: upscale a video by an integer factor. The first
/// `Video → Video` transform of the visual optimization tier — chains onto T2V output or a
/// decode stage before encode.
/// Canonical output is a `Video` at `scale ×` the input frame dimensions (same duration/fps).
public struct VideoUpscaleRequest: CapabilityRequest {
    public static var capability: Capability { .videoUpscale }

    /// The video to upscale (canonical `Video` artifact, serialized container bytes).
    public let video: Video
    /// Requested integer scale factor; `nil` means the package's native/default scale.
    public let scale: Int?
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video, scale: Int? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.video = video
        self.scale = scale
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical video super-resolution response: the upscaled video and the factor actually applied.
public struct VideoUpscaleResponse: CapabilityResponse {
    public let video: Video
    /// The scale factor actually applied.
    public let appliedScale: Int

    public init(video: Video, appliedScale: Int) {
        self.video = video
        self.appliedScale = appliedScale
    }
}

/// The canonical descriptor shape for a video-upscale tool. A package fills in `name`/`summary`
/// and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum VideoUpscaleContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .videoUpscale,
            summary: summary,
            parameters: [
                ParameterSchema(name: "video", kind: .video, required: true,
                                summary: "The video to upscale."),
                ParameterSchema(name: "scale", kind: .integer, required: false,
                                summary: "Integer scale factor; omit for the package's native scale."),
            ],
            supportedModes: modes
        )
    }
}
