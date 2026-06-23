import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mock packages with tailored requirements (no MLX)

private func mockManifest(capability: Capability, footprint: UInt64,
                          backends: Set<Backend>, chipFloor: ChipTier?) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/mock", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: footprint)],
            requiredBackends: backends,
            os: OSRequirement(),
            chipFloor: chipFloor
        ),
        surfaces: [ToolDescriptor(name: "mock-\(capability.rawValue)", capability: capability, summary: "mock")]
    )
}

private protocol MockBase: ModelPackage where Configuration == StandardConfiguration {}
extension MockBase {
    public func load() async throws {}
    public func unload() async {}
    public func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

@InferenceActor private final class MockLLM: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm, footprint: 60, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockTTS: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .tts, footprint: 60, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockImage60: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .textToImage, footprint: 60, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockBig: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .textToImage, footprint: 10_000, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockANE: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .imageAnalysis, footprint: 10, backends: [.coreMLANE], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockUltra: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .videoAnalysis, footprint: 10, backends: [.metalGPU], chipFloor: .ultra) }
    nonisolated init(configuration: StandardConfiguration) {}
}

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

private func engine(budget: UInt64, backends: Set<Backend> = [.metalGPU], chip: ChipTier = .max) -> MLXServeEngine {
    let device = DeviceProfile(chipTier: chip,
                               macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                               backends: backends,
                               totalMemoryBytes: 64_000_000_000)
    return MLXServeEngine(device: device, governor: MemoryGovernor(budgetBytes: budget))
}

// MARK: - Eligibility (C10)

@Test func registerRejectsMissingBackend() async {
    let e = engine(budget: 1_000, backends: [.metalGPU])
    await #expect(throws: EngineError.ineligible(.missingBackend(.coreMLANE))) {
        try await e.register(PackageRegistration.of(MockANE.self), configuration: cfg())
    }
}

@Test func registerRejectsChipBelowFloor() async {
    let e = engine(budget: 1_000, chip: .base)
    await #expect(throws: EngineError.ineligible(.chipBelowFloor(required: .ultra, have: .base))) {
        try await e.register(PackageRegistration.of(MockUltra.self), configuration: cfg())
    }
}

// MARK: - Memory governance

@Test func prepareRejectsFootprintLargerThanBudget() async throws {
    let e = engine(budget: 100)
    try await e.register(PackageRegistration.of(MockBig.self), configuration: cfg())
    await #expect(throws: EngineError.self) {
        _ = try await e.prepare(.textToImage)
    }
}

@Test func evictsLRUWhenFull() async throws {
    let e = engine(budget: 100) // fits one 60-byte working set
    try await e.register(PackageRegistration.of(MockLLM.self), configuration: cfg())
    try await e.register(PackageRegistration.of(MockTTS.self), configuration: cfg())

    try await e.prepare(.llm)
    var snap = await e.memory
    #expect(snap.residentBytes == 60)
    #expect(snap.residents[.llm] == 60)

    try await e.prepare(.tts) // needs 60, only 40 free → evict .llm
    snap = await e.memory
    #expect(snap.residentBytes == 60)
    #expect(snap.residents[.tts] == 60)
    #expect(snap.residents[.llm] == nil)
}

@Test func lruKeepsRecentlyUsed() async throws {
    let e = engine(budget: 120) // fits two 60-byte working sets
    try await e.register(PackageRegistration.of(MockLLM.self), configuration: cfg())
    try await e.register(PackageRegistration.of(MockTTS.self), configuration: cfg())
    try await e.register(PackageRegistration.of(MockImage60.self), configuration: cfg())

    try await e.prepare(.llm)
    try await e.prepare(.tts)                       // resident: llm + tts (120)
    _ = try await e.run(LLMRequest(prompt: "hi"))   // touch .llm → most recently used

    try await e.prepare(.textToImage)               // needs 60 → evict LRU (.tts)
    let snap = await e.memory
    #expect(snap.residents[.tts] == nil)
    #expect(snap.residents[.llm] == 60)
    #expect(snap.residents[.textToImage] == 60)
}

// MARK: - Multi-package per capability (modularity)

