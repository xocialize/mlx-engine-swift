import Foundation
import Testing
import MLXHubMetadata
import MLXToolKit
@testable import MLXServeCore

// MARK: - Fixtures

/// A configuration that declares one network weight source (nothing on disk in these tests, so the
/// MS-2 default probe reports it missing — exactly the fresh-machine case MS-3 previews).
private struct SourcedConfiguration: PackageConfiguration, WeightSourcing {
    var repo = "org/model"
    var weightSources: [WeightSource] { [WeightSource(role: "main", repo: repo)] }
}

@InferenceActor
private final class SourcedPackage: ModelPackage {
    typealias Configuration = SourcedConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/model", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "sourced-llm", summary: "mock")])
    }
    nonisolated init(configuration: SourcedConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

/// The same package with a configuration that declares nothing — the pre-MS-2 shape.
private struct UnsourcedConfiguration: PackageConfiguration {}

@InferenceActor
private final class UnsourcedPackage: ModelPackage {
    typealias Configuration = UnsourcedConfiguration
    nonisolated static var manifest: PackageManifest { SourcedPackage.manifest }
    nonisolated init(configuration: UnsourcedConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

/// A hub that reports one fixed total for every repo (or fails, modelling an unreachable hub).
private struct FixedSizeHub: HubMetadataProviding {
    let bytes: UInt64
    var reachable = true
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] {
        guard reachable else { throw HubMetadataError.httpStatus(503) }
        return [HubFileEntry(path: "model.safetensors", size: bytes)]
    }
}

private func makeStoreRoot() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "DiskPrecheck-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// These tests are about the MS-3 precheck, not the 1.24 executor — stub the executor out so a
/// `prepare()` that passes the precheck doesn't proceed into a real download.
private struct NoopMaterializer: WeightMaterializing {
    func materialize(_ sources: [WeightSource], into root: URL) async throws {}
}

// MARK: - MS-3

@Test func previewSizesTheMissingSourcesAgainstTheStoreVolume() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MLXServeEngine(hubMetadata: FixedSizeHub(bytes: 4_096))
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(SourcedPackage.self),
                              configuration: SourcedConfiguration())

    let preview = try #require(await engine.materializationPreview(.llm))
    #expect(preview.sources.map(\.role) == ["main"])
    #expect(preview.totalBytes == 4_096)
    #expect(preview.fits == true)
}

@Test func previewIsNilForAPackageThatDeclaresNoSources() async throws {
    // A configuration that isn't WeightSourcing has nothing to preview, and that is not an error.
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(UnsourcedPackage.self),
                              configuration: UnsourcedConfiguration())
    #expect(await engine.materializationPreview(.llm) == nil)
}

@Test func prepareRefusesWhenThePendingDownloadCannotFitTheVolume() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // A download larger than any volume — the precheck must fire before load(), not mid-write.
    let engine = MLXServeEngine(hubMetadata: FixedSizeHub(bytes: .max / 2))
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(SourcedPackage.self),
                              configuration: SourcedConfiguration())

    do {
        _ = try await engine.prepare(.llm)
        Issue.record("expected EngineError.insufficientDisk")
    } catch let error as EngineError {
        guard case .insufficientDisk(let required, let free) = error else {
            Issue.record("unexpected engine error: \(error)")
            return
        }
        #expect(required == UInt64.max / 2, "required=\(required) free=\(free)")
        #expect(free < required)
    }
}

@Test func prepareProceedsWhenTheHubIsUnreachable() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Unknown size must never block a materialization that would have succeeded.
    let engine = MLXServeEngine(hubMetadata: FixedSizeHub(bytes: .max / 2, reachable: false),
                                materializer: NoopMaterializer())
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(SourcedPackage.self),
                              configuration: SourcedConfiguration())

    _ = try await engine.prepare(.llm)
}

@Test func diskPrecheckEscapeHatchDisablesTheRefusal() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MLXServeEngine(hubMetadata: FixedSizeHub(bytes: .max / 2),
                                materializer: NoopMaterializer(),
                                diskPrecheckEnabled: false)
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(SourcedPackage.self),
                              configuration: SourcedConfiguration())

    _ = try await engine.prepare(.llm)
}

@Test func prepareSkipsThePrecheckWithNoStoreRoot() async throws {
    // No store root ⇒ no volume to check and no free-space reading; the package's own downloader
    // decides where the weights land.
    let engine = MLXServeEngine(hubMetadata: FixedSizeHub(bytes: .max / 2))
    try await engine.register(PackageRegistration.of(SourcedPackage.self),
                              configuration: SourcedConfiguration())
    _ = try await engine.prepare(.llm)
}
