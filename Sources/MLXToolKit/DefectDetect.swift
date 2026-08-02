import Foundation

/// Canonical defect-detection request: an image → a mask of physical damage (scratches, tears,
/// dust, cracks) present on it.
///
/// Distinct from `matting` on purpose: a matte answers *"what is the foreground?"* — a defect mask
/// answers *"what should not be here?"*. The consumers differ accordingly: this mask's canonical
/// consumer is `imageInpaint` (detect → mask → fill, the fully automatic damage-repair chain that
/// otherwise requires a hand-painted brush mask), and a caller may dilate it before inpainting.
///
/// `preferredKind` mirrors matting's: `.binary` is the thresholded mask ready for inpainting;
/// `.softAlpha` is the raw per-pixel defect probability, for callers that want their own threshold
/// or a confidence display. `threshold` applies to `.binary` only (`nil` = the package's default —
/// packages document theirs; BOPBTL's reference uses 0.4).
public struct DefectDetectRequest: CapabilityRequest {
    public static var capability: Capability { .defectDetect }

    /// The image to inspect (canonical `Image` artifact).
    public let image: Image
    /// Thresholded mask vs raw probability map.
    public let preferredKind: Matte.Kind
    /// Binarization threshold in 0…1 for `.binary`; `nil` = the package's documented default.
    public let threshold: Float?
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image,
                preferredKind: Matte.Kind = .binary,
                threshold: Float? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.image = image
        self.preferredKind = preferredKind
        self.threshold = threshold
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical defect-detection response: the defect mask at the input image's dimensions.
/// `mask.kind` reports what was actually produced; `appliedThreshold` is the threshold that made a
/// `.binary` mask (`nil` for `.softAlpha` — no threshold was applied).
public struct DefectDetectResponse: CapabilityResponse {
    public let mask: Matte
    public let appliedThreshold: Float?

    public init(mask: Matte, appliedThreshold: Float? = nil) {
        self.mask = mask
        self.appliedThreshold = appliedThreshold
    }
}

/// The canonical descriptor shape for a defect-detection tool.
public enum DefectDetectContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .defectDetect,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to inspect for physical damage."),
                ParameterSchema(name: "preferredKind", kind: .string, required: false,
                                summary: "\"binary\" (thresholded mask, default) or \"softAlpha\" "
                                       + "(raw defect probability)."),
                ParameterSchema(name: "threshold", kind: .number, required: false,
                                summary: "Binarization threshold 0…1 for binary masks; omitted = "
                                       + "the package's documented default."),
            ],
            supportedModes: modes
        )
    }
}
