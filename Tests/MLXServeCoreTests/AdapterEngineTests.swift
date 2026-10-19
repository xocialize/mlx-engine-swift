//
//  AdapterEngineTests.swift
//  MLXServeCoreTests
//
//  Contract 1.53.0 (AB-A-0189) — the engine half of typed adapters: the catalog and its licence
//  classification, the declaration pre-flight, routing by base model, the content-keyed fetch
//  with its SHA-256 check (through a recording executor AND the live materializer over a
//  `file://` hub), the consent posture, the admission reserve, and the load-time rebuild.
//  Offline, mock packages, no MLX.
//

import CryptoKit
import Foundation
import Testing
import MLXHubMetadata
import MLXToolKit
@testable import MLXServeCore

// MARK: - Fixtures

private let revision = String(repeating: "c", count: 40)
private let adapterBytes = Data("lora-delta-bytes".utf8)
private let adapterDigest = SHA256.hash(data: adapterBytes).map { String(format: "%02x", $0) }.joined()

private func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("adapter-engine-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func descriptor(id: String = "anime", base: String = "klein-4b",
                        kind: AdapterKind = .plain, digest: String = adapterDigest,
                        license: SPDXLicense = .apache2, bytes: UInt64? = UInt64(adapterBytes.count),
                        footprint: AdapterFootprint? = nil,
                        conditioning: [AdapterConditioningSlot] = []) -> AdapterDescriptor {
    AdapterDescriptor(id: id, kind: kind, format: .diffusersPEFT, baseModels: [base],
                      capabilities: [.textToImage],
                      source: AdapterSource(repo: "org/\(id)", revision: revision,
                                            file: "weights/\(id).safetensors", sha256: digest,
                                            bytes: bytes),
                      license: license, conditioning: conditioning, footprint: footprint)
}

private func icDescriptor() -> AdapterDescriptor {
    descriptor(id: "pose", kind: .referenceConditioned,
               footprint: AdapterFootprint(residentBytes: 500, activationMultiplier: 2),
               conditioning: [AdapterConditioningSlot(role: "pose", media: .image)])
}

/// What the mock packages saw, for the assertions. The suite is serialized.
@InferenceActor
private final class Seen {
    static let shared = Seen()
    var resolved: [[ResolvedAdapter]] = []
    var loads = 0
    var builtWith: [[String]] = []
    func reset() { resolved = []; loads = 0; builtWith = [] }
}

private func t2iManifest(name: String, support: AdapterSupport?, peak: UInt64 = 1_000) -> PackageManifest {
    var surface = T2IContract.descriptor(name: name, summary: "m")
    if let support { surface = surface.declaring(adapters: support) }
    return PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .bf16, residentBytes: 1, peakActivationBytes: peak)],
            requiredBackends: [.metalGPU]),
        surfaces: [surface])
}

private let kleinSupport = AdapterSupport(baseModel: "klein-4b", formats: [.diffusersPEFT],
                                          kinds: [.plain, .referenceConditioned], maxCount: 2)

/// Declares Klein-shaped per-request adapters, and answers with the first adapter file's bytes,
/// so a test sees exactly what crossed the engine.
@InferenceActor
private final class KleinPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { t2iManifest(name: "klein", support: kleinSupport) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { Seen.shared.loads += 1 }
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        let resolved = (request as? T2IRequest)?.resolvedAdapters ?? []
        Seen.shared.resolved.append(resolved)
        let data = try resolved.first.map { try Data(contentsOf: $0.fileURL) } ?? Data()
        return T2IResponse(image: Image(format: .png, data: data))
    }
}

/// A second T2I backer on another base model.
@InferenceActor
private final class QwenPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        t2iManifest(name: "qwen", support: AdapterSupport(baseModel: "qwen-image", formats: [.diffusersPEFT]))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data("qwen".utf8)))
    }
}

/// Declares nothing — every pre-1.53 package.
@InferenceActor
private final class PlainPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { t2iManifest(name: "plain", support: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data()))
    }
}

