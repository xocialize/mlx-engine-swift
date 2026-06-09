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
