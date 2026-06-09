import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mock packages (no MLX — exercise the coordinator offline)

private func mockManifest(weightLicense: SPDXLicense) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: weightLicense, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/mock", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]
        ),
        surfaces: [LLMContract.descriptor(name: "mock-llm", summary: "mock")]
    )
}

@InferenceActor
private final class MockLLMPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(weightLicense: .apache2) }

    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}

    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard loaded else { throw PackageError.notLoaded }
        guard request.capability == .llm else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        return LLMResponse(text: "mock", finishReason: .stop)
    }
}

@InferenceActor
private final class MockGPLPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(weightLicense: SPDXLicense("GPL-3.0")) }
    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

// MARK: - Tests

@Test func registerThenRunRoutesToPackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockLLMPackage.self), configuration: mockConfig())
    #expect(await engine.registeredCapabilities == [.llm])

    let response = try await engine.run(LLMRequest(prompt: "hi"))
    let llm = try #require(response as? LLMResponse)
    #expect(llm.text == "mock")
}

@Test func runWithoutRegistrationThrowsNoPackage() async {
    let engine = MLXServeEngine()
    do {
        _ = try await engine.run(LLMRequest(prompt: "hi"))
        Issue.record("expected EngineError.noPackage")
    } catch let error as EngineError {
        #expect(error == .noPackage(.llm))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func registerRejectsNonPermissiveLicense() async {
    let engine = MLXServeEngine()
    do {
        try await engine.register(PackageRegistration.of(MockGPLPackage.self), configuration: mockConfig())
        Issue.record("expected EngineError.licenseRejected")
    } catch let error as EngineError {
        #expect(error == .licenseRejected(.rejectedWeight(SPDXLicense("GPL-3.0"))))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func evictThenRunReloads() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockLLMPackage.self), configuration: mockConfig())
    _ = try await engine.run(LLMRequest(prompt: "one"))
    await engine.evict(.llm)
    let response = try await engine.run(LLMRequest(prompt: "two"))
    #expect((response as? LLMResponse)?.text == "mock")
}
