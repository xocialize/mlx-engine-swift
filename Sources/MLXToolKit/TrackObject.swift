import Foundation

/// Canonical promptable **video object tracking** request: a `Video` + point/box prompts on one frame →
/// a per-frame `Matte` track of the indicated object across the whole clip (masklet propagation). The
/// video extension of `promptSegment`: where that segments a still `Image`, this propagates the
/// click-selected object through time. Introduced by EdgeTAM (on-device SAM 2); contract 1.11.0.
///
/// The prompt is supplied on `promptFrame` (default the first frame); coordinates are in **source-video
/// pixels** and the package maps them into model space. Foreground/background is per-point via
/// `pointLabels` (1 = include, 0 = exclude). At least one prompt (points or `box`) is required.
///
/// **Boundary:** the request carries the whole `Video` as serialized container bytes (the `Video↔…`
/// convention); the runtime package decodes it to frames (`FrameStreamNative`, the FFmpeg-free native
/// path), runs the stateful tracker, and returns lossless per-frame mattes. V1 tracks a **single**
/// object; multi-object (an array of prompt sets → array of tracks) is an additive follow-up.
public struct TrackObjectRequest: CapabilityRequest {
    public static var capability: Capability { .trackObject }

    /// The source video to track through (canonical `Video` artifact, serialized container bytes).
    public let video: Video
    /// Index of the frame the prompt is given on (0-based; default 0 = first frame).
    public let promptFrame: Int
    /// Point prompts as `[x, y]` in source-video pixels (may be empty if `box` is given).
    public let points: [[Float]]
    /// Per-point label: 1 = foreground (include), 0 = background (exclude). Same count as `points`.
    public let pointLabels: [Int]
    /// Optional box prompt `[x0, y0, x1, y1]` in source-video pixels.
    public let box: [Float]?
    public let mode: Mode?
    public let metaData: MetaData

    public init(video: Video, promptFrame: Int = 0, points: [[Float]] = [], pointLabels: [Int] = [],
                box: [Float]? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.video = video
        self.promptFrame = promptFrame
        self.points = points
        self.pointLabels = pointLabels
        self.box = box
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical video-tracking response: one `Matte` **per video frame**, in frame order, at source
/// resolution — a lossless masklet (binary mattes, never a re-encoded mask video, so hard edges survive).
/// `scores[i]` is the model's confidence (predicted IoU / object-presence) for `masks[i]`; a low score
/// marks a frame where the object is occluded or absent. `masks.count == scores.count == frame count`.
public struct TrackObjectResponse: CapabilityResponse {
    /// Per-frame mattes in frame order (`count` == the source video's frame count).
    public let masks: [Matte]
    /// Per-frame confidence aligned with `masks` (predicted IoU / object-presence; ≤0 ≈ occluded/absent).
    public let scores: [Float]

    public init(masks: [Matte], scores: [Float]) {
        self.masks = masks
        self.scores = scores
    }
}

/// The canonical descriptor for a promptable video-tracking tool (video + a click/box on one frame →
/// a per-frame matte track). A package fills in `name`/`summary` and may extend `supportedModes`.
public enum TrackObjectContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .trackObject,
            summary: summary,
            parameters: [
                ParameterSchema(name: "video", kind: .video, required: true,
                                summary: "The source video to track the object through."),
                ParameterSchema(name: "promptFrame", kind: .integer, required: false,
                                summary: "Frame index the prompt is given on (0-based; default 0)."),
                ParameterSchema(name: "points", kind: .array, required: false,
                                summary: "Point prompts as [[x,y],...] in source-video pixels."),
                ParameterSchema(name: "pointLabels", kind: .array, required: false,
                                summary: "Per-point label: 1 = foreground (include), 0 = background (exclude)."),
                ParameterSchema(name: "box", kind: .array, required: false,
                                summary: "Optional box prompt [x0,y0,x1,y1] in source-video pixels."),
            ],
            supportedModes: modes
        )
    }
}
