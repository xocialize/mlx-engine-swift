import Foundation

/// Canonical no-reference image-quality request: score an image's perceptual quality without a
/// reference. The first *assessment* capability of the visual optimization tier — its score
/// drives pipeline decisions (e.g. "does restoration pay on this source?").
/// Canonical output is **structured text** (a score + optional sub-metrics).
public struct ImageQualityScoreRequest: CapabilityRequest {
    public static var capability: Capability { .imageQualityScore }

    /// The image to assess (canonical `Image` artifact).
    public let image: Image
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical no-reference image-quality response.
public struct ImageQualityScoreResponse: CapabilityResponse {
    /// Overall quality in [0, 1] (model-defined semantics; e.g. "restoration-pays": low where
    /// enhancement helps, high on clean content).
    public let score: Float
    /// Optional named sub-metrics (model-specific, e.g. per-patch scores).
    public let subscores: [String: Float]

    public init(score: Float, subscores: [String: Float] = [:]) {
        self.score = score
        self.subscores = subscores
    }
}

/// The canonical descriptor shape for an image-quality tool. A package fills in `name`/`summary`
/// and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum ImageQualityContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageQualityScore,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to assess (no-reference)."),
            ],
            supportedModes: modes
        )
    }
}
