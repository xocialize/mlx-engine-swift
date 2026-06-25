import Foundation

/// Canonical promptable-segmentation request: an image + point/box prompts → a single-channel `Matte`
/// of the indicated object. Interactive (the caller clicks or boxes the thing to segment), unlike
/// `matting`'s automatic foreground extraction — but it returns the same `Matte` artifact, so consumers
/// (Extract's cutout, Erase's fill mask) handle it uniformly. Contract 1.10.0; introduced by EdgeTAM.
///
/// At least one prompt is required. Coordinates are in **source-image pixels**; the package maps them
/// into model space. Foreground/background is per-point via `pointLabels` (1 = include, 0 = exclude).
public struct PromptSegmentRequest: CapabilityRequest {
    public static var capability: Capability { .promptSegment }

    public let image: Image
    /// Point prompts as `[x, y]` in source pixels (may be empty if `box` is given).
    public let points: [[Float]]
    /// Per-point label: 1 = foreground (include), 0 = background (exclude). Same count as `points`.
    public let pointLabels: [Int]
    /// Optional box prompt `[x0, y0, x1, y1]` in source pixels.
    public let box: [Float]?
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, points: [[Float]] = [], pointLabels: [Int] = [],
                box: [Float]? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.points = points
        self.pointLabels = pointLabels
        self.box = box
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical promptable-segmentation response: the selected object `Matte` (source dimensions) + the
/// model's confidence (`score`, the predicted IoU of the returned mask).
public struct PromptSegmentResponse: CapabilityResponse {
    public let matte: Matte
    public let score: Float
    public init(matte: Matte, score: Float) { self.matte = matte; self.score = score }
}

/// The canonical descriptor for a promptable-segmentation tool (image + point/box prompts).
public enum PromptSegmentContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .promptSegment,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to segment."),
                ParameterSchema(name: "points", kind: .array, required: false,
                                summary: "Point prompts as [[x,y],...] in source pixels."),
                ParameterSchema(name: "pointLabels", kind: .array, required: false,
                                summary: "Per-point label: 1 = foreground (include), 0 = background (exclude)."),
                ParameterSchema(name: "box", kind: .array, required: false,
                                summary: "Optional box prompt [x0,y0,x1,y1] in source pixels."),
            ],
            supportedModes: modes
        )
    }
}
