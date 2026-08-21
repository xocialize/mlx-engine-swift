import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Fixtures
//
// Weights-volume floor enforcement (1.34.0, AB-T-0070): a variant declaring
// `minSustainedReadBytesPerSecond` must be REFUSED at prepare() when the measured volume sits
// below it — before construction, prewarm, or any command buffer. `UInt64.max` as the floor makes
// every real disk "too slow", so the tests exercise the refusal path deterministically on any
// hardware; the no-floor and warnOnly arms prove the default behavior is untouched.

private func makeWeightsDir() throws -> URL {
    let dir = URL.temporaryDirectory.appending(path: "floor-\(UUID().uuidString)",
                                               directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // ≥8 MB so the probe accepts it as a real measurement.
    try Data(count: 16 << 20).write(to: dir.appending(path: "model.safetensors"))
    return dir
}

/// Conforms to FootprintConfigured implementing only SOME members — the rest ride the extension
/// defaults, which is itself the conformer-compatibility proof for the 1.35.0 protocol addition.
private struct FloorConfiguration: PackageConfiguration, QuantConfigured, WeightPrewarming,
                                   FootprintConfigured {
    var weightsDir: URL
    var expectedRead: UInt64? = nil
    var quant: Quant { .bf16 }
    var prewarmPaths: [URL] { [weightsDir] }
    var residentBytesHint: UInt64? { nil }
    var expectedWeightReadBytesPerRunHint: UInt64? { expectedRead }
}

@InferenceActor
private final class FloorPackage: ModelPackage {
    typealias Configuration = FloorConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/floor", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1,
                                            minSustainedReadBytesPerSecond: UInt64.max)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "floor-llm", summary: "mock")])
    }
    nonisolated init(configuration: FloorConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

@InferenceActor
private final class NoFloorPackage: ModelPackage {
    typealias Configuration = FloorConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/nofloor", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "nofloor-llm", summary: "mock")])
    }
    nonisolated init(configuration: FloorConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

// MARK: - Enforcement

@Test func belowFloorVolumeIsRefusedAtPrepare() async throws {
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()
    let id = try await engine.register(PackageRegistration.of(FloorPackage.self),
                                       configuration: FloorConfiguration(weightsDir: dir))
    do {
        _ = try await engine.prepare(.llm, package: id)
        Issue.record("prepare() must refuse a below-floor volume")
    } catch PackageError.weightsVolumeBelowFloor(let msg) {
        // The refusal must carry the numbers and the override — it is the explainability the
        // I9 crash never had.
        #expect(msg.contains("GB/s") && msg.contains("warnOnly"))
    } catch {
        Issue.record("wrong error: \(error) — must be weightsVolumeBelowFloor")
    }
    // The refusal happened at the storage gate specifically — the characterization was recorded
    // on the way, so an app can render WHY.
    let c = await engine.volumeCharacterization(package: id.description)
    #expect(c?.sustainedReadBytesPerSecond != nil)
}

@Test func warnOnlyPolicyOverridesTheRefusal() async throws {
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()
    await engine.setStorageFloorPolicy(.warnOnly)
    let id = try await engine.register(PackageRegistration.of(FloorPackage.self),
                                       configuration: FloorConfiguration(weightsDir: dir))
    try await engine.prepare(.llm, package: id)   // must NOT throw
}

@Test func noFloorBehavesExactlyAsToday() async throws {
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()
    let id = try await engine.register(PackageRegistration.of(NoFloorPackage.self),
                                       configuration: FloorConfiguration(weightsDir: dir))
    try await engine.prepare(.llm, package: id)   // no refusal without a declared floor…
    let c = await engine.volumeCharacterization(package: id.description)
    #expect(c != nil)                             // …but the advisory data is still there
}


// MARK: - 1.35.0 advisories (AB-A-0013)

@Test func warnOnlyRecordsARenderableAdvisory() async throws {
    // Gap 1's regression test: .warnOnly was print-only — the posture an operator chooses for
    // UX must produce something an app can SHOW.
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()
    await engine.setStorageFloorPolicy(.warnOnly)
    let id = try await engine.register(PackageRegistration.of(FloorPackage.self),
                                       configuration: FloorConfiguration(weightsDir: dir))
    try await engine.prepare(.llm, package: id)
    let advisories = await engine.storageAdvisories(package: id.description)
    let floor = try #require(advisories.first { $0.kind == .belowCrashFloor })
    #expect(floor.requiredBytesPerSecond == UInt64.max)
    #expect(floor.measuredBytesPerSecond != nil)
    #expect(floor.message.contains("GB/s"))
}

@Test func enforceRecordsTheAdvisoryBeforeThrowing() async throws {
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()
    let id = try await engine.register(PackageRegistration.of(FloorPackage.self),
                                       configuration: FloorConfiguration(weightsDir: dir))
    _ = try? await engine.prepare(.llm, package: id)   // refuses
    let advisories = await engine.storageAdvisories(package: id.description)
    #expect(advisories.contains { $0.kind == .belowCrashFloor })   // renderable after the failure
}

@Test func perPackagePolicyOverridesTheGlobal() async throws {
    // Gap 2: global .enforce + package .warnOnly → this package prepares; and the reverse
    // direction refuses. "Warn here, enforce there" is now expressible.
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()                      // global default: .enforce
    let id = try await engine.register(PackageRegistration.of(FloorPackage.self),
                                       configuration: FloorConfiguration(weightsDir: dir))
    await engine.setStorageFloorPolicy(.warnOnly, package: id.description)
    try await engine.prepare(.llm, package: id)        // package override wins → no throw

    await engine.setStorageFloorPolicy(.warnOnly)      // flip global permissive…
    await engine.setStorageFloorPolicy(.enforce, package: id.description)   // …package strict
    await engine.evict(.llm)
    do {
        _ = try await engine.prepare(.llm, package: id)
        Issue.record("per-package .enforce must refuse")
    } catch PackageError.weightsVolumeBelowFloor { /* expected */ }
      catch { Issue.record("wrong error: \(error)") }
}

@Test func projectedIOAdvisoryComputesFromDeclaredReadVolume() async throws {
    // Gap 3: the engine projects I/O time from the MEASURED volume speed and the lane's declared
    // read volume — the app never re-derives the arithmetic.
    let dir = try makeWeightsDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = MLXServeEngine()
    let id = try await engine.register(
        PackageRegistration.of(NoFloorPackage.self),
        configuration: FloorConfiguration(weightsDir: dir, expectedRead: 147 << 30))
    try await engine.prepare(.llm, package: id)
    let advisories = await engine.storageAdvisories(package: id.description)
    let projected = try #require(advisories.first { $0.kind == .projectedIO })
    #expect(projected.expectedReadBytesPerRun == 147 << 30)
    let measured = try #require(projected.measuredBytesPerSecond)
    let seconds = try #require(projected.projectedIOSecondsPerRun)
    // The projection must BE the declared arithmetic, to double precision.
    #expect(abs(seconds - Double(147 << 30) / Double(measured)) < 0.001)
    #expect(projected.message.contains("GiB"))
}