private struct LoadTimeConfiguration: PackageConfiguration, AdapterConfigured {
    var loadedAdapters: [ResolvedAdapter] = []
}

/// Fuses its adapters when built (Mage-Flow / Klein's `loraPath` today).
@InferenceActor
private final class LoadTimePackage: ModelPackage {
    typealias Configuration = LoadTimeConfiguration
    nonisolated static var manifest: PackageManifest {
        t2iManifest(name: "fused", support: AdapterSupport(baseModel: "klein-4b", formats: [.diffusersPEFT],
                                                           maxCount: 2, binding: .loadTime))
    }
    private let configuration: LoadTimeConfiguration
    nonisolated init(configuration: LoadTimeConfiguration) { self.configuration = configuration }
    func load() async throws {
        Seen.shared.loads += 1
        Seen.shared.builtWith.append(configuration.loadedAdapters.map(\.id))
    }
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data()))
    }
}

/// Load-time binding declared, but the configuration cannot be stamped.
@InferenceActor
private final class UnstampablePackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        t2iManifest(name: "unstampable", support: AdapterSupport(baseModel: "klein-4b",
                                                                 formats: [.diffusersPEFT], binding: .loadTime))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data()))
    }
}

/// Serves files out of memory into the flat store layout, like the live executor; records calls.
private final class ServingMaterializer: WeightMaterializing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WeightSource] = []
    var calls: [WeightSource] { lock.withLock { recorded } }
    let payload: Data
    init(payload: Data = adapterBytes) { self.payload = payload }

    func materialize(_ sources: [WeightSource], into root: URL) async throws {
        lock.withLock { recorded.append(contentsOf: sources) }
        for source in sources {
            let dir = ModelStore(root: root).directory(for: source.repo)!
            for path in source.matching ?? [] {
                let file = dir.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try payload.write(to: file)
            }
        }
    }
}

private struct Listing: HubMetadataProviding {
    let entries: [HubFileEntry]
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] { entries }
}

private func makeEngine(materializer: any WeightMaterializing = ServingMaterializer(),
                        hub: any HubMetadataProviding = Listing(entries: []),
                        budget: UInt64 = 1 << 40,
                        enforcement: LicenseEnforcement = .advisory,
                        root: URL? = scratch()) async -> MLXServeEngine {
    let engine = MLXServeEngine(licenseEnforcement: enforcement,
                                governor: MemoryGovernor(budgetBytes: budget),
                                hubMetadata: hub, materializer: materializer,
                                diskPrecheckEnabled: false)
    if let root { await engine.useModelStore(ModelStore(root: root)) }
    return engine
}

