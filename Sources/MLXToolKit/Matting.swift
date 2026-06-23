import Foundation

/// Canonical matte-extraction request: an image → a single-channel matte (foreground alpha).
///
/// `preferredKind` selects hard binary segmentation vs. a soft alpha matte (fine hair/fur/
/// semi-transparency) — it determines the `Matte.Kind` the package should produce, so it is a
/// canonical field, not a steering tag. Quality/resolution tier (e.g. fast vs. high-resolution) rides
/// `mode`; a package documents the modes it honors via its `ToolDescriptor` (see `MattingContract`).
///
/// Canonical output is a `Matte` at the source image's dimensions. Background removal is a *consumer*
/// of this matte (composite over transparency); the matte itself is reusable as a weight-map signal by
/// other capabilities (region-aware `imageRestore`/`imageUpscale`, `opticalFlow`-guided propagation).
public struct MattingRequest: CapabilityRequest {
    public static var capability: Capability { .matting }

    /// The image to extract a foreground matte from (canonical `Image` artifact).
    public let image: Image
    /// Which matte kind the caller wants. Packages that produce only one kind ignore the off-axis
    /// request and report the actual kind on the returned `Matte`.
    public let preferredKind: Matte.Kind
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image,
                preferredKind: Matte.Kind = .softAlpha,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.image = image
        self.preferredKind = preferredKind
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical matte-extraction response: the foreground matte (same dimensions as the input image).
/// `matte.kind` reports the kind actually produced (may differ from `preferredKind`).
public struct MattingResponse: CapabilityResponse {
    public let matte: Matte
    public init(matte: Matte) { self.matte = matte }
}

/// The canonical descriptor shape for a matte-extraction tool. A package fills in `name`/`summary`,
/// may extend `supportedModes` (e.g. quality/resolution tiers), and documents which `Matte.Kind`s it
/// supports; the parameter schema is the canonical surface.
public enum MattingContract {
    /// Quality/resolution tier modes a matting package may honor. Open/extensible (Mode is a tag).
    public static let fast: Mode = "fast"   // fast tier (e.g. general weights @ base resolution)
    public static let best: Mode = "best"   // best tier (e.g. high-resolution matting weights)

    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .matting,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to extract a foreground matte from."),
                ParameterSchema(name: "preferredKind", kind: .string, required: false,
                                summary: "Matte kind: \"binary\" (hard segmentation) or "
                                       + "\"softAlpha\" (soft matte, fine hair/fur). Default softAlpha."),
            ],
            supportedModes: modes
        )
    }
}
