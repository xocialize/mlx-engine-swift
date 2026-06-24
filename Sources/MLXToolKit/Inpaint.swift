import Foundation

/// Canonical inpainting / object-removal request: an image + a mask (white = the region to remove) →
/// an image with that region plausibly filled from surrounding context, at the **same dimensions**.
/// The fill is invented (no full-reference floor) — an opt-in transform. Tier rides `mode`
/// (`InpaintContract.best` = LaMa · `.fast` = MI-GAN). Contract 1.8.0; introduced by LaMa.
///
/// This is the contract's first **two-input** surface: `image` AND `mask` are both canonical `Image`
/// artifacts. The mask is single-channel-in-RGB (any white pixel = remove); it is typically produced
/// upstream by `matting`, a brush UI, or promptable segmentation. Canonical output is an `Image`.
public struct InpaintRequest: CapabilityRequest {
    public static var capability: Capability { .imageInpaint }

    public let image: Image
    /// Mask image, source-aligned. White (>0.5 luma) = remove / fill; black = keep.
    public let mask: Image
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, mask: Image, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.mask = mask
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical inpainting response: the filled image (same dimensions as the input).
public struct InpaintResponse: CapabilityResponse {
    public let image: Image
    public init(image: Image) { self.image = image }
}

/// The canonical descriptor for an inpainting tool — two image inputs (image + mask).
public enum InpaintContract {
    /// Quality/speed tier Modes. Open/extensible (Mode is a tag, C4).
    public static let best: Mode = "best"   // quality tier (e.g. LaMa — large masks, structured bg)
    public static let fast: Mode = "fast"   // fast/on-device tier (e.g. MI-GAN)

    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageInpaint,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to inpaint."),
                ParameterSchema(name: "mask", kind: .image, required: true,
                                summary: "Mask image; white = region to remove/fill, black = keep."),
            ],
            supportedModes: modes
        )
    }
}
