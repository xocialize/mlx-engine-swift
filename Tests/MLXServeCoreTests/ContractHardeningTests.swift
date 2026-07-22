import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Fixtures

/// A two-surface package: `imageAnalysis` usable at any quant, `textToImage` declaring an int8
/// floor. The motivating shape — the same weights are analysis-fine but generation-bad at int4.
private struct TieredConfiguration: PackageConfiguration, QuantConfigured {
    var quant: Quant
}

@InferenceActor
private final class TwoSurfacePackage: ModelPackage {
    typealias Configuration = TieredConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/two-surface", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .int4, residentBytes: 1),
                             QuantFootprint(quant: .bf16, residentBytes: 2)],
                requiredBackends: [.metalGPU]),
            specialties: [SpecialtyWeight(.general, strength: 1.0)],
            surfaces: [
                ToolDescriptor(name: "two-surface-analysis", capability: .imageAnalysis,
                               summary: "analysis at any quant"),
                ToolDescriptor(name: "two-surface-t2i", capability: .textToImage,
                               summary: "generation needs int8+", quantFloor: .int8),
            ])
    }
    nonisolated init(configuration: TieredConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        ImageAnalysisResponse(text: "mock")
    }
}

/// Declares a specialty that is not in the registered vocabulary (C6 drift).
@InferenceActor
private final class DriftingSpecialtyPackage: ModelPackage {
    typealias Configuration = TieredConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/drifting", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            specialties: [SpecialtyWeight("line-art", strength: 0.9),
                          SpecialtyWeight(.general, strength: 0.2)],
            surfaces: [ToolDescriptor(name: "drifting-t2i", capability: .textToImage,
                                      summary: "mock")])
    }
    nonisolated init(configuration: TieredConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        ImageAnalysisResponse(text: "mock")
    }
}

// MARK: - 3.5 Specialty vocabulary governance (warn-only)

@Test func registeredVocabularyCoversTheFleetsDeclaredTerms() {
    // Every core constant is registered — the set and the constants can't drift apart silently.
    for specialty in [Specialty.general, .coder, .researcher, .companion, .poseless, .poseDriven,
                      .emotionControl, .durationControl, .voiceClone, .realtimeStreaming, .anime,
                      .threeDGeneration, .meshRigging, .characterRigging] {
        #expect(specialty.isRegistered, "\(specialty.rawValue) missing from registeredVocabulary")
    }
    #expect(Specialty("line-art").isRegistered == false)
}

@Test func unregisteredSpecialtyWarnsButStillRegisters() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DriftingSpecialtyPackage.self),
                              configuration: TieredConfiguration(quant: .int4))

    // Warn-only: the package IS registered and routable (hard rejection would break unknown
    // third-party conformers with no deprecation window).
    #expect(await engine.registeredCapabilities == [.textToImage])
    #expect(await engine.unregisteredSpecialties == [Specialty("line-art")])
}

@Test func registeredSpecialtiesRaiseNoWarning() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(TwoSurfacePackage.self),
                              configuration: TieredConfiguration(quant: .bf16))
    #expect(await engine.unregisteredSpecialties.isEmpty)
}

// MARK: - 3.2 Per-surface quant eligibility

@Test func quantPrecisionRanking() {
    #expect(Quant.int4.meets(floor: .int4))
    #expect(Quant.bf16.meets(floor: .int8))
    #expect(Quant.fp32.meets(floor: .bf16))
    #expect(Quant.int4.meets(floor: .int8) == false)
    #expect(Quant.int6.meets(floor: .int8) == false)
    // fp16/bf16 share a rank (both 16-bit) — neither is "below" the other.
    #expect(Quant.fp16.meets(floor: .bf16))
    #expect(Quant.bf16.meets(floor: .fp16))
    // mxfp4 ranks with int4: 4 bits with richer per-block scaling, not a tier above.
    #expect(Quant.mxfp4.meets(floor: .int4))
    #expect(Quant.mxfp4.meets(floor: .int5) == false)
}

@Test func belowFloorSurfaceStopsBackingWhileSiblingsStillDo() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(TwoSurfacePackage.self),
                              configuration: TieredConfiguration(quant: .int4))

    // int4 < the t2i surface's int8 floor: generation is not backed, analysis still is.
    #expect(await engine.registeredCapabilities == [.imageAnalysis])
    #expect(await engine.packages(for: .textToImage).isEmpty)
}

@Test func atOrAboveFloorAdmitsEverySurface() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(TwoSurfacePackage.self),
                              configuration: TieredConfiguration(quant: .bf16))
    #expect(Set(await engine.registeredCapabilities) == [.imageAnalysis, .textToImage])
}

@Test func nilFloorIsUnchangedBehavior() async throws {
    // The drifting package declares no floor at all — the existing-conformer path.
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DriftingSpecialtyPackage.self),
                              configuration: TieredConfiguration(quant: .int4))
    #expect(await engine.registeredCapabilities == [.textToImage])
}

@Test func admissibilityReportsTheSurfaceFloorVerdict() async throws {
    let engine = MLXServeEngine()
    let manifest = TwoSurfacePackage.manifest

    let generation = await engine.admissibility(for: manifest,
                                                configuration: TieredConfiguration(quant: .int4),
                                                capability: .textToImage)
    #expect(generation.eligibility == .quantBelowSurfaceFloor(capability: .textToImage,
                                                              required: .int8, selected: .int4))
    #expect(generation.admissible == false)

    let analysis = await engine.admissibility(for: manifest,
                                              configuration: TieredConfiguration(quant: .int4),
                                              capability: .imageAnalysis)
    #expect(analysis.eligibility.isEligible)

    let atFloor = await engine.admissibility(for: manifest,
                                             configuration: TieredConfiguration(quant: .int8),
                                             capability: .textToImage)
    #expect(atFloor.eligibility.isEligible)
}
