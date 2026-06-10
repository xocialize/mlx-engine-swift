import Foundation

/// Canonical video frame-interpolation request: synthesize intermediate frames to raise the
/// frame rate by an integer factor (2× inserts one midpoint between each adjacent pair, 4× three,
/// …). A `Video → Video` transform of the visual optimization tier — chains onto T2V output
/// (low-fps generations) or any decoded source before encode.
/// Canonical output is a `Video` at the same dimensions with `factor ×` the frame rate.
public struct FrameInterpolateRequest: CapabilityRequest {
    public static var capability: Capability { .frameInterpolate }

    /// The video to interpolate (canonical `Video` artifact).
    public let video: Video
    /// Requested integer frame-rate multiplier; `nil` means the package default (typically 2).
    public let factor: Int?
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video, factor: Int? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.video = video
        self.factor = factor
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical frame-interpolation response: the interpolated video and the multiplier applied.
public struct FrameInterpolateResponse: CapabilityResponse {
    public let video: Video
    /// The frame-rate multiplier actually applied.
    public let appliedFactor: Int

    public init(video: Video, appliedFactor: Int) {
        self.video = video
        self.appliedFactor = appliedFactor
    }
}

/// The canonical descriptor shape for a frame-interpolation tool.
public enum FrameInterpolateContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .frameInterpolate,
            summary: summary,
            parameters: [
                ParameterSchema(name: "video", kind: .video, required: true,
                                summary: "The video to frame-interpolate."),
                ParameterSchema(name: "factor", kind: .integer, required: false,
                                summary: "Integer frame-rate multiplier; omit for the package default (2)."),
            ],
            supportedModes: modes
        )
    }
}
