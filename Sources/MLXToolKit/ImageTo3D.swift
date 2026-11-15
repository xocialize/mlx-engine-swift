import Foundation

/// Canonical image → 3D request: a primary `Image` (plus optional additional views) → a 3D triangle
/// `Mesh` (GLB).
///
/// From a single view the geometry is *invented* (no full-reference floor) — an opt-in generative
/// transform. Passing `additionalViews` (e.g. a front/¾/side/back turnaround of the SAME subject) is
/// genuine multi-view conditioning: a package that supports it concatenates the views' features, which
/// resolves back/side ambiguity and reduces single-view artifacts. Packages that don't support it use
/// `image` only. Resolution tier (the voxel grid size) rides `mode`
/// (`ImageTo3DContract.res512`/`.res1024`/`.res1536`); a package documents the tiers it honors via its
/// `ToolDescriptor`. Background removal of the input is package-internal preprocessing (the shipped
/// BiRefNet `matting`), not a request field.
///
/// **Cameras (contract 1.64.0, AB-A-0284).** A projection-conditioned model (Pixal3D, first) needs the
/// camera each view was taken with: `cameras` carries one `ImageTo3DCamera` per view, aligned with
/// `[image] + additionalViews`, and `frame` says which frame the mesh comes back in. Both are
/// DECLARATION-GATED (`ImageTo3DControls`, engine-enforced before admission), unlike `additionalViews`:
/// an ignored camera is wrong output — the subject at the wrong scale or depth, or a mesh in a frame the
/// caller did not ask for — and nothing in the GLB says so. A surface that declares nothing refuses
/// them and runs every other request exactly as before.
///
/// Canonical output is a `Mesh` artifact (GLB bytes), geometry + vertex color in V1.
public struct ImageTo3DRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .imageTo3D }

    /// The primary image to reconstruct a 3D mesh from (canonical `Image` artifact).
    public let image: Image
    /// Optional additional views of the SAME subject (multi-view conditioning). Empty/nil ⇒ single-view.
    /// A package that doesn't support multi-view ignores these and uses `image`.
    public let additionalViews: [Image]?
    /// Resolution tier (voxel grid). Optional; a package picks its default tier when nil.
    public let mode: Mode?
    /// The camera of each view (contract 1.64.0), aligned with `[image] + additionalViews`: exactly
    /// `1 + additionalViews.count` entries. Nil ⇒ the package places its own camera. Pose every view
    /// or none (`cameraToWorld` on all entries or on none). Declaration-gated
    /// (`ImageTo3DControls.features`: `.fov`, `.pose`).
    public let cameras: [ImageTo3DCamera]?
    /// The frame the mesh comes back in (contract 1.64.0). Nil ⇒ `.front`, the package's own object
    /// frame — what every imageTo3D package returns. `.world` (the cameras' frame) needs every view
    /// posed and is declaration-gated (`.worldFrame`).
    public let frame: ImageTo3DFrame?
    /// Package-only levers. Never the cameras or the frame (C5, contract 1.64.0).
    public let metaData: MetaData

    public init(image: Image, additionalViews: [Image]? = nil, mode: Mode? = nil,
                cameras: [ImageTo3DCamera]? = nil, frame: ImageTo3DFrame? = nil,
                metaData: MetaData = [:]) {
        self.image = image
        self.additionalViews = additionalViews
        self.mode = mode
        self.cameras = cameras
        self.frame = frame
        self.metaData = metaData
    }

    /// The number of views: `image` plus `additionalViews`.
    public var viewCount: Int { 1 + (additionalViews?.count ?? 0) }

    /// Whether any view carries a pose.
    public var isPosed: Bool { cameras?.contains { $0.cameraToWorld != nil } == true }

    /// What is malformed in the request's own shape, or nil. Independent of any declaration: the camera
    /// count, each camera, posing all views or none, and `.world` without poses.
    public var shapeProblem: String? {
        if let cameras {
            if cameras.count != viewCount {
                return "cameras — \(cameras.count) given for \(viewCount) view(s); give one per view, "
                    + "aligned with [image] + additionalViews"
            }
            for (index, camera) in cameras.enumerated() {
                if let problem = camera.shapeProblem { return "cameras[\(index)] — \(problem)" }
            }
            let posed = cameras.filter { $0.cameraToWorld != nil }.count
            if posed != 0, posed != cameras.count {
                return "cameras — \(posed) of \(cameras.count) views carry cameraToWorld; pose every "
                    + "view or none"
            }
        }
        if frame == .world, !isPosed {
            return "frame(\"world\") — the world frame is the cameras' frame; give cameraToWorld for "
                + "every view, or ask for \"front\""
        }
        return nil
    }
}

