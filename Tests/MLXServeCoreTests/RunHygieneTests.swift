import Testing
import Foundation
import MLXToolKit
@testable import MLXServeCore

// V1 (run-lifecycle program, LTX-informed): a run that throws — a user cancel surfacing as
// `CancellationError`, or a genuine error — still runs the engine's pool-hygiene policy
// (`trimEveryRuns` counting, cancel-trim for large-transient packages, LRU touch) and
// propagates the error to the caller unchanged. All offline: the trims are proven through
// `policyTrimCount` (the `clearCache()` itself is best-effort without a Metal device), and
// every engine here uses `limit: .unmanaged` so no test writes the process-global cache limit.

private func mockManifest(capability: Capability, footprint: UInt64,
                          transient: UInt64) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/mock", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: footprint,
                                        peakActivationBytes: transient)],
            requiredBackends: [.metalGPU]
        ),
        surfaces: [ToolDescriptor(name: "mock-\(capability.rawValue)", capability: capability,
                                  summary: "mock")]
    )
}

private struct MockRunFailure: Error, Equatable {}

/// Throws `CancellationError` from `run()` — a package honoring the cooperative-cancellation
/// contract mid-generation. Declares an LTX-scale transient peak (2 GB ≥ the 1 GiB default
/// cancel-trim threshold).
@InferenceActor private final class CancellingBigTransientLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .llm, footprint: 1, transient: 2_000_000_000)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        throw CancellationError()
    }
}

/// Cancels too, but with a small transient peak (below the cancel-trim threshold).
@InferenceActor private final class CancellingSmallTransientLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .llm, footprint: 60, transient: 0)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        throw CancellationError()
    }
}

/// A genuine mid-run failure (not cancellation).
@InferenceActor private final class FailingLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .llm, footprint: 1, transient: 2_000_000_000)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        throw MockRunFailure()
    }
}

@InferenceActor private final class WellBehavedTTS: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .tts, footprint: 60, transient: 0)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

@InferenceActor private final class WellBehavedImage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .textToImage, footprint: 60, transient: 0)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

// Symbolic byte budgets + injected nil phys reading (real-pressure trigger off), and an
// unmanaged limit so the process-global MLX cache limit is never written from here.
private func engine(budget: UInt64, gpuCache: GPUCacheConfiguration) -> MLXServeEngine {
    let device = DeviceProfile(chipTier: .max,
                               macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                               backends: [.metalGPU],
                               totalMemoryBytes: 64_000_000_000)
    return MLXServeEngine(device: device, governor: MemoryGovernor(budgetBytes: budget),
                          gpuCache: gpuCache, physFootprint: { nil })
}

// MARK: - trimEveryRuns counts thrown runs

@Test func cancelledRunCountsForTrimEveryRuns() async throws {
    let e = engine(budget: 3_000_000_000,
                   gpuCache: GPUCacheConfiguration(limit: .unmanaged, trimEveryRuns: 2,
                                                   trimAfterCancelBytes: nil))
    try await e.register(PackageRegistration.of(CancellingBigTransientLLM.self), configuration: cfg())

    await #expect(throws: CancellationError.self) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 0)  // 1 of 2 — counted, not yet trimmed
    await #expect(throws: CancellationError.self) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 1)  // 2 of 2 — the cancelled runs reached the trim
}

@Test func genuineErrorCountsForTrimPolicyAndPropagatesUnchanged() async throws {
    let e = engine(budget: 3_000_000_000,
                   gpuCache: GPUCacheConfiguration(limit: .unmanaged, trimEveryRuns: 1,
                                                   trimAfterCancelBytes: nil))
    try await e.register(PackageRegistration.of(FailingLLM.self), configuration: cfg())

    await #expect(throws: MockRunFailure()) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 1)
}

// MARK: - Cancel-specific trim (trimAfterCancelBytes)

@Test func cancelledLargeTransientRunTrimsPool() async throws {
    // Default knob (1 GiB) vs a package declaring a 2 GB transient peak.
    let e = engine(budget: 3_000_000_000, gpuCache: GPUCacheConfiguration(limit: .unmanaged))
    try await e.register(PackageRegistration.of(CancellingBigTransientLLM.self), configuration: cfg())

    await #expect(throws: CancellationError.self) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 1)
}

@Test func cancelledSmallTransientRunDoesNotTrim() async throws {
    let e = engine(budget: 3_000_000_000, gpuCache: GPUCacheConfiguration(limit: .unmanaged))
    try await e.register(PackageRegistration.of(CancellingSmallTransientLLM.self), configuration: cfg())

    await #expect(throws: CancellationError.self) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 0)
}

@Test func genuineErrorDoesNotFireCancelTrim() async throws {
    // Same large transient, but a non-cancellation error: the cancel-specific trim stays off.
    let e = engine(budget: 3_000_000_000, gpuCache: GPUCacheConfiguration(limit: .unmanaged))
    try await e.register(PackageRegistration.of(FailingLLM.self), configuration: cfg())

    await #expect(throws: MockRunFailure()) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 0)
}

@Test func unmanagedPresetDisablesCancelTrim() async throws {
    let e = engine(budget: 3_000_000_000, gpuCache: .unmanaged)
    try await e.register(PackageRegistration.of(CancellingBigTransientLLM.self), configuration: cfg())

    await #expect(throws: CancellationError.self) { _ = try await e.run(LLMRequest(prompt: "x")) }
    #expect(await e.policyTrimCount == 0)
}

// MARK: - A cancelled run still touches LRU

@Test func cancelledRunKeepsPackageMostRecentlyUsed() async throws {
    // Budget fits two 60-byte working sets. Resident llm + tts (llm older), then a CANCELLED
    // llm run: the touch must make .tts the LRU victim when .textToImage needs the room.
    let e = engine(budget: 120, gpuCache: .unmanaged)
    try await e.register(PackageRegistration.of(CancellingSmallTransientLLM.self), configuration: cfg())
    try await e.register(PackageRegistration.of(WellBehavedTTS.self), configuration: cfg())
    try await e.register(PackageRegistration.of(WellBehavedImage.self), configuration: cfg())

    try await e.prepare(.llm)
    try await e.prepare(.tts)
    await #expect(throws: CancellationError.self) { _ = try await e.run(LLMRequest(prompt: "x")) }

    try await e.prepare(.textToImage)  // needs 60 → evicts the LRU
    let snap = await e.memory
    #expect(snap.residents[.tts] == nil)          // tts was the LRU — evicted
    #expect(snap.residents[.llm] == 60)           // the cancelled run kept llm hot
    #expect(snap.residents[.textToImage] == 60)
}
