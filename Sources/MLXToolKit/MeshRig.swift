import Foundation

/// Canonical mesh auto-rigging request: a 3D triangle `Mesh` (GLB) → the SAME geometry with a
/// skeleton + per-vertex skin weights (JOINTS_0 / WEIGHTS_0) injected. Contract 1.19.0; introduced
/// by SkinTokens.
///
/// Two modes ride `mode` (a per-request tag, C4 — same input artifact, different output semantics):
///   • `MeshRigContract.auto` (default) — GENERATE a skeleton and skin the mesh to it. Works on any
///     mesh (a TRELLIS.2 `imageTo3D` output, a scanned object). Output GLB carries a fresh armature.
///   • `MeshRigContract.skinOnly` — the caller PROVIDES the skeleton; the model predicts only skin
///     weights for it (J-in == J-out, the existing bones preserved). The companion-character path:
///     a VRM's own humanoid skeleton in → skinned VRM out.
///
/// The skeleton for `skinOnly` is taken, in order of preference, from (1) the optional `skeleton`
/// artifact, else (2) the skeleton embedded in the `mesh` GLB itself (a VRM/rigged glTF). `auto`
/// ignores any embedded skeleton. Canonical output is a `Mesh` artifact (rigged GLB bytes).
public struct MeshRigRequest: CapabilityRequest {
    public static var capability: Capability { .meshRig }

    /// The mesh to rig (canonical `Mesh` artifact, GLB bytes). Its geometry is preserved verbatim;
    /// only JOINTS_0/WEIGHTS_0 + skeleton nodes are added.
    public let mesh: Mesh
    /// Optional explicit skeleton source for `skinOnly` (a GLB whose joint hierarchy is used). When
    /// nil in `skinOnly` mode, the `mesh`'s own embedded skeleton is used. Ignored in `auto` mode.
    /// Lane-ready second input (the `imageInpaint` two-input precedent); nil for the common cases.
    public let skeleton: Mesh?
    /// `auto` (generate skeleton + skin) or `skinOnly` (skin a provided skeleton). Nil → package default.
    public let mode: Mode?
    public let metaData: MetaData

    public init(mesh: Mesh, skeleton: Mesh? = nil, mode: Mode? = nil, metaData: MetaData = [:]) {
        self.mesh = mesh
        self.skeleton = skeleton
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical mesh auto-rigging response: the rigged mesh (input geometry + injected skeleton/skin).
public struct MeshRigResponse: CapabilityResponse {
    public let mesh: Mesh
    public init(mesh: Mesh) { self.mesh = mesh }
}

/// The canonical descriptor shape for a mesh-rigging tool. A package fills in `name`/`summary`; the
/// parameter schema is the canonical surface. The `skeleton` parameter is optional (single-input is
/// the common case — a VRM carries its own skeleton).
public enum MeshRigContract {
    /// Generate a skeleton AND skin weights for the mesh.
    public static let auto: Mode = "auto"
    /// Predict skin weights only, for a caller-provided (or mesh-embedded) skeleton.
    public static let skinOnly: Mode = "skinOnly"

    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .meshRig,
            summary: summary,
            parameters: [
                ParameterSchema(name: "mesh", kind: .mesh, required: true,
                                summary: "The 3D mesh (GLB) to rig; geometry is preserved verbatim."),
                ParameterSchema(name: "skeleton", kind: .mesh, required: false,
                                summary: "Optional skeleton source (GLB) for skinOnly mode; defaults to "
                                       + "the mesh's own embedded skeleton."),
                ParameterSchema(name: "mode", kind: .string, required: false,
                                summary: "\"auto\" (generate skeleton + skin) or \"skinOnly\" (skin a "
                                       + "provided skeleton, bones preserved). Default is package-defined."),
            ],
            supportedModes: modes
        )
    }
}
