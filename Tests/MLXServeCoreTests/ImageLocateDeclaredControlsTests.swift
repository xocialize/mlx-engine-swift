//
//  ImageLocateDeclaredControlsTests.swift
//  MLXServeCoreTests
//
//  Contract 1.66.0 (AB-A-0295) — the engine pre-flight for the imageLocate surface: a request within
//  the declaration reaches the package intact and its typed boxes come back; a count above maxCount,
//  an empty prompt and a surface with no declaration are refused before admission. Offline, mocks.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

private func locateManifest(surfaces: [ToolDescriptor]) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
        provenance: Provenance(sourceRepo: "mock/locate", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .fp32, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/locate") }

private func unsupportedFeature(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

private let picture = Image(format: .png, data: Data([1]), width: 256, height: 256)

/// The mlx-locate shape: up to 16 scored boxes. Returns `count` boxes labelled with the prompt, out of
/// order and one hanging off the edge, served through `ImageLocateBox.served` as a package would; a
/// prompt of "nothing" finds nothing.
@InferenceActor
private final class LocatorPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        locateManifest(surfaces: [ImageLocateContract.descriptor(
            name: "locate", summary: "l", controls: ImageLocateControls(maxCount: 16, scores: true))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let locate = request as? ImageLocateRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        if locate.prompt == "nothing" { return ImageLocateResponse(boxes: []) }
        let raw = [
            ImageLocateBox(x: 0.6, y: 0.6, width: 0.3, height: 0.3, label: locate.prompt, score: 0.4),
            ImageLocateBox(x: 0.8, y: 0.1, width: 0.4, height: 0.2, label: locate.prompt, score: 0.7),
            ImageLocateBox(x: 0.15, y: 0.15, width: 0.7, height: 0.7, label: locate.prompt, score: 0.95),
        ]
        return ImageLocateResponse(boxes: raw.served(count: locate.effectiveCount))
    }
}

/// A surface built by hand with no declaration — what the factory will not produce.
@InferenceActor
private final class UndeclaredLocatePackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        locateManifest(surfaces: [ToolDescriptor(name: "bare-locate", capability: .imageLocate, summary: "b")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        ImageLocateResponse(boxes: [])
    }
}

@Test func aDeclaredLocateRequestReturnsTypedBoxesBestFirst() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(LocatorPackage.self), configuration: mockConfig())
    #expect(await engine.registeredCapabilities.contains(.imageLocate))
    let controls = ImageLocateControls(maxCount: 16, scores: true)

    let request = ImageLocateRequest(image: picture, prompt: "the red ball", count: 3)
    let response = try #require(try await engine.run(request) as? ImageLocateResponse)
    #expect(response.boxes.map(\.score) == [0.95, 0.7, 0.4])
    #expect(response.boxes.allSatisfy { $0.label == "the red ball" })
    // The box hanging off the right edge came back clipped to the image.
    let clipped = response.boxes[1]
    #expect(abs(clipped.x + clipped.width - 1) < 1e-9)
    #expect(controls.responseProblems(response, for: request).isEmpty)

    // The default count is 1: the best box alone.
    let best = try #require(try await engine.run(ImageLocateRequest(image: picture, prompt: "the red ball"))
                            as? ImageLocateResponse)
    #expect(best.boxes.count == 1)
    #expect(best.boxes[0].overlap(ImageLocateBox(x: 0.15, y: 0.15, width: 0.7, height: 0.7)) > 0.99)

    // Nothing found is a success with an empty list.
    let none = try #require(try await engine.run(ImageLocateRequest(image: picture, prompt: "nothing", count: 4))
                            as? ImageLocateResponse)
    #expect(none.isEmpty)
}

@Test func aCountAboveTheDeclarationAndAMalformedRequestAreRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(LocatorPackage.self), configuration: mockConfig())
    let cases: [(ImageLocateRequest, String)] = [
        (ImageLocateRequest(image: picture, prompt: "windows", count: 17), "count(17) — this surface returns at most 16"),
        (ImageLocateRequest(image: picture, prompt: "  "), "prompt — an image-locate request says what to find"),
        (ImageLocateRequest(image: picture, prompt: "windows", count: 0), "count(0) — the most boxes"),
    ]
    for (request, prefix) in cases {
        do {
            _ = try await engine.run(request)
            Issue.record("a request the surface cannot take reached the package: \(prefix)")
        } catch {
            let detail = try #require(unsupportedFeature(error))
            #expect(detail.hasPrefix(prefix), "\(detail)")
            #expect(detail.hasSuffix("[locate]"))
        }
    }
}

@Test func aLocateSurfaceWithNoDeclarationIsRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(UndeclaredLocatePackage.self), configuration: mockConfig())
    do {
        _ = try await engine.run(ImageLocateRequest(image: picture, prompt: "a head"))
        Issue.record("an undeclared imageLocate surface ran")
    } catch {
        let detail = try #require(unsupportedFeature(error))
        #expect(detail.hasPrefix("imageLocate — bare-locate declares no ImageLocateControls"))
    }
}