/// The camera one input view was taken with (contract 1.64.0, AB-A-0284). Introduced for Pixal3D.
///
/// **Convention** (Blender / NeRF / OpenGL camera): the WORLD is Z-up; the camera looks down its own
/// −Z axis with +Y up and +X right. `cameraToWorld` is the 4×4 camera-to-world matrix, 16 numbers,
/// ROW-MAJOR (`m[0...3]` is the first row), bottom row `0 0 0 1`; its translation column is the camera
/// centre in world units. View 0 should be the subject's canonical front.
public struct ImageTo3DCamera: Sendable, Codable, Equatable {
    /// Horizontal field of view in degrees, in (0, 180). Nil ⇒ the package's default. With no
    /// `cameraToWorld` the package places the camera on its canonical front axis at the distance this
    /// implies (Pixal3D: `0.5 / tan(fov/2)`, the unit cube filling the image width).
    public let fovXDegrees: Double?
    /// Camera-to-world, 16 numbers row-major (see the type's convention). Nil ⇒ unposed.
    public let cameraToWorld: [Double]?

    public init(fovXDegrees: Double? = nil, cameraToWorld: [Double]? = nil) {
        self.fovXDegrees = fovXDegrees
        self.cameraToWorld = cameraToWorld
    }

    /// What is malformed in this camera, or nil: a field of view outside (0, 180) or not finite, a
    /// matrix that is not 16 finite numbers, a bottom row that is not `0 0 0 1`, or a rotation part
    /// that is not a rotation (orthonormal, determinant +1, within 1e-3).
    public var shapeProblem: String? {
        if let fov = fovXDegrees, !(fov.isFinite && fov > 0 && fov < 180) {
            return "fovXDegrees \(fov) — expected degrees in (0, 180)"
        }
        guard let m = cameraToWorld else { return nil }
        if m.count != 16 { return "cameraToWorld — expected 16 numbers (4×4 row-major), got \(m.count)" }
        if m.contains(where: { !$0.isFinite }) { return "cameraToWorld — contains a non-finite number" }
        let tolerance = 1e-3
        if abs(m[12]) > tolerance || abs(m[13]) > tolerance || abs(m[14]) > tolerance
            || abs(m[15] - 1) > tolerance {
            return "cameraToWorld — bottom row must be 0 0 0 1 (row-major); a transposed matrix lands here"
        }
        // Columns of the upper-left 3×3: the camera's X, Y, Z axes in world coordinates.
        let axes = (0..<3).map { c in [m[c], m[4 + c], m[8 + c]] }
        func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
        for i in 0..<3 {
            if abs(dot(axes[i], axes[i]) - 1) > tolerance {
                return "cameraToWorld — the rotation part is not orthonormal (unit axes, no scale)"
            }
            for j in (i + 1)..<3 where abs(dot(axes[i], axes[j])) > tolerance {
                return "cameraToWorld — the rotation part is not orthonormal (unit axes, no scale)"
            }
        }
        let x = axes[0], y = axes[1], z = axes[2]
        let determinant = x[0] * (y[1] * z[2] - y[2] * z[1])
            - y[0] * (x[1] * z[2] - x[2] * z[1])
            + z[0] * (x[1] * y[2] - x[2] * y[1])
        if determinant < 0 {
            return "cameraToWorld — the rotation part is a reflection (determinant −1); "
                + "check the handedness against the convention (−Z forward, +Y up)"
        }
        return nil
    }
}

