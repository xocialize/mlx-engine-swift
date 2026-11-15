//
//  ImageTo3DCameraContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.64.0 (AB-A-0284) — cameras on imageTo3D: one camera per view, an output frame, an
//  optional declaration that gates them, and an optional camera report on the response. These pin the
//  request shape, the matrix checks, the refusal rules, the descriptor and the wire forms. Offline.
//

import XCTest
@testable import MLXToolKit

final class ImageTo3DCameraContractTests: XCTestCase {
    private let front = Image(format: .png, data: Data([1]), width: 512, height: 512)
    private let side = Image(format: .png, data: Data([2]), width: 512, height: 512)

    /// The Pixal3D declaration: FOV up to 120°, posed views, the world frame, a camera report.
    private let pixal3D = ImageTo3DControls(features: [.fov, .pose, .worldFrame, .cameraReport],
                                            fovXDegreesRange: 1...120)
    /// A single-photo surface that takes a field of view and nothing else.
    private let fovOnly = ImageTo3DControls(features: [.fov])

    /// Camera on the −Y axis at distance `d`, looking at the origin along +Y, Z up (row-major).
    private func frontCamera(distance d: Double = 2.8) -> [Double] {
        [1, 0, 0, 0,
         0, 0, -1, -d,
         0, 1, 0, 0,
         0, 0, 0, 1]
    }
    /// Camera on the +X axis looking at the origin along −X, Z up (row-major).
    private func sideCamera(distance d: Double = 2.8) -> [Double] {
        [0, 0, 1, d,
         1, 0, 0, 0,
         0, 1, 0, 0,
         0, 0, 0, 1]
    }

    func testVersionAndDefaults() {
        XCTAssertGreaterThanOrEqual(ContractVersion.current, SemanticVersion(major: 1, minor: 64, patch: 0))
        let plain = ImageTo3DRequest(image: front)
        XCTAssertNil(plain.cameras)
        XCTAssertNil(plain.frame)
        XCTAssertNil(plain.shapeProblem)
        XCTAssertEqual(plain.viewCount, 1)
        XCTAssertFalse(plain.isPosed)
        // No declaration: a plain request still passes, so every pre-1.64 package is unaffected.
        XCTAssertNil(ImageTo3DControls.refusal(for: plain, declared: nil))
        XCTAssertNil(ImageTo3DControls.refusal(for: ImageTo3DRequest(image: front, frame: .front), declared: nil))
    }

