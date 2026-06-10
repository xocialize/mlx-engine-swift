import Foundation

/// Canonical image super-resolution request: upscale an image by an integer factor. A transform
/// capability of the visual optimization tier — chains onto generative output or a decode stage
/// (often after `imageRestore`, before encode).
/// Canonical output is an `Image` at `scale ×` the input dimensions.
public struct ImageUpscaleRequest: CapabilityRequest {
    public static var capability: Capability { .imageUpscale }

    /// The image to upscale (canonical `Image` artifact).
    public let image: Image
    /// Requested integer scale factor; `nil` means the package's native/default scale.
    public let scale: Int?
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, scale: Int? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.scale = scale
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical image super-resolution response: the upscaled image and the factor actually applied
/// (a package may only support its native scale — callers verify here).
public struct ImageUpscaleResponse: CapabilityResponse {
    public let image: Image
    /// The scale factor actually applied.
    public let appliedScale: Int

    public init(image: Image, appliedScale: Int) {
        self.image = image
        self.appliedScale = appliedScale
    }
}

/// The canonical descriptor shape for an image-upscale tool. A package fills in `name`/`summary`
/// and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum ImageUpscaleContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageUpscale,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to upscale."),
                ParameterSchema(name: "scale", kind: .integer, required: false,
                                summary: "Integer scale factor; omit for the package's native scale."),
            ],
            supportedModes: modes
        )
    }
}
