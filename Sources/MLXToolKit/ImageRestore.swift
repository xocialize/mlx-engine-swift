import Foundation

/// Canonical image-restoration request: clean up an image (denoise / deblock / remove encode
/// artifacts) without changing its resolution. The first *transform* capability of the visual
/// optimization tier — typically gated by `imageQualityScore` ("restore only where it pays")
/// and chained onto the output of a generative or decode stage.
/// Canonical output is an `Image` at the same dimensions.
public struct ImageRestoreRequest: CapabilityRequest {
    public static var capability: Capability { .imageRestore }

    /// The image to restore (canonical `Image` artifact).
    public let image: Image
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical image-restoration response: the restored image (same dimensions as the input).
public struct ImageRestoreResponse: CapabilityResponse {
    public let image: Image
    public init(image: Image) { self.image = image }
}

/// The canonical descriptor shape for an image-restoration tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum ImageRestoreContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageRestore,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to restore (denoise / deblock)."),
            ],
            supportedModes: modes
        )
    }
}
