import Foundation

/// Canonical exposure / lighting-correction request: re-expose an image — lift shadows, recover
/// mid-tones — without changing its resolution or content.
///
/// Separate from `imageRestore` on purpose. Restoration removes defects and has no notion of "how
/// much"; re-exposure is a continuously dialable *choice*, and one that must be able to decline:
/// low-light models drive their output toward a target mean luma regardless of input, so applied to
/// an already-correctly-exposed image they actively degrade it. That makes the bypass part of the
/// contract rather than an implementation detail — hence `appliedStrength` and `bypassed` on the
/// response.
///
/// Canonical output is an `Image` at the same dimensions.
public struct ImageRelightRequest: CapabilityRequest {
    public static var capability: Capability { .imageRelight }

    /// The image to re-expose (canonical `Image` artifact).
    public let image: Image

    /// How far to apply the correction, `0...1`. `nil` = the package's default (full strength).
    ///
    /// `0` returns the input unchanged; `1` is the model's own output. Intermediate values are a
    /// blend, which is what makes this a slider rather than a switch — and the reason a package
    /// should never need to invent its own "intensity" mode.
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

/// Canonical exposure-correction response: the re-exposed image at the input's dimensions, plus
/// what the package actually did.
public struct ImageRelightResponse: CapabilityResponse {
    public let image: Image

    /// The strength actually applied after clamping and any automatic gating — not necessarily the
    /// requested value.
    public let appliedStrength: Float

    /// True when the package judged the input already well-exposed and declined to enhance it
    /// (`image` is then the input, or a mild classical fallback).
    ///
    /// Typed rather than buried in `metaData` because a caller genuinely needs to distinguish
    /// "corrected" from "left alone": a UI showing a before/after has nothing to show, and a
    /// pipeline may want to skip a subsequent stage.
    public let bypassed: Bool

    public init(image: Image, appliedStrength: Float, bypassed: Bool) {
        self.image = image
        self.appliedStrength = appliedStrength
        self.bypassed = bypassed
    }
}

/// The canonical descriptor shape for an exposure-correction tool.
public enum ImageRelightContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageRelight,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The image to re-expose."),
                ParameterSchema(name: "strength", kind: .number, required: false,
                                summary: "How far to apply the correction, 0…1 "
                                    + "(0 = unchanged, 1 = full model output). Default 1."),
            ],
            supportedModes: modes
        )
    }
}
