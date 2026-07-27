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

    /// How hard to restore, `0...1`. `nil` = the package's own default.
    ///
    /// **Optional because most restoration models have no such notion.** NAFNet, FFTformer and
    /// Restormer each bake their strength into the checkpoint — you pick a model, not a level — and
    /// they simply ignore this. But some architectures take the level as a genuine *input*: DRUNet
    /// consumes a noise-level plane as a 4th channel, so one set of weights spans a continuous
    /// range. Without this field that capability could only be reached through untyped `metaData`,
    /// where no planner would find it.
    ///
    /// A package that ignores this MUST report `appliedStrength == nil` on the response, so a caller
    /// can tell "I turned the dial and it did nothing" from "there is no dial here."
    /// Contract 1.30.0.
    public let strength: Float?

    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, strength: Float? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.strength = strength
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical image-restoration response: the restored image (same dimensions as the input).
public struct ImageRestoreResponse: CapabilityResponse {
    public let image: Image

    /// The strength actually applied, or `nil` when the package has no strength notion and ignored
    /// the request's value.
    ///
    /// Typed rather than left to inference: "this backer cannot honour your slider" is something a
    /// caller acts on — a UI greys the control out, a planner routes to a package that can.
    /// Contract 1.30.0; defaulted so existing packages stay source-compatible.
    public let appliedStrength: Float?

    public init(image: Image, appliedStrength: Float? = nil) {
        self.image = image
        self.appliedStrength = appliedStrength
    }
}

/// The canonical descriptor shape for an image-restoration tool. A package fills in
/// `name`/`summary` and may extend `supportedModes`; the parameter schema is the canonical surface.
public enum ImageRestoreContract {
    /// - Parameter supportsStrength: whether this backer honours `strength`. Packages whose level is
    ///   baked into the checkpoint should leave it `false`, so the parameter does not appear on
    ///   their surface and a planner is never offered a dial that does nothing.
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  supportsStrength: Bool = false) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "image", kind: .image, required: true,
                            summary: "The image to restore (denoise / deblock)."),
        ]
        if supportsStrength {
            parameters.append(
                ParameterSchema(name: "strength", kind: .number, required: false,
                                summary: "How hard to restore, 0…1. Default is the package's own."))
        }
        return ToolDescriptor(
            name: name,
            capability: .imageRestore,
            summary: summary,
            parameters: parameters,
            supportedModes: modes
        )
    }
}
