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

private struct FloorConfiguration: PackageConfiguration, QuantConfigured, WeightPrewarming {
    var weightsDir: URL
    var quant: Quant { .bf16 }
    var prewarmPaths: [URL] { [weightsDir] }
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
