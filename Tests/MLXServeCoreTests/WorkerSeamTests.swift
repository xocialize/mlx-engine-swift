import Foundation
import Synchronization
import Testing
import MLXHubMetadata
import MLXToolKit
@testable import MLXServeCore

// Contract 1.57.0 — the worker seams a multi-process host needs (AB-A-0206): download-only
// `materialize(package:)` (item 2), the resolved lane the governor charges (item 1), the
// preparation event stream during a download (item 4), and a host-assigned budget (item 5).

// MARK: - Fixtures

/// Counts constructions and loads per configuration `tag`, so "downloaded without loading" is
/// observable while other tests construct the same package in parallel.
private let lifecycle = Mutex<[String: Int]>([:])

private struct WorkerConfiguration: PackageConfiguration, WeightSourcing, ModelStorable, QuantConfigured {
    var modelsRootDirectory: URL?
    var quant: Quant = .int4
    var tag = ""
    var weightSources: [WeightSource] {
        [WeightSource(role: "snapshot", repo: "org/worker-\(quant.rawValue)", revision: "abc123")]
    }
}

@InferenceActor
private final class WorkerPackage: ModelPackage {
    typealias Configuration = WorkerConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/worker", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 3_000, peakActivationBytes: 500),
                             QuantFootprint(quant: .int4, residentBytes: 1_000, peakActivationBytes: 500)],
                requiredBackends: [.metalGPU]),
            surfaces: [T2IContract.descriptor(name: "worker-t2i", summary: "mock")])
    }
    nonisolated init(configuration: WorkerConfiguration) {
        lifecycle.withLock { $0[configuration.tag, default: 0] += 1 }
    }
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data([1])))
    }
}

private struct SelfFetching: PackageConfiguration, WeightSourcing, SelfMaterializing, ModelStorable {
    var modelsRootDirectory: URL?
    var weightSources: [WeightSource] { [WeightSource(role: "main", repo: "org/self")] }
}

@InferenceActor
private final class SelfFetchingPackage: ModelPackage {
    typealias Configuration = SelfFetching
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/self", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "self-llm", summary: "mock")])
    }
    nonisolated init(configuration: SelfFetching) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock")
    }
}

/// Writes each source's files in the flat layout after an optional delay; counts calls.
private final class SlowMaterializer: WeightMaterializing, Sendable {
    let calls = Mutex(0)
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }

    func materialize(_ sources: [WeightSource], into root: URL) async throws {
        calls.withLock { $0 += 1 }
        WeightDownloadProgress.report(fraction: 0.5, bytesPerSecond: 1_000)
        try await Task.sleep(for: delay)
        let store = ModelStore(root: root)
        for source in sources {
            let dir = try #require(store.directory(for: source.repo))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: dir.appending(path: "model.safetensors"))
        }
        WeightDownloadProgress.report(fraction: 1, bytesPerSecond: nil)
    }
}

private struct FailingListing: HubMetadataProviding {
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] {
        throw HubMetadataError.httpStatus(404)
    }
}

private struct FixedListing: HubMetadataProviding {
    let entries: [HubFileEntry]
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] { entries }
}

private func makeStoreRoot() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "Worker-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - materialize(package:)

@Test func materializeDownloadsWithoutConstructingOrLoading() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = SlowMaterializer()
    let engine = MLXServeEngine(materializer: executor, diskPrecheckEnabled: false)
    await engine.useModelStore(ModelStore(root: root))
    let id = try await engine.register(PackageRegistration.of(WorkerPackage.self),
                                       configuration: WorkerConfiguration(tag: "materialize-only"))
    let events = engine.preparation.events()

    let report = try await engine.materialize(package: id)

    #expect(executor.calls.withLock { $0 } == 1)
    #expect(report.packageID == "worker-t2i")
    #expect(report.materialization == .engine)
    #expect(report.downloaded.map(\.repo) == ["org/worker-int4"])
    #expect(report.alreadyPresent.isEmpty)
    #expect(report.storeRoot == root)
    // Not constructed, not loaded, not charged.
    #expect(lifecycle.withLock { $0["materialize-only"] } == nil)
    #expect(await engine.memory.residentBytes == 0)
    #expect(await engine.needsDownload(.textToImage) == false)
    // The storage UI's marker is stamped, as a prepare would.
    #expect(ModelStore(root: root).hasMarker(for: "org/worker-int4"))

    // The phase stream showed the download and returned to idle (on disk, not resident).
    var phases: [PreparePhase] = []
    for await event in events {
        phases.append(event.phase)
        if event.phase == .idle { break }
    }
    #expect(phases.first == .downloading(fraction: 0, bytesPerSecond: nil))
    #expect(phases.contains(.downloading(fraction: 0.5, bytesPerSecond: 1_000)))
    #expect(phases.last == .idle)

    // A second materialize finds everything present; prepare downloads nothing.
    let again = try await engine.materialize(package: id)
    #expect(again.downloaded.isEmpty)
    #expect(again.alreadyPresent.map(\.repo) == ["org/worker-int4"])
    try await engine.prepare(.textToImage)
    #expect(executor.calls.withLock { $0 } == 1)
}

@Test func prepareDuringMaterializeWaitsInsteadOfDownloadingTwice() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = SlowMaterializer(delay: .milliseconds(300))
    let engine = MLXServeEngine(materializer: executor, diskPrecheckEnabled: false)
    await engine.useModelStore(ModelStore(root: root))
    let id = try await engine.register(PackageRegistration.of(WorkerPackage.self),
                                       configuration: WorkerConfiguration(quant: .bf16))

    async let materialized = engine.materialize(package: id)
    try await Task.sleep(for: .milliseconds(50))
    try await engine.prepare(.textToImage, package: id)
    _ = try await materialized
    #expect(executor.calls.withLock { $0 } == 1)
}

