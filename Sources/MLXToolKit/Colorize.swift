import Foundation

/// Canonical colorization request: a grayscale / desaturated image → a plausibly colorized image at
/// the **same dimensions**. Color is invented (no reference), so this is an opt-in *enhance*-style
/// transform — there is no full-reference quality floor gating it (cf. `imageRestore`). Quality/style
/// tier rides `mode` (`ColorizeContract.fast`/`.best`/`.artistic`). Contract 1.7.0; introduced by DDColor.
/// Canonical output is an `Image` at the same dimensions.
public struct ColorizeRequest: CapabilityRequest {
    public static var capability: Capability { .imageColorize }

    /// The image to colorize (canonical `Image` artifact). A colour image is accepted and treated as
    /// its luminance — the package extracts the L channel, exactly like the grayscale path.
    public let image: Image
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical colorization response: the colorized image (same dimensions as the input).
public struct ColorizeResponse: CapabilityResponse {
    public let image: Image
    public init(image: Image) { self.image = image }
}

/// The canonical descriptor shape for a colorization tool. A package fills in `name`/`summary` and may
/// extend `supportedModes`; the parameter schema (one image) is the canonical surface.
public enum ColorizeContract {
    /// Quality/style tier modes a colorization package may honor. Open/extensible (Mode is a tag, C4).
    public static let fast: Mode = "fast"          // fast tier (e.g. DDColor convnext-t)
    public static let best: Mode = "best"          // best tier (e.g. DDColor convnext-l / modelscope)
    public static let artistic: Mode = "artistic"  // stylized tier (e.g. DDColor artistic checkpoint)

    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageColorize,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The grayscale / desaturated image to colorize."),
            ],
            supportedModes: modes
        )
    }
}