/// The frame an imageTo3D mesh is expressed in (contract 1.64.0). Open tag, like `Mode`.
public struct ImageTo3DFrame: RawRepresentable, Sendable, Codable, Equatable, Hashable,
                              ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// The package's own object frame, the subject facing its canonical front. What every imageTo3D
    /// package returns; never declaration-gated.
    public static let front: ImageTo3DFrame = "front"
    /// The cameras' world frame (the `ImageTo3DCamera` convention): the mesh placed where the posed
    /// views see it. Needs every view posed; needs `.worldFrame` declared.
    public static let world: ImageTo3DFrame = "world"
}

/// The optional camera levers an imageTo3D surface honors (contract 1.64.0).
public enum ImageTo3DCameraFeature: String, Sendable, Codable, Hashable, CaseIterable {
    /// `ImageTo3DCamera.fovXDegrees`: the field of view of each view.
    case fov
    /// `ImageTo3DCamera.cameraToWorld`: posed views.
    case pose
    /// `ImageTo3DFrame.world`: the mesh returned in the cameras' frame.
    case worldFrame
    /// `ImageTo3DResponse.camera`: the response reports view 0's camera in the mesh's frame.
    case cameraReport
}

/// What an imageTo3D surface does with cameras (contract 1.64.0, AB-A-0284), as
/// `SurfaceControls.imageTo3D` (`ToolDescriptor.imageTo3DControls`). OPTIONAL: a surface with no
/// declaration refuses `cameras` and a non-front `frame`, and runs every other request as before.
public struct ImageTo3DControls: Sendable, Codable, Equatable {
    /// The camera levers this surface honors.
    public let features: Set<ImageTo3DCameraFeature>
    /// The field-of-view range this surface takes, in degrees (Pixal3D: up to 120). Nil ⇒ the whole
    /// (0, 180) the contract allows. Engine-enforced.
    public let fovXDegreesRange: ClosedRange<Double>?

    public init(features: Set<ImageTo3DCameraFeature>, fovXDegreesRange: ClosedRange<Double>? = nil) {
        self.features = features
        self.fovXDegreesRange = fovXDegreesRange
    }

    public func declares(_ feature: ImageTo3DCameraFeature) -> Bool { features.contains(feature) }

    /// Internal inconsistencies of the declaration. Empty for a coherent one. A package's manifest
    /// test asserts this is empty (the C11 "honest descriptor" expectation).
    public var declarationProblems: [String] {
        var problems: [String] = []
        if features.isEmpty { problems.append("no camera features are declared") }
        if declares(.worldFrame), !declares(.pose) {
            problems.append("worldFrame is declared without pose — the world frame is the cameras' frame")
        }
        if let range = fovXDegreesRange {
            if !declares(.fov) { problems.append("fovXDegreesRange is set without the fov feature") }
            if !(range.lowerBound >= 0 && range.upperBound <= 180) {
                problems.append("fovXDegreesRange lies outside (0, 180)")
            }
        }
        return problems
    }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it
    /// as `PackageError.unsupportedRequestFeature` before admission; a package driven directly may
    /// call it first for the same refusal. A nil declaration is `ImageTo3DControls.refusal(for:declared:)`.
    public func refusal(for request: ImageTo3DRequest) -> String? {
        Self.refusal(for: request, declared: self)
    }

    /// The refusal for `request` on a surface declaring `declared` (nil = no declaration): the request's
    /// own shape first, then only what an ignored field would make WRONG.
    public static func refusal(for request: ImageTo3DRequest, declared: ImageTo3DControls?) -> String? {
        if let problem = request.shapeProblem { return problem }
        let features = declared?.features ?? []
        if let cameras = request.cameras {
            if cameras.contains(where: { $0.fovXDegrees != nil }), !features.contains(.fov) {
                return "cameras.fovXDegrees — this surface takes no field of view "
                    + "(ImageTo3DControls.features); drop it, or choose a package that declares fov"
            }
            if let range = declared?.fovXDegreesRange,
               let fov = cameras.compactMap(\.fovXDegrees).first(where: { !range.contains($0) }) {
                return "cameras.fovXDegrees \(fov) — outside the \(range.lowerBound)…\(range.upperBound)° "
                    + "this surface takes (ImageTo3DControls.fovXDegreesRange)"
            }
            if request.isPosed, !features.contains(.pose) {
                return "cameras.cameraToWorld — this surface takes no posed views "
                    + "(ImageTo3DControls.features); drop the poses, or choose a package that declares pose"
            }
        }
        if let frame = request.frame, frame != .front {
            if frame == .world {
                if !features.contains(.worldFrame) {
                    return "frame(\"world\") — this surface returns its own object frame "
                        + "(ImageTo3DControls.features); ask for \"front\" and place the mesh yourself, "
                        + "or choose a package that declares worldFrame"
                }
            } else {
                return "frame(\"\(frame.rawValue)\") — not a frame this contract defines (front / world)"
            }
        }
        return nil
    }
}