@Test func materializeRefusesWhatItCannotFetchWithoutLoading() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = MLXServeEngine(materializer: SlowMaterializer(), diskPrecheckEnabled: false)

    await #expect(throws: EngineError.packageNotRegistered("nope")) {
        try await engine.materialize(package: "nope")
    }
    let selfID = try await engine.register(PackageRegistration.of(SelfFetchingPackage.self),
                                           configuration: SelfFetching())
    await engine.useModelStore(ModelStore(root: root))
    do {
        try await engine.materialize(package: selfID)
        Issue.record("a SelfMaterializing package cannot be fetched without load()")
    } catch EngineError.materializationUnavailable(let id, let reason) {
        #expect(id == selfID)
        #expect(reason.contains("SelfMaterializing"))
    }

    let noStore = MLXServeEngine(materializer: SlowMaterializer(), diskPrecheckEnabled: false)
    let id = try await noStore.register(PackageRegistration.of(WorkerPackage.self),
                                        configuration: WorkerConfiguration())
    do {
        try await noStore.materialize(.textToImage)
        Issue.record("no model store, nowhere to download into")
    } catch EngineError.materializationUnavailable(let refused, let reason) {
        #expect(refused == id)
        #expect(reason.contains("useModelStore"))
    }
}

@Test func materializationErrorsNameTheRepoRevisionAndURL() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // A never-published repo: the listing 404s (AB-A-0153's bare httpStatus(404)).
    let unpublished = WeightMaterializer(listing: FailingListing(), retryPolicy: .none)
    do {
        try await unpublished.materialize([WeightSource(role: "main", repo: "org/never", revision: "v2")],
                                          into: root)
        Issue.record("the listing failed")
    } catch let error as WeightMaterializer.MaterializeError {
        guard case .source(let repo, let revision, let path, let url, let underlying) = error else {
            Issue.record("expected .source, got \(error)"); return
        }
        #expect(repo == "org/never")
        #expect(revision == "v2")
        #expect(path == nil)
        #expect(url.absoluteString == "https://huggingface.co/api/models/org/never/tree/v2")
        #expect(underlying as? HubMetadataError == .httpStatus(404))
        let message = error.localizedDescription
        #expect(message.contains("org/never@v2"))
        #expect(message.contains("may not exist"))
    }

    // A file the origin does not serve: named by path and resolve URL.
    let serve = root.appending(path: "serve", directoryHint: .isDirectory)
    let missingFile = WeightMaterializer(
        listing: FixedListing(entries: [HubFileEntry(path: "model.safetensors", size: 10)]),
        endpoint: serve, retryPolicy: .none)
    do {
        try await missingFile.materialize([WeightSource(role: "main", repo: "org/gone")],
                                          into: root.appending(path: "store"))
        Issue.record("the file is not served")
    } catch let error as WeightMaterializer.MaterializeError {
        guard case .source(let repo, let revision, let path, let url, _) = error else {
            Issue.record("expected .source, got \(error)"); return
        }
        #expect(repo == "org/gone")
        #expect(revision == "main")
        #expect(path == "model.safetensors")
        #expect(url.path.hasSuffix("org/gone/resolve/main/model.safetensors"))
    }
}

// MARK: - Resolved lane (item 1)

@Test func resolvedLaneIsWhatTheGovernorCharges() async throws {
    let engine = MLXServeEngine(materializer: SlowMaterializer(), diskPrecheckEnabled: false)
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    await engine.useModelStore(ModelStore(root: root))
    let configuration = WorkerConfiguration(quant: .int4)
    let id = try await engine.register(PackageRegistration.of(WorkerPackage.self),
                                       configuration: configuration)
    let lane = try await engine.resolvedLane(for: id)
    #expect(lane == ResolvedLane(manifest: WorkerPackage.manifest, configuration: configuration))
    #expect(lane.persistentBytes == 1_000)
    #expect(lane.peakTransientBytes == 500)
    #expect(lane.materialization == .engine)
    #expect(lane.weightSources.map(\.revision) == ["abc123"])

    try await engine.prepare(.textToImage)
    let memory = await engine.memory
    #expect(memory.residentBytes == lane.persistentBytes)
    #expect(memory.transientReserveBytes == lane.peakTransientBytes)
    await #expect(throws: EngineError.packageNotRegistered("other")) {
        try await engine.resolvedLane(for: "other")
    }
}

// MARK: - Worker budget (item 5)

@Test func workerBudgetSizesTheEngineFromTheHostsCeiling() async throws {
    let ceiling: UInt64 = 6_000_000_000
    let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: ceiling, cacheLimitBytes: 256 << 20),
                                materializer: SlowMaterializer(), diskPrecheckEnabled: false)
    #expect(await engine.memory.budgetBytes == ceiling)
    if let wired = engine.wiredLimitCeilingBytes { #expect(wired <= ceiling) }
    if let cap = engine.appliedGPUCacheLimitBytes { #expect(cap == 256 << 20) }

    let unwired = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: ceiling, wiresWeights: false))
    #expect(unwired.wiredLimitCeilingBytes == nil)

    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    await engine.useModelStore(ModelStore(root: root))
    let id = try await engine.register(PackageRegistration.of(WorkerPackage.self),
                                       configuration: WorkerConfiguration())
    try await engine.prepare(.textToImage)
    let report = await engine.workerMemoryReport()
    #expect(report.budgetBytes == ceiling)
    #expect(report.residentBytes == 1_000)
    #expect(report.transientReserveBytes == 500)
    #expect(report.residents == [id.description: 1_000])
    #expect(report.availableBytes == ceiling - 1_500)
    #expect(report.running.isEmpty)
    let json = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(WorkerMemoryReport.self, from: json) == report)
}
