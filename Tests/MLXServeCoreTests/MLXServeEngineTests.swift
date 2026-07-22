import Foundation
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

// MARK: - MS-1: the download probe reads the canonical (HF-cache) store layout

/// Before MS-1 `needsDownload` probed `<root>/<org>/<name>/` while the hub client materialized into
/// `<root>/models--<org>--<name>/`, so the marker never landed where the probe looked.
@Test func needsDownloadReadsTheHubCacheLayoutAndTheLegacyFallback() async throws {
    let root = URL.temporaryDirectory.appending(path: "EngineStore-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ModelStore(root: root)
    let engine = MLXServeEngine()
    await engine.useModelStore(store)
    try await engine.register(PackageRegistration.of(MockLLMPackage.self), configuration: mockConfig())

    // Fresh store → the weights still have to come from the network.
    #expect(await engine.needsDownload(.llm))

    // A marker in the canonical repo directory clears it.
    store.writeMarker(repo: "mock/mock", revision: "main", capabilities: [.llm])
    #expect(FileManager.default.fileExists(
        atPath: root.appending(path: "models--mock--mock").appending(path: ModelStore.markerName).path))
    #expect(await engine.needsDownload(.llm) == false)

    // …and so does one left behind by a pre-MS-1 engine (read-both tolerance window).
    let legacyRoot = URL.temporaryDirectory.appending(path: "EngineStoreLegacy-\(UUID().uuidString)",
                                                      directoryHint: .isDirectory)
    let legacyDir = legacyRoot.appending(path: "mock", directoryHint: .isDirectory)
        .appending(path: "mock", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: legacyRoot) }
    try Data("{}".utf8).write(to: legacyDir.appending(path: ModelStore.markerName))

    let legacyEngine = MLXServeEngine()
    await legacyEngine.useModelStore(ModelStore(root: legacyRoot))
    try await legacyEngine.register(PackageRegistration.of(MockLLMPackage.self), configuration: mockConfig())
    #expect(await legacyEngine.needsDownload(.llm) == false)
}

// MARK: - MS-4: guarded deletion

@Test func deleteWeightsRefusesWhileResidentAndSucceedsAfterEvict() async throws {
    let root = URL.temporaryDirectory.appending(path: "EngineDelete-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ModelStore(root: root)
    let repoDir = store.directory(for: "mock/mock")!
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: repoDir.appending(path: "model.safetensors"))

    let engine = MLXServeEngine()
    await engine.useModelStore(store)
    try await engine.register(PackageRegistration.of(MockLLMPackage.self), configuration: mockConfig())

    // Registered but NOT resident → deletable by design (weights re-materialize on next prepare).
    // Make it resident first so the guard has something to protect.
    _ = try await engine.run(LLMRequest(prompt: "hi"))
    do {
        try await engine.deleteWeights(repo: "mock/mock")
        Issue.record("expected EngineError.weightsInUse")
    } catch let error as EngineError {
        #expect(error == .weightsInUse(repo: "mock/mock", packageID: PackageID("mock-llm")))
    }
    #expect(FileManager.default.fileExists(atPath: repoDir.path))

    await engine.evict(.llm)
    try await engine.deleteWeights(repo: "mock/mock")
    #expect(FileManager.default.fileExists(atPath: repoDir.path) == false)
}

@Test func deleteWeightsIgnoresUnrelatedResidentsAndUnmaterializedRepos() async throws {
    let root = URL.temporaryDirectory.appending(path: "EngineDelete-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MLXServeEngine()
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(MockLLMPackage.self), configuration: mockConfig())
    _ = try await engine.run(LLMRequest(prompt: "hi"))

    // A resident package guards only ITS repo, and deleting nothing is not an error.
    try await engine.deleteWeights(repo: "other/repo")
}
