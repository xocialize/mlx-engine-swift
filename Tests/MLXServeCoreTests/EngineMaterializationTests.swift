import Foundation
import Testing
import MLXHubMetadata
import MLXToolKit
@testable import MLXServeCore

// MARK: - Fixtures
//
// Engine-executed materialization (contract 1.24): `resident()` downloads a `WeightSourcing`
// configuration's missing sources into the store BEFORE `load()`. These tests drive the hook
// through `prepare()` with a recording executor — no network.

private struct HookConfiguration: PackageConfiguration, WeightSourcing, ModelStorable {
    var modelsRootDirectory: URL?
    var weightSources: [WeightSource] { [WeightSource(role: "main", repo: "org/hooked")] }
}

/// Fails `load()` unless the declared sources are ALREADY materialized — the executor must have
/// run first (that is the 1.24 doctrine: the engine executes; `load()` just loads).
@InferenceActor
private final class HookPackage: ModelPackage {
    typealias Configuration = HookConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/hooked", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "hooked-llm", summary: "mock")])
    }
    private let configuration: HookConfiguration
    nonisolated init(configuration: HookConfiguration) { self.configuration = configuration }
    func load() async throws {
        let missing = configuration.missingWeightSources(storeRoot: configuration.modelsRootDirectory)
        guard missing.isEmpty else { throw PackageError.notLoaded }
    }
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

private struct OptOutConfiguration: PackageConfiguration, WeightSourcing, SelfMaterializing {
    var weightSources: [WeightSource] { [WeightSource(role: "main", repo: "org/self")] }
}

@InferenceActor
private final class OptOutPackage: ModelPackage {
    typealias Configuration = OptOutConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/self", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "selfmat-llm", summary: "mock")])
    }
    nonisolated init(configuration: OptOutConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

/// Records every call; optionally satisfies the sources (flat layout, like the live executor)
/// and reports progress through the ambient `WeightDownloadProgress` binding.
private final class RecordingMaterializer: WeightMaterializing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[WeightSource]] = []
    private var observedDownloadingStorage = false
    var calls: [[WeightSource]] { lock.withLock { recorded } }
    var observedDownloading: Bool { lock.withLock { observedDownloadingStorage } }

    let writesFiles: Bool
    /// When set, `materialize` reports a mid-download fraction and waits (bounded) until the
    /// monitor shows it — proving the engine's sink binding carries executor progress through.
    var monitor: PreparationMonitor?

    init(writesFiles: Bool) { self.writesFiles = writesFiles }

    func materialize(_ sources: [WeightSource], into root: URL) async throws {
        lock.withLock { recorded.append(sources) }
        if let monitor {
            WeightDownloadProgress.report(fraction: 0.5, bytesPerSecond: 1_234)
            for _ in 0 ..< 200 {   // the sink hops to the main actor; poll briefly
                let phase = await MainActor.run { monitor.phase(for: .llm) }
                if case .downloading(let fraction, let bps) = phase,
                   fraction == 0.5, bps == 1_234 {
                    lock.withLock { observedDownloadingStorage = true }
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        guard writesFiles else { return }
        let store = ModelStore(root: root)
        for source in sources {
            let dir = try #require(store.directory(for: source.repo))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: dir.appending(path: "model.safetensors"))
        }
    }
}

private func makeStoreRoot() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "EngineMat-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - The pre-load hook

@Test func engineMaterializesMissingSourcesBeforeLoad() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = RecordingMaterializer(writesFiles: true)
    let engine = MLXServeEngine(materializer: executor)
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(HookPackage.self),
                              configuration: HookConfiguration())
    #expect(await engine.needsDownload(.llm))

    // HookPackage.load() throws unless the sources are present — prepare() succeeding IS the
    // executed-before-load() evidence.
    try await engine.prepare(.llm)
    #expect(executor.calls.count == 1)
    #expect(executor.calls.first?.map(\.role) == ["main"])
    #expect(await engine.needsDownload(.llm) == false)

    // Idempotency ACROSS residencies: the store is satisfied now, so a re-prepare after evict
    // must not re-invoke the executor (the flat layout satisfies the MS-2 default probe).
    await engine.evict(.llm)
    try await engine.prepare(.llm)
    #expect(executor.calls.count == 1)
}

@Test func alreadySatisfiedStoreSkipsTheExecutor() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Materialize by hand (flat layout) before the engine ever runs.
    let store = ModelStore(root: root)
    let dir = try #require(store.directory(for: "org/hooked"))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: dir.appending(path: "model.safetensors"))

    let executor = RecordingMaterializer(writesFiles: false)
    let engine = MLXServeEngine(materializer: executor)
    await engine.useModelStore(store)
    try await engine.register(PackageRegistration.of(HookPackage.self),
                              configuration: HookConfiguration())
    try await engine.prepare(.llm)
    #expect(executor.calls.isEmpty)
}

@Test func selfMaterializingOptOutIsHonored() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = RecordingMaterializer(writesFiles: true)
    let engine = MLXServeEngine(materializer: executor)
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(OptOutPackage.self),
                              configuration: OptOutConfiguration())

    // Sources are missing, but the configuration claims its own executor — the engine stays out.
    try await engine.prepare(.llm)
    #expect(executor.calls.isEmpty)
}