@InferenceActor private final class MockImageAlt: MockBase {
    nonisolated static var manifest: PackageManifest {
        var m = mockManifest(capability: .textToImage, footprint: 30, backends: [.metalGPU], chipFloor: nil)
        return PackageManifest(
            license: m.license, provenance: m.provenance, requirements: m.requirements,
            specialties: m.specialties,
            surfaces: [ToolDescriptor(name: "mock-t2i-alt", capability: .textToImage, summary: "alt")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
}

@Test func multiPackageSelectionAndDefaults() async throws {
    let e = engine(budget: 200)
    let primary = try await e.register(PackageRegistration.of(MockImage60.self), configuration: cfg())
    let alt = try await e.register(PackageRegistration.of(MockImageAlt.self), configuration: cfg())

    // Both back the capability; LAST registration is the default (swap-flow compatible).
    #expect(await e.packages(for: .textToImage).count == 2)
    #expect(await e.defaultPackage(for: .textToImage) == alt)

    // Re-point routing without re-registering.
    try await e.setDefault(primary, for: .textToImage)
    #expect(await e.defaultPackage(for: .textToImage) == primary)

    // Per-request selection: both can be resident simultaneously (60 + 30 ≤ 200).
    try await e.prepare(.textToImage)                 // default → primary (60)
    try await e.prepare(.textToImage, package: alt)   // explicit → alt (30)
    let residentBytes = await e.memory.residentBytes
    #expect(residentBytes == 90)

    // Selecting an id that doesn't back the capability is an error.
    await #expect(throws: EngineError.unknownPackage(.llm, alt)) {
        try await e.prepare(.llm, package: alt)
    }

    // Evict the specific module; the default stays resident.
    await e.evict(.textToImage, package: alt)
    let after = await e.residentPackages
    #expect(after[alt] == nil)
    #expect(after[primary] == 60)
}

// MARK: - Config-aware footprint (ISSUES W1)

/// Multi-footprint manifest (bf16 160 / int4 56) — the shape that triggered W1.
private func mockMultiManifest() -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/multi", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .bf16, residentBytes: 160),
                         QuantFootprint(quant: .int4, residentBytes: 56)],
            requiredBackends: [.metalGPU],
            os: OSRequirement(),
            chipFloor: nil),
        surfaces: [ToolDescriptor(name: "mock-multi", capability: .textToImage, summary: "mock")])
}

@InferenceActor private final class MockMulti: MockBase {
    nonisolated static var manifest: PackageManifest { mockMultiManifest() }
    nonisolated init(configuration: StandardConfiguration) {}
}

@Test func footprintMatchesRegisteredVariant() {
    let gov = MemoryGovernor(budgetBytes: 90)  // bf16 (160) exceeds budget → exposes the W1 trap
    let reqs = mockMultiManifest().requirements
    // Variant-agnostic survey: largest-that-fits picks int4 56 (bf16 doesn't fit) — the old charge.
    #expect(gov.footprint(for: reqs) == 56)
    // Config-aware: each registered variant is charged its own declared footprint.
    #expect(gov.footprint(for: reqs, quant: .bf16) == 160)  // NOT the silent 56 under-reserve
    #expect(gov.footprint(for: reqs, quant: .int4) == 56)
    // Safe fallbacks: no opt-in (nil) / no matching declared footprint → largest-that-fits.
    #expect(gov.footprint(for: reqs, quant: nil) == 56)
    #expect(gov.footprint(for: reqs, quant: .fp32) == 56)
}

@Test func registerChargesConfigVariant() async throws {
    // StandardConfiguration conforms to QuantConfigured → the engine charges the registered variant's
    // footprint end-to-end (register → prepare → resident). Budget fits bf16.
    let eBf16 = engine(budget: 300)
    try await eBf16.register(PackageRegistration.of(MockMulti.self),
                             configuration: StandardConfiguration(weightsRepo: "mock/multi", quant: .bf16))
    try await eBf16.prepare(.textToImage)
    #expect(await eBf16.memory.residentBytes == 160)

    let eInt4 = engine(budget: 300)
    try await eInt4.register(PackageRegistration.of(MockMulti.self),
                             configuration: StandardConfiguration(weightsRepo: "mock/multi", quant: .int4))
    try await eInt4.prepare(.textToImage)
    #expect(await eInt4.memory.residentBytes == 56)
}

@Test func bf16NoLongerSilentlyUnderReserves() async throws {
    // The W1 safety win: at a budget where bf16 (160) doesn't fit, a bf16 registration is charged
    // 160 and REJECTED at prepare — not silently admitted at the int4 56 figure (the old bug).
    let e = engine(budget: 90)
    try await e.register(PackageRegistration.of(MockMulti.self),
                         configuration: StandardConfiguration(weightsRepo: "mock/multi", quant: .bf16))
    await #expect(throws: EngineError.self) {
        _ = try await e.prepare(.textToImage)
    }
}
