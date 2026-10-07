//
//  RegistrationReplacementTests.swift
//  MLXServeCoreTests
//
//  AB-A-0109 — ForgeCore registered one Restormer package three times (motion / defocus / denoise)
//  with no `id:`; every registration derived the same id, so the last silently won every route.
//  A derived-id replacement by a different configuration or package is now logged and recorded.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

private func restoreManifest(repo: String) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: repo, revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: [LLMContract.descriptor(name: "restore", summary: "m")])
}

/// One package whose variants differ only by configuration (the Restormer shape).
@InferenceActor
private final class RestorePackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { restoreManifest(repo: "mock/restormer") }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "restored", finishReason: .stop)
    }
}

/// A different package whose first surface happens to carry the same name.
@InferenceActor
private final class OtherRestorePackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { restoreManifest(repo: "mock/other-restore") }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "other", finishReason: .stop)
    }
}

private let motion = StandardConfiguration(weightsRepo: "mock/Restormer-motion-deblurring")
private let denoise = StandardConfiguration(weightsRepo: "mock/Restormer-real-denoising")

// The bug: two variants, no id. The collapse still happens (replacement is how updates work), but it
// is no longer silent.
@Test func twoConfigurationsWithoutAnIDAreRecordedAndTheLastWins() async throws {
    let engine = MLXServeEngine()
    let first = try await engine.register(PackageRegistration.of(RestorePackage.self),
                                          configuration: motion)
    let second = try await engine.register(PackageRegistration.of(RestorePackage.self),
                                           configuration: denoise)
    #expect(first == second)
    #expect(await engine.packages(for: .llm) == [second])     // one backer: the denoiser

    let replacements = await engine.registrationReplacements
    #expect(replacements.count == 1)
    let finding = try #require(replacements.first)
    #expect(finding.packageID == "restore")
    #expect(finding.samePackage)
    #expect(finding.previousConfiguration.contains("Restormer-motion-deblurring"))
    #expect(finding.newConfiguration.contains("Restormer-real-denoising"))
}

// Re-registering the same configuration is an update, not a collision.
@Test func anIdenticalReRegistrationIsNotAFinding() async throws {
    let engine = MLXServeEngine()
    for _ in 0..<2 {
        try await engine.register(PackageRegistration.of(RestorePackage.self), configuration: motion)
    }
    #expect(await engine.registrationReplacements.isEmpty)
}

// An explicit id marks the replacement as intended (a settings change re-registering a package).
@Test func anExplicitIDMarksAReplacementAsIntended() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(RestorePackage.self), configuration: motion,
                              id: "restore-active")
    try await engine.register(PackageRegistration.of(RestorePackage.self), configuration: denoise,
                              id: "restore-active")
    #expect(await engine.registrationReplacements.isEmpty)
    #expect(await engine.packages(for: .llm) == ["restore-active"])
}

// The documented fix: each variant carries its own id, and both stay routable.
@Test func variantsWithTheirOwnIDsBothStay() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(RestorePackage.self), configuration: motion,
                              id: "restore-motion")
    try await engine.register(PackageRegistration.of(RestorePackage.self), configuration: denoise,
                              id: "restore-denoise")
    #expect(await engine.registrationReplacements.isEmpty)
    #expect(Set(await engine.packages(for: .llm)) == ["restore-motion", "restore-denoise"])
}

// A different package deriving the same id is the same silent collapse, and says which it was.
@Test func aDifferentPackageDerivingTheSameIDIsRecorded() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(RestorePackage.self), configuration: motion)
    try await engine.register(PackageRegistration.of(OtherRestorePackage.self), configuration: motion)
    let replacements = await engine.registrationReplacements
    let finding = try #require(replacements.first)
    #expect(finding.packageID == "restore")
    #expect(!finding.samePackage)
}
