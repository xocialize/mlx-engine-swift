import Foundation

/// Canonical video frame-interpolation request: synthesize intermediate frames to raise the
/// frame rate by an integer factor (2× inserts one midpoint between each adjacent pair, 4× three,
/// …). A `Video → Video` transform of the visual optimization tier — chains onto T2V output
/// (low-fps generations) or any decoded source before encode.
/// Canonical output is a `Video` at the same dimensions with `factor ×` the frame rate.
public struct FrameInterpolateRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .frameInterpolate }

    /// The video to interpolate (canonical `Video` artifact).
    public let video: Video
    /// Requested integer frame-rate multiplier; `nil` means the package default (typically 2).
    public let factor: Int?
    /// The output frame rate to retime to, in fps (contract 1.61.0, AB-A-0236) — instead of an
    /// integer `factor`; a request names one or the other. A rate that is not a whole multiple of the
    /// source's (24 → 60) is the arbitrary-timestep case RIFE takes natively: the package places each
    /// output frame on the target's time grid and interpolates it at the matching fractional position
    /// between its two nearest source frames. **Declaration-gated** (`FrameInterpolateControls.
    /// targetFrameRate`, with `ratios`).
    public let targetFrameRate: Double?
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video, factor: Int? = nil, targetFrameRate: Double? = nil,
                mode: Mode? = nil, metaData: MetaData = [:]) {
        self.video = video
        self.factor = factor
        self.targetFrameRate = targetFrameRate
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical frame-interpolation response: the interpolated video and the multiplier applied.
public struct FrameInterpolateResponse: CapabilityResponse, Codable {
    public let video: Video
    /// The frame-rate multiplier actually applied. For a `targetFrameRate` that is not a whole
    /// multiple, the ratio rounded to the nearest integer (≥ 1); `appliedFrameRate` is exact.
    public let appliedFactor: Int
    /// The output frame rate in fps (contract 1.61.0); nil from a package that does not state it
    /// (`video.frameRate` is the other place to read it).
    public let appliedFrameRate: Double?

    public init(video: Video, appliedFactor: Int, appliedFrameRate: Double? = nil) {
        self.video = video
        self.appliedFactor = appliedFactor
        self.appliedFrameRate = appliedFrameRate
    }
}

/// The canonical descriptor shape for a frame-interpolation tool.
public enum FrameInterpolateContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: FrameInterpolateControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "video", kind: .video, required: true,
                            summary: "The video to frame-interpolate."),
            ParameterSchema(name: "factor", kind: .integer, required: false,
                            summary: "Integer frame-rate multiplier; omit for the package default (2)."),
        ]
        // `targetFrameRate` (contract 1.61.0) is advertised only when DECLARED.
        if let support = controls?.targetFrameRate {
            parameters.append(ParameterSchema(
                name: "targetFrameRate", kind: .number, required: false,
                summary: "Output frame rate in fps, instead of `factor`"
                    + (support.ratios == .integerMultiples ? " (a whole multiple of the source's)" : "")
                    + (support.maxFrameRate.map { " up to \(VEditControls.format($0))" } ?? "") + "."))
        }
        return ToolDescriptor(
            name: name,
            capability: .frameInterpolate,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map(SurfaceControls.frameInterpolate)
        )
    }
}