    func testWellFormedCamerasPass() {
        XCTAssertTrue(pixal3D.declarationProblems.isEmpty)
        XCTAssertNil(ImageTo3DCamera(cameraToWorld: frontCamera()).shapeProblem)
        XCTAssertNil(ImageTo3DCamera(cameraToWorld: sideCamera()).shapeProblem)

        let single = ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(fovXDegrees: 20)])
        XCTAssertNil(pixal3D.refusal(for: single))
        XCTAssertNil(fovOnly.refusal(for: single))

        let posed = ImageTo3DRequest(
            image: front, additionalViews: [side],
            cameras: [ImageTo3DCamera(fovXDegrees: 30, cameraToWorld: frontCamera()),
                      ImageTo3DCamera(fovXDegrees: 30, cameraToWorld: sideCamera())],
            frame: .world)
        XCTAssertTrue(posed.isPosed)
        XCTAssertNil(posed.shapeProblem)
        XCTAssertNil(pixal3D.refusal(for: posed))
    }

    func testMalformedShapesAreRefusedWhateverTheDeclaration() {
        let cases: [(ImageTo3DRequest, String)] = [
            (ImageTo3DRequest(image: front, additionalViews: [side], cameras: [ImageTo3DCamera(fovXDegrees: 20)]),
             "cameras — 1 given for 2 view(s)"),
            (ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(fovXDegrees: 0)]),
             "cameras[0] — fovXDegrees 0.0"),
            (ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(fovXDegrees: .nan)]),
             "cameras[0] — fovXDegrees"),
            (ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(cameraToWorld: [1, 0, 0])]),
             "cameras[0] — cameraToWorld — expected 16 numbers"),
            (ImageTo3DRequest(image: front, additionalViews: [side],
                              cameras: [ImageTo3DCamera(cameraToWorld: frontCamera()), ImageTo3DCamera(fovXDegrees: 20)]),
             "cameras — 1 of 2 views carry cameraToWorld"),
            (ImageTo3DRequest(image: front, frame: .world), "frame(\"world\") — the world frame is the cameras' frame"),
        ]
        for (request, prefix) in cases {
            let reason = ImageTo3DControls.refusal(for: request, declared: pixal3D)
            XCTAssertTrue(reason?.hasPrefix(prefix) == true, "\(String(describing: reason)) ≠ \(prefix)…")
        }
    }

    func testMatrixChecksCatchTransposedScaledAndReflected() {
        // Transposed: the translation lands in the bottom row.
        let m = frontCamera()
        let transposed = (0..<16).map { m[($0 % 4) * 4 + $0 / 4] }
        XCTAssertTrue(ImageTo3DCamera(cameraToWorld: transposed).shapeProblem?.contains("bottom row") == true)
        // Scaled rotation.
        var scaled = m
        scaled[0] = 2
        XCTAssertTrue(ImageTo3DCamera(cameraToWorld: scaled).shapeProblem?.contains("orthonormal") == true)
        // Reflection: flip the camera's X axis.
        var reflected = m
        reflected[0] = -1
        XCTAssertTrue(ImageTo3DCamera(cameraToWorld: reflected).shapeProblem?.contains("reflection") == true)
        var infinite = m
        infinite[3] = .infinity
        XCTAssertTrue(ImageTo3DCamera(cameraToWorld: infinite).shapeProblem?.contains("non-finite") == true)
    }

    func testUndeclaredLeversAreRefused() {
        let fov = ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(fovXDegrees: 20)])
        XCTAssertTrue(ImageTo3DControls.refusal(for: fov, declared: nil)?
            .hasPrefix("cameras.fovXDegrees — this surface takes no field of view") == true)

        let posed = ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(cameraToWorld: frontCamera())])
        XCTAssertTrue(fovOnly.refusal(for: posed)?.hasPrefix("cameras.cameraToWorld — this surface takes no posed views") == true)
        XCTAssertNil(ImageTo3DControls(features: [.pose]).refusal(for: posed))

        let world = ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(cameraToWorld: frontCamera())], frame: .world)
        XCTAssertTrue(ImageTo3DControls(features: [.pose]).refusal(for: world)?
            .hasPrefix("frame(\"world\") — this surface returns its own object frame") == true)

        let wide = ImageTo3DRequest(image: front, cameras: [ImageTo3DCamera(fovXDegrees: 150)])
        XCTAssertTrue(pixal3D.refusal(for: wide)?.hasPrefix("cameras.fovXDegrees 150.0 — outside the 1.0…120.0°") == true)

        let unknown = ImageTo3DRequest(image: front, frame: "screen")
        XCTAssertTrue(pixal3D.refusal(for: unknown)?.hasPrefix("frame(\"screen\") — not a frame") == true)
    }

    func testDeclarationProblems() {
        XCTAssertEqual(ImageTo3DControls(features: []).declarationProblems, ["no camera features are declared"])
        XCTAssertTrue(ImageTo3DControls(features: [.worldFrame]).declarationProblems
            .contains { $0.hasPrefix("worldFrame is declared without pose") })
        XCTAssertTrue(ImageTo3DControls(features: [.pose], fovXDegreesRange: 1...90).declarationProblems
            .contains { $0.hasPrefix("fovXDegreesRange is set without the fov feature") })
        XCTAssertTrue(ImageTo3DControls(features: [.fov], fovXDegreesRange: 1...200).declarationProblems
            .contains { $0.hasPrefix("fovXDegreesRange lies outside") })
    }

    func testDescriptorAdvertisesOnlyWhatIsDeclared() {
        let bare = ImageTo3DContract.descriptor(name: "trellis2", summary: "s", modes: [ImageTo3DContract.res1024])
        XCTAssertNil(bare.controls)
        XCTAssertEqual(bare.parameters.map(\.name), ["image", "mode"])

        let single = ImageTo3DContract.descriptor(name: "photo", summary: "s", controls: fovOnly)
        XCTAssertEqual(single.parameters.map(\.name), ["image", "mode", "cameras"])
        XCTAssertFalse(single.parameters.last?.summary?.contains("cameraToWorld") ?? true)

        let pixal = ImageTo3DContract.descriptor(name: "pixal3d", summary: "s", controls: pixal3D)
        XCTAssertEqual(pixal.parameters.map(\.name), ["image", "mode", "cameras", "frame"])
        XCTAssertEqual(pixal.imageTo3DControls, pixal3D)
        XCTAssertTrue(pixal.controlsMatchCapability)
        XCTAssertFalse(ToolDescriptor(name: "x", capability: .textToImage, summary: "s",
                                      controls: .imageTo3D(pixal3D)).controlsMatchCapability)
    }

    func testWireFormsRoundTripAndPre164JSONDecodes() throws {
        let request = ImageTo3DRequest(
            image: front, additionalViews: [side], mode: ImageTo3DContract.res1024,
            cameras: [ImageTo3DCamera(fovXDegrees: 30, cameraToWorld: frontCamera()),
                      ImageTo3DCamera(fovXDegrees: 30, cameraToWorld: sideCamera())],
            frame: .world)
        let decoded = try JSONDecoder().decode(ImageTo3DRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.cameras, request.cameras)
        XCTAssertEqual(decoded.frame, .world)

        let response = ImageTo3DResponse(mesh: Mesh(data: Data([9])),
                                         camera: ImageTo3DCamera(fovXDegrees: 20, cameraToWorld: frontCamera()),
                                         frame: .front)
        let back = try JSONDecoder().decode(ImageTo3DResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(back.camera, response.camera)
        XCTAssertEqual(back.frame, .front)

        // A pre-1.64 response (mesh only) and request (no cameras / frame) still decode.
        let oldResponse = try JSONEncoder().encode(["mesh": Mesh(data: Data([9]))])
        let legacy = try JSONDecoder().decode(ImageTo3DResponse.self, from: oldResponse)
        XCTAssertNil(legacy.camera)
        XCTAssertNil(legacy.frame)
        struct OldRequest: Encodable { let image: Image; let metaData: MetaData }
        let oldRequest = try JSONEncoder().encode(OldRequest(image: front, metaData: [:]))
        let legacyRequest = try JSONDecoder().decode(ImageTo3DRequest.self, from: oldRequest)
        XCTAssertNil(legacyRequest.cameras)
        XCTAssertNil(legacyRequest.frame)

        let controls = try JSONDecoder().decode(SurfaceControls.self,
                                                from: JSONEncoder().encode(SurfaceControls.imageTo3D(pixal3D)))
        XCTAssertEqual(controls, .imageTo3D(pixal3D))
    }
}