/// Canonical single-image → 3D response: the generated triangle mesh (GLB bytes).
///
/// Since 1.64.0 (AB-A-0284) it may report the camera and frame: `camera` is view 0's camera
/// expressed in the RETURNED mesh's frame (render the mesh through it and it lines up with the input
/// image), present where the surface declares `.cameraReport`; `frame` is the frame the mesh is in.
/// Both nil = not reported (every pre-1.64 package). Pre-1.64 JSON decodes.
public struct ImageTo3DResponse: CapabilityResponse, Codable {
    public let mesh: Mesh
    /// View 0's camera in the returned mesh's frame (`fovXDegrees` and `cameraToWorld` both set when
    /// reported). Nil = not reported.
    public let camera: ImageTo3DCamera?
    /// The frame `mesh` is in. Nil = not reported (read: `.front`).
    public let frame: ImageTo3DFrame?

    public init(mesh: Mesh, camera: ImageTo3DCamera? = nil, frame: ImageTo3DFrame? = nil) {
        self.mesh = mesh
        self.camera = camera
        self.frame = frame
    }
}

/// The canonical descriptor shape for an image→3D tool. A package fills in `name`/`summary` and
/// may extend `supportedModes` with the resolution tiers it honors; the parameter schema is the
/// canonical surface.
public enum ImageTo3DContract {
    /// Resolution-tier modes (voxel grid). Open/extensible (Mode is a tag).
    public static let res512: Mode = "res512"     // fastest / lightest
    public static let res1024: Mode = "res1024"   // balanced
    public static let res1536: Mode = "res1536"   // highest detail

    /// The descriptor. `controls` (contract 1.64.0) declares the camera levers; only declared ones are
    /// advertised (`cameras`, `frame`), so a planner is never handed a knob the engine would refuse.
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: ImageTo3DControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "image", kind: .image, required: true,
                            summary: "The single image to reconstruct a 3D mesh from."),
            ParameterSchema(name: "mode", kind: .string, required: false,
                            summary: "Resolution tier: \"res512\" (fast), \"res1024\" (balanced), "
                                   + "or \"res1536\" (highest detail). Default is package-defined."),
        ]
        if let controls, controls.declares(.fov) || controls.declares(.pose) {
            var fields: [String] = []
            if controls.declares(.fov) {
                let range = controls.fovXDegreesRange.map { " \($0.lowerBound)…\($0.upperBound)" } ?? ""
                fields.append("fovXDegrees (horizontal, degrees\(range))")
            }
            if controls.declares(.pose) {
                fields.append("cameraToWorld (16 numbers, row-major 4×4; Z-up world, camera looks down −Z, +Y up)")
            }
            parameters.append(ParameterSchema(
                name: "cameras", kind: .array, required: false,
                summary: "One camera per view, aligned with [image] + additionalViews: {"
                    + fields.joined(separator: ", ") + "}. Pose every view or none."))
        }
        if let controls, controls.declares(.worldFrame) {
            parameters.append(ParameterSchema(
                name: "frame", kind: .string, required: false,
                summary: "\"front\" (the object frame, default) or \"world\" (the posed cameras' frame)."))
        }
        return ToolDescriptor(
            name: name,
            capability: .imageTo3D,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            controls: controls.map { .imageTo3D($0) }
        )
    }
}
