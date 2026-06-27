import Foundation

/// Canonical single-image → 3D request: one `Image` → a 3D triangle `Mesh` (GLB).
///
/// The geometry is *invented* from a single view (no multi-view reconstruction, no full-reference
/// floor) — an opt-in generative transform. Resolution tier (the voxel grid size) rides `mode`
/// (`ImageTo3DContract.res512`/`.res1024`/`.res1536`); a package documents the tiers it honors via its
/// `ToolDescriptor`. Background removal of the input is package-internal preprocessing (the shipped
/// BiRefNet `matting`), not a request field.
///
/// Canonical output is a `Mesh` artifact (GLB bytes), geometry + vertex color in V1.
public struct ImageTo3DRequest: CapabilityRequest {
    public static var capability: Capability { .imageTo3D }

    /// The image to reconstruct a 3D mesh from (canonical `Image` artifact).
    public let image: Image
    /// Resolution tier (voxel grid). Optional; a package picks its default tier when nil.
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical single-image → 3D response: the generated triangle mesh (GLB bytes).
public struct ImageTo3DResponse: CapabilityResponse {
    public let mesh: Mesh
    public init(mesh: Mesh) { self.mesh = mesh }
}

/// The canonical descriptor shape for an image→3D tool. A package fills in `name`/`summary` and
/// may extend `supportedModes` with the resolution tiers it honors; the parameter schema is the
/// canonical surface.
public enum ImageTo3DContract {
    /// Resolution-tier modes (voxel grid). Open/extensible (Mode is a tag).
    public static let res512: Mode = "res512"     // fastest / lightest
    public static let res1024: Mode = "res1024"   // balanced
    public static let res1536: Mode = "res1536"   // highest detail

    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .imageTo3D,
            summary: summary,
            parameters: [
                ParameterSchema(name: "image", kind: .image, required: true,
                                summary: "The single image to reconstruct a 3D mesh from."),
                ParameterSchema(name: "mode", kind: .string, required: false,
                                summary: "Resolution tier: \"res512\" (fast), \"res1024\" (balanced), "
                                       + "or \"res1536\" (highest detail). Default is package-defined."),
            ],
            supportedModes: modes
        )
    }
}