@Test func noStoreRootSkipsTheExecutor() async throws {
    let executor = RecordingMaterializer(writesFiles: false)
    let engine = MLXServeEngine(materializer: executor)
    try await engine.register(PackageRegistration.of(OptOutPackage.self),
                              configuration: OptOutConfiguration())
    try await engine.prepare(.llm)
    #expect(executor.calls.isEmpty)
}

@Test func executorProgressReachesThePreparationMonitor() async throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = RecordingMaterializer(writesFiles: true)
    let engine = MLXServeEngine(materializer: executor)
    executor.monitor = engine.preparation
    await engine.useModelStore(ModelStore(root: root))
    try await engine.register(PackageRegistration.of(HookPackage.self),
                              configuration: HookConfiguration())
    try await engine.prepare(.llm)

    // The executor reported 0.5 @ 1234 B/s through the ambient sink and saw the monitor's
    // `.downloading` phase carry exactly that — the engine's binding reached the UI seam.
    #expect(executor.observedDownloading)
    #expect(await MainActor.run { engine.preparation.phase(for: .llm) } == .ready)
}

// MARK: - The live executor's transport (no network — file:// endpoint)

/// Serves the resolve layout from disk: `<serve>/<repo>/resolve/<revision>/<path>`.
private struct StubListing: HubMetadataProviding {
    let entries: [HubFileEntry]
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] { entries }
}

private final class FractionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ f: Double) { lock.lock(); stored.append(f); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Test func liveMaterializerStreamsIntoTheFlatStoreLayout() async throws {
    let scratch = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let serve = scratch.appending(path: "serve", directoryHint: .isDirectory)
    let root = scratch.appending(path: "store", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Three files in the "repo": a nested weight, a config, and one the globs must exclude.
    let base = serve.appending(path: "org/model/resolve/main", directoryHint: .isDirectory)
    let weights = Data((0 ..< 100_000).map { UInt8(truncatingIfNeeded: $0) })
    let config = Data("{\"a\":1}".utf8)
    let excluded = Data("nope".utf8)
    for (path, data) in [("sub/weights.safetensors", weights),
                         ("config.json", config),
                         ("notes.md", excluded)] {
        let url = base.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    let listing = StubListing(entries: [
        HubFileEntry(path: "sub/weights.safetensors", size: UInt64(weights.count)),
        HubFileEntry(path: "config.json", size: UInt64(config.count)),
        HubFileEntry(path: "notes.md", size: UInt64(excluded.count)),
    ])
    let source = WeightSource(role: "main", repo: "org/model",
                              matching: ["*.safetensors", "config.json"])
    let materializer = WeightMaterializer(listing: listing, endpoint: serve)

    let fractions = FractionBox()
    try await WeightDownloadProgress.$sink.withValue({ fraction, _ in fractions.append(fraction) }) {
        try await materializer.materialize([source], into: root)
    }

    let store = ModelStore(root: root)
    let dir = try #require(store.directory(for: "org/model"))
    #expect(try Data(contentsOf: dir.appending(path: "sub/weights.safetensors")) == weights)
    #expect(try Data(contentsOf: dir.appending(path: "config.json")) == config)
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "notes.md").path))
    #expect(fractions.values.last == 1.0)

    // What it wrote satisfies the MS-2 default probe — the engine won't re-invoke it.
    struct Probe: WeightSourcing { var weightSources: [WeightSource] }
    #expect(Probe(weightSources: [source]).missingWeightSources(storeRoot: root).isEmpty)

    // File-level resume: a size-identical file is not re-fetched (mutate the origin in place —
    // the destination must keep the first download's bytes).
    var flipped = weights; flipped[0] ^= 0xFF
    try flipped.write(to: base.appending(path: "sub/weights.safetensors"))
    try await materializer.materialize([source], into: root)
    #expect(try Data(contentsOf: dir.appending(path: "sub/weights.safetensors")) == weights)
}

@Test func liveMaterializerVerifiesDeclaredSizes() async throws {
    let scratch = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let serve = scratch.appending(path: "serve", directoryHint: .isDirectory)
    let root = scratch.appending(path: "store", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let url = serve.appending(path: "org/model/resolve/main/model.safetensors")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("short".utf8).write(to: url)

    // The listing promises more bytes than the origin serves — the executor must refuse the
    // truncated artifact instead of installing it.
    let listing = StubListing(entries: [HubFileEntry(path: "model.safetensors", size: 10_000)])
    let materializer = WeightMaterializer(listing: listing, endpoint: serve)
    await #expect(throws: WeightMaterializer.MaterializeError.self) {
        try await materializer.materialize([WeightSource(role: "main", repo: "org/model")],
                                           into: root)
    }
    let store = ModelStore(root: root)
    let dest = try #require(store.directory(for: "org/model")).appending(path: "model.safetensors")
    #expect(!FileManager.default.fileExists(atPath: dest.path))
}