private func refusal(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

private func config() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/x") }

// MARK: - Tests

@Suite("Typed adapters in the engine — contract 1.53.0", .serialized)
struct AdapterEngineTests {

    @Test func registrationValidatesAndClassifiesTheLicence() async throws {
        let engine = await makeEngine()
        let unpinned = AdapterDescriptor(
            id: "bad", format: .kohya, baseModels: ["klein-4b"], capabilities: [.textToImage],
            source: AdapterSource(repo: "org/bad", revision: "main", file: "x.safetensors",
                                  sha256: adapterDigest),
            license: .apache2)
        await #expect(throws: EngineError.invalidAdapter(
            id: "bad", problems: ["revision \"main\" is not a 40-character commit hash"])) {
            try await engine.registerAdapter(unpinned)
        }
        #expect(await engine.registeredAdapters.isEmpty)

        // Advisory (the default): a non-allowlisted adapter licence is recorded, not refused.
        let research = descriptor(id: "research", license: "LicenseRef-Research-Only")
        try await engine.registerAdapter(research)
        #expect(await engine.adapter(id: "research") == research)
        #expect(await engine.licenseAdvisories.contains {
            $0.repo == "org/research" && $0.license == "LicenseRef-Research-Only" && $0.layer == .weight
        })

        // Blocking: refused, naming the licence.
        let strict = await makeEngine(enforcement: .blocking)
        await #expect(throws: EngineError.licenseRejected(.rejectedWeight("LicenseRef-Research-Only"))) {
            try await strict.registerAdapter(research)
        }
    }

    @Test func aSurfaceThatDeclaresNoAdaptersRefusesThemBeforeAnyDownload() async throws {
        let materializer = ServingMaterializer()
        let engine = await makeEngine(materializer: materializer)
        try await engine.register(.of(PlainPackage.self), configuration: config())
        try await engine.registerAdapter(descriptor())
        do {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
            Issue.record("expected a refusal")
        } catch {
            #expect(refusal(error)?.contains("declares no adapter support") == true)
        }
        #expect(materializer.calls.isEmpty)
        #expect(await engine.residentPackages.isEmpty)
        // No adapters asked: the same package runs as it always did.
        _ = try await engine.run(T2IRequest(prompt: "p"))
    }

    @Test func aRunFetchesHashChecksAndStampsItsAdapters() async throws {
        await Seen.shared.reset()
        let root = scratch()
        let materializer = ServingMaterializer()
        let engine = await makeEngine(materializer: materializer, root: root)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        let anime = descriptor()
        try await engine.registerAdapter(anime)
        #expect(await engine.adapterNeedsDownload(id: "anime"))

        let response = try await engine.run(
            T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime", strength: 0.75)])) as! T2IResponse
        #expect(response.image.data == adapterBytes)          // the package read the verified file

        // Fetched at the PINNED revision, exactly the one file.
        #expect(materializer.calls == [WeightSource(role: "adapter", repo: "org/anime", revision: revision,
                                                    matching: ["weights/anime.safetensors"])])
        let seen = await Seen.shared.resolved.last ?? []
        let expectedFile = root.appending(path: "adapters/\(adapterDigest)/anime.safetensors")
        #expect(seen.map(\.id) == ["anime"])
        #expect(seen.first?.fileURL.standardizedFileURL == expectedFile.standardizedFileURL)
        #expect(seen.first?.strength == 0.75)
        #expect(seen.first?.footprint == AdapterFootprint(residentBytes: UInt64(adapterBytes.count)))
        #expect(!(await engine.adapterNeedsDownload(id: "anime")))
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "adapters/\(adapterDigest)/\(ModelStore.adapterMarkerName)").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "adapters/\(adapterDigest)/.download").path))

        // A verified file is reused: no second fetch.
        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        #expect(materializer.calls.count == 1)
        #expect(await Seen.shared.resolved.last?.first?.strength == 1)   // the descriptor's default

        // The engine always re-stamps: a caller's own resolvedAdapters never reaches the package.
        let forged = ResolvedAdapter(id: "forged", kind: .plain, format: .kohya,
                                     fileURL: URL(fileURLWithPath: "/etc/passwd"), source: anime.source,
                                     strength: 1, footprint: AdapterFootprint(residentBytes: 0))
        _ = try await engine.run(T2IRequest(prompt: "p").resolving([forged]))
        #expect(await Seen.shared.resolved.last == [])
    }

    @Test func aPresentButUnverifiedFileIsHashedNotRefetched() async throws {
        await Seen.shared.reset()
        let root = scratch()
        let materializer = ServingMaterializer()
        let engine = await makeEngine(materializer: materializer, root: root)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        let anime = descriptor()
        try await engine.registerAdapter(anime)
        let file = ModelStore(root: root).adapterFile(for: anime.source)!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try adapterBytes.write(to: file)    // copied in by hand, no marker

        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        #expect(materializer.calls.isEmpty)
        #expect(ModelStore(root: root).hasVerifiedAdapter(anime.source))
    }

    @Test func aDigestMismatchDeletesTheFileAndRunsNothing() async throws {
        await Seen.shared.reset()
        let root = scratch()
        let engine = await makeEngine(materializer: ServingMaterializer(payload: Data("tampered".utf8)),
                                      root: root)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        try await engine.registerAdapter(descriptor(bytes: nil))
        do {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
            Issue.record("expected a digest mismatch")
        } catch let EngineError.adapterDigestMismatch(id, expected, actual) {
            #expect(id == "anime")
            #expect(expected == adapterDigest)
            #expect(actual != adapterDigest)
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "adapters/\(adapterDigest)/anime.safetensors").path))
        #expect(await Seen.shared.loads == 0)
        #expect(await engine.residentPackages.isEmpty)
    }

    @Test func preparedOnlyRefusesUntilTheHostPreparesWithConsent() async throws {
        await Seen.shared.reset()
        let materializer = ServingMaterializer()
        let hub = Listing(entries: [HubFileEntry(path: "weights/anime.safetensors", size: 4_242)])
        let engine = await makeEngine(materializer: materializer, hub: hub)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        try await engine.registerAdapter(descriptor(bytes: nil))     // size comes from the hub
        await engine.setAdapterFetchPolicy(.preparedOnly)

        await #expect(throws: EngineError.adapterNotMaterialized(id: "anime")) {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        }
        #expect(materializer.calls.isEmpty)

        let preview = await engine.adapterMaterializationPreview(["anime", "not-in-catalog"])
        #expect(preview.sources == [MaterializationPreview.Source(role: "adapter:anime", repo: "org/anime",
                                                                  expectedBytes: 4_242)])
        #expect(preview.totalBytes == 4_242)
        #expect(preview.freeBytes != nil)

        let files = try await engine.prepareAdapters(["anime"])
        #expect(files["anime"].map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(await engine.adapterMaterializationPreview(["anime"]).isSatisfied)
        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        #expect(materializer.calls.count == 1)

        await #expect(throws: PackageError.unsupportedRequestFeature(
            "adapter \"ghost\" — not in the engine's adapter catalog")) {
            try await engine.prepareAdapters(["ghost"])
        }
    }

    @Test func noModelsRootMeansNoAdapters() async throws {
        let engine = await makeEngine(root: nil)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        try await engine.registerAdapter(descriptor())
        await #expect(throws: EngineError.adapterStoreUnset(id: "anime")) {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        }
    }

    @Test func theAdapterImpliesItsBaseModel() async throws {
        await Seen.shared.reset()
        let engine = await makeEngine()
        try await engine.register(.of(KleinPackage.self), configuration: config())
        try await engine.register(.of(QwenPackage.self), configuration: config())   // now the default
        try await engine.registerAdapter(descriptor())
        try await engine.registerAdapter(descriptor(id: "qwen-style", base: "qwen-image"))

        #expect(await engine.adapters(for: .textToImage).map(\.id) == ["qwen-style"])
        #expect(await engine.adapters(for: .textToImage, package: "klein").map(\.id) == ["anime"])

        // No package named: routed to the backer the adapter fits, not the default.
        let routed = try await engine.run(
            T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")])) as! T2IResponse
        #expect(routed.image.data == adapterBytes)
        // A package named that the adapter does not fit is refused (the 422 the image engine maps).
        do {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]),
                                     package: "qwen")
            Issue.record("expected a refusal")
        } catch {
            #expect(refusal(error)?.contains("not this surface's base model qwen-image") == true)
        }
    }

    @Test func adapterBytesAndTheICMultiplierAreChargedToTheRun() async throws {
        await Seen.shared.reset()
        // Persistent 1 B + peak 1 000 B. The IC adapter doubles the peak and holds 500 B while
        // applied: 1 + 2 000 + 500 = 2 501 B, past a 2 000 B budget the bare run fits.
        let engine = await makeEngine(budget: 2_000)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        try await engine.registerAdapter(icDescriptor())
        _ = try await engine.run(T2IRequest(prompt: "p"))

        let pose = AdapterRef(id: "pose", conditioning: [
            ConditioningInput(role: "pose", media: .image(Image(format: .png, data: Data([1])))),
        ])
        await #expect(throws: EngineError.exceedsMemoryBudget(required: 2_501, budget: 2_000)) {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [pose]))
        }

        let roomy = await makeEngine(budget: 3_000)
        try await roomy.register(.of(KleinPackage.self), configuration: config())
        try await roomy.registerAdapter(icDescriptor())
        _ = try await roomy.run(T2IRequest(prompt: "p", adapters: [pose]))
        let seen = await Seen.shared.resolved.last ?? []
        #expect(seen.first?.conditioning.map(\.role) == ["pose"])
        #expect(seen.first?.kind == .referenceConditioned)

        // A 16-bit conditioning image is held to the surface's raw-format declaration too.
        let raw = AdapterRef(id: "pose", conditioning: [
            ConditioningInput(role: "pose", media: .image(Image.rawRGBA16(data: Data(count: 8), width: 1,
                                                                            height: 1))),
        ])
        do {
            _ = try await roomy.run(T2IRequest(prompt: "p", adapters: [raw]))
            Issue.record("expected a refusal")
        } catch {
            #expect(refusal(error)?.contains("rawRGBA16") == true)
        }
    }

    @Test func aLoadTimeSurfaceIsRebuiltWhenTheSetChanges() async throws {
        await Seen.shared.reset()
        let engine = await makeEngine()
        try await engine.register(.of(LoadTimePackage.self), configuration: LoadTimeConfiguration())
        try await engine.registerAdapter(descriptor())
        try await engine.registerAdapter(descriptor(id: "ink"))

        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
        #expect(await Seen.shared.builtWith == [["anime"]])            // same set: no rebuild

        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime"),
                                                                    AdapterRef(id: "ink")]))
        _ = try await engine.run(T2IRequest(prompt: "p"))
        #expect(await Seen.shared.builtWith == [["anime"], ["anime", "ink"], []])
        // The built set is persistent residency; nothing is held now.
        #expect(await engine.residentPackages["fused"] == 1)

        _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime", strength: 0.5)]))
        #expect(await engine.residentPackages["fused"] == 1 + UInt64(adapterBytes.count))
        #expect(await Seen.shared.loads == 4)
    }

    @Test func aLoadTimeSurfaceWithoutAnAdapterConfiguredConfigurationRefuses() async throws {
        let engine = await makeEngine()
        try await engine.register(.of(UnstampablePackage.self), configuration: config())
        try await engine.registerAdapter(descriptor())
        do {
            _ = try await engine.run(T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")]))
            Issue.record("expected a refusal")
        } catch {
            #expect(refusal(error)?.contains("does not adopt AdapterConfigured") == true)
        }
    }

    /// The live executor end to end over a `file://` hub: the URL carries the pinned revision
    /// (a `main` copy of the file is a different payload and would fail the digest).
    @Test func theLiveMaterializerFetchesThePinnedRevision() async throws {
        await Seen.shared.reset()
        let hubRoot = scratch()
        for (rev, payload) in [(revision, adapterBytes), ("main", Data("moved-on".utf8))] {
            let file = hubRoot.appending(path: "org/anime/resolve/\(rev)/weights/anime.safetensors")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try payload.write(to: file)
        }
        let listing = Listing(entries: [HubFileEntry(path: "weights/anime.safetensors",
                                                     size: UInt64(adapterBytes.count))])
        let live = WeightMaterializer(listing: listing, endpoint: hubRoot, token: nil, retryPolicy: .none)
        let engine = await makeEngine(materializer: live, hub: listing)
        try await engine.register(.of(KleinPackage.self), configuration: config())
        try await engine.registerAdapter(descriptor())

        let response = try await engine.run(
            T2IRequest(prompt: "p", adapters: [AdapterRef(id: "anime")])) as! T2IResponse
        #expect(response.image.data == adapterBytes)
    }
}
