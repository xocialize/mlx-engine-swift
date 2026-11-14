//
//  CharacterPartDeclaredControlsTests.swift
//  MLXServeCoreTests
//
//  Contract 1.63.0 (AB-A-0277) — the engine pre-flight for the characterPart surface: a declared
//  request reaches the package intact, and an undeclared source, box, body or switch is refused
//  before admission. Offline, mock packages.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

private func partManifest(surfaces: [ToolDescriptor]) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
        provenance: Provenance(sourceRepo: "mock/part", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .fp32, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/part") }

private func unsupportedFeature(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

private let picture = Image(format: .png, data: Data([1]), width: 64, height: 64)
private let cloud = PointCloud(data: Data([2]), pointCount: 10_000, hasNormals: true)
private let vrm = Mesh(data: Data([3]))

/// The HairDeck shape. Answers with a mesh whose bytes say which source it was handed and whether a
/// body came with it, so a test sees what crossed the engine.
@InferenceActor
private final class HairPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        partManifest(surfaces: [CharacterPartContract.descriptor(
            name: "hairdeck", summary: "h",
            controls: CharacterPartControls(parts: [.hair], inputs: [.image, .pointCloud],
                                            features: [.subjectBox, .bodyFit, .springBones, .colors],
                                            requiresSubjectBox: true))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let part = request as? CharacterPartRequest, let input = part.input else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        return CharacterPartResponse(mesh: Mesh(data: Data(input.rawValue.utf8)), part: part.part ?? .hair,
                                     fittedToBody: part.body != nil)
    }
}

/// A surface built by hand with no declaration — what the factory will not produce.
@InferenceActor
private final class UndeclaredPartPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        partManifest(surfaces: [ToolDescriptor(name: "bare-part", capability: .characterPart, summary: "b")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        CharacterPartResponse(mesh: vrm, part: .hair, fittedToBody: false)
    }
}

@Test func bothDeclaredSourcesRouteAndReachThePackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(HairPackage.self), configuration: mockConfig())
    #expect(await engine.registeredCapabilities.contains(.characterPart))

    let fromPicture = try #require(try await engine.run(
        CharacterPartRequest(image: picture, subjectBox: [8, 4, 56, 40], body: vrm, seed: 1)) as? CharacterPartResponse)
    #expect(fromPicture.mesh.data == Data("image".utf8))
    #expect(fromPicture.fittedToBody && fromPicture.part == .hair)

    let fromCloud = try #require(try await engine.run(CharacterPartRequest(pointCloud: cloud))
                                 as? CharacterPartResponse)
    #expect(fromCloud.mesh.data == Data("pointCloud".utf8))
    #expect(fromCloud.fittedToBody == false)
}

@Test func aMissingBoxAndAMalformedRequestAreRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(HairPackage.self), configuration: mockConfig())
    let cases: [(CharacterPartRequest, String)] = [
        (CharacterPartRequest(image: picture), "subjectBox — this surface needs the box"),
        (CharacterPartRequest(body: vrm), "no source"),
        (CharacterPartRequest(image: picture, subjectBox: [8, 4, 56, 40], pointCloud: cloud), "two sources"),
        (CharacterPartRequest(image: picture, subjectBox: [8, 4, 8, 40]), "subjectBox — expected"),
        (CharacterPartRequest(pointCloud: cloud, part: .garment), "part(\"garment\")"),
    ]
    for (request, prefix) in cases {
        do {
            _ = try await engine.run(request)
            Issue.record("a request the surface cannot take reached the package: \(prefix)")
        } catch {
            let detail = try #require(unsupportedFeature(error))
            #expect(detail.hasPrefix(prefix), "\(detail)")
            #expect(detail.hasSuffix("[hairdeck]"))
        }
    }
}

@Test func aSurfaceWithNoDeclarationIsRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(UndeclaredPartPackage.self), configuration: mockConfig())
    do {
        _ = try await engine.run(CharacterPartRequest(pointCloud: cloud))
        Issue.record("an undeclared characterPart surface ran")
    } catch {
        let detail = try #require(unsupportedFeature(error))
        #expect(detail.hasPrefix("characterPart — bare-part declares no CharacterPartControls"))
    }
}
