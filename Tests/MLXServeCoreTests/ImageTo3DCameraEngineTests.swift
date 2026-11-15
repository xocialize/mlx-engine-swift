//
//  ImageTo3DCameraEngineTests.swift
//  MLXServeCoreTests
//
//  Contract 1.64.0 (AB-A-0284) — the engine pre-flight for cameras on imageTo3D: a declared request
//  reaches the package intact with its cameras, an undeclared camera or world frame is refused before
//  admission, and a surface with no declaration still runs a plain request. Offline, mock packages.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

private func reconManifest(surfaces: [ToolDescriptor]) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
        provenance: Provenance(sourceRepo: "mock/recon", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .fp32, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/recon") }

private func unsupportedFeature(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

private let photo = Image(format: .png, data: Data([1]), width: 64, height: 64)
private let posedFront: [Double] = [1, 0, 0, 0, 0, 0, -1, -2.8, 0, 1, 0, 0, 0, 0, 0, 1]

/// The Pixal3D shape. Echoes the cameras it was handed back as the camera report, so a test sees what
/// crossed the engine.
@InferenceActor
private final class PosedPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        reconManifest(surfaces: [ImageTo3DContract.descriptor(
            name: "pixal3d", summary: "p", modes: [ImageTo3DContract.res1024],
            controls: ImageTo3DControls(features: [.fov, .pose, .worldFrame, .cameraReport],
                                        fovXDegreesRange: 1...120))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let recon = request as? ImageTo3DRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        return ImageTo3DResponse(mesh: Mesh(data: Data([7])), camera: recon.cameras?.first,
                                 frame: recon.frame ?? .front)
    }
}

/// Stock TRELLIS.2: the 1.63 descriptor, no declaration.
@InferenceActor
private final class StockPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        reconManifest(surfaces: [ImageTo3DContract.descriptor(name: "trellis2", summary: "t")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        ImageTo3DResponse(mesh: Mesh(data: Data([8])))
    }
}

@Test func declaredCamerasReachThePackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PosedPackage.self), configuration: mockConfig())
    let camera = ImageTo3DCamera(fovXDegrees: 30, cameraToWorld: posedFront)
    let response = try #require(try await engine.run(
        ImageTo3DRequest(image: photo, cameras: [camera], frame: .world)) as? ImageTo3DResponse)
    #expect(response.camera == camera)
    #expect(response.frame == .world)
}

@Test func undeclaredOrMalformedCamerasAreRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PosedPackage.self), configuration: mockConfig())
    let cases: [(ImageTo3DRequest, String)] = [
        (ImageTo3DRequest(image: photo, cameras: [ImageTo3DCamera(fovXDegrees: 150)]),
         "cameras.fovXDegrees 150.0 — outside"),
        (ImageTo3DRequest(image: photo, additionalViews: [photo], cameras: [ImageTo3DCamera(fovXDegrees: 20)]),
         "cameras — 1 given for 2 view(s)"),
        (ImageTo3DRequest(image: photo, frame: .world), "frame(\"world\") — the world frame"),
    ]
    for (request, prefix) in cases {
        do {
            _ = try await engine.run(request)
            Issue.record("a request the surface cannot take reached the package: \(prefix)")
        } catch {
            let detail = try #require(unsupportedFeature(error))
            #expect(detail.hasPrefix(prefix), "\(detail)")
            #expect(detail.hasSuffix("[pixal3d]"))
        }
    }
}

@Test func anUndeclaredSurfaceRunsPlainRequestsAndRefusesCameras() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(StockPackage.self), configuration: mockConfig())
    let plain = try #require(try await engine.run(ImageTo3DRequest(image: photo)) as? ImageTo3DResponse)
    #expect(plain.mesh.data == Data([8]))
    #expect(plain.camera == nil && plain.frame == nil)
    _ = try await engine.run(ImageTo3DRequest(image: photo, frame: .front))

    do {
        _ = try await engine.run(ImageTo3DRequest(image: photo, cameras: [ImageTo3DCamera(fovXDegrees: 20)]))
        Issue.record("an undeclared surface took a field of view")
    } catch {
        let detail = try #require(unsupportedFeature(error))
        #expect(detail.hasPrefix("cameras.fovXDegrees — this surface takes no field of view"))
        #expect(detail.hasSuffix("[trellis2]"))
    }
}

/// The lane answer to AB-A-0284 Q2, pinned: stock and Pixal3D side by side as two PackageIDs on one
/// capability, routed by package, with no replacement recorded.
@Test func pixal3DIsItsOwnLaneBesideStock() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(StockPackage.self), configuration: mockConfig(), id: "trellis2")
    try await engine.register(PackageRegistration.of(PosedPackage.self), configuration: mockConfig(), id: "pixal3d")
    #expect(await engine.registrationReplacements.isEmpty)
    let posed = ImageTo3DRequest(image: photo, cameras: [ImageTo3DCamera(fovXDegrees: 20)])
    let viaPixal = try #require(try await engine.run(posed, package: "pixal3d") as? ImageTo3DResponse)
    #expect(viaPixal.camera?.fovXDegrees == 20)
    let viaStock = try #require(try await engine.run(ImageTo3DRequest(image: photo), package: "trellis2")
                                as? ImageTo3DResponse)
    #expect(viaStock.mesh.data == Data([8]))
    await #expect(throws: PackageError.self) { _ = try await engine.run(posed, package: "trellis2") }
}
