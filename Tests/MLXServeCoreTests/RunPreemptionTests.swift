import Testing
import Foundation
import MLXToolKit
@testable import MLXServeCore

// V3 (run-lifecycle program, ROADMAP 3.4): user-cancel vs governor-cancel disambiguation +
// mid-run preemption/requeue. All offline with cooperative mock packages that yield between
// "steps" (the LTX-proven checkpoint pattern). Serialized: the mocks coordinate through
// per-class probes, and `InferenceActor` is process-global.
//
// Covered here:
//   - user cancel (cancel the Task wrapping engine.run()) surfaces CancellationError, no requeue
//   - governor preemption requeues; the preempted caller gets a GENUINE response
//   - the retry bound degrades repeated preemption to EngineError.preemptionRetryExhausted
//   - a nearly-done victim (V2 progress ≥ threshold) is waited for, not cancelled
//   - V1 hygiene (cancel-trim) fires on the preempt path; V2 monitor clears on every exit
//   - a package with a run in flight is never the idle-LRU victim; prepare() never preempts

// MARK: - Probes

/// Cross-actor scratch a mock package reports its behavior into. Lock-guarded: written from
/// `InferenceActor`, read from test tasks.
private final class RunProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0
    private var _cancelledMidRun = false

    func reset() { lock.withLock { _attempts = 0; _cancelledMidRun = false } }
    /// Registers the start of one run() attempt and returns its ordinal (1-based).
    func beginAttempt() -> Int { lock.withLock { _attempts += 1; return _attempts } }
    func noteCancelled() { lock.withLock { _cancelledMidRun = true } }

    var attempts: Int { lock.withLock { _attempts } }
    var cancelledMidRun: Bool { lock.withLock { _cancelledMidRun } }
}

// MARK: - Mock packages (cooperative: yield between steps, honor Task.checkCancellation)

private func mockManifest(name: String, capability: Capability = .llm,
                          persistent: UInt64, transient: UInt64 = 0) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: persistent,
                                        peakActivationBytes: transient)],
            requiredBackends: [.metalGPU]
        ),
        surfaces: [ToolDescriptor(name: name, capability: capability, summary: "mock")]
    )
}

/// The canonical cooperative victim: attempt 1 reports early progress then spins at yield
/// points until cancelled (rethrowing the CancellationError, LTX-style); a requeued attempt
/// (≥ 2) completes immediately with a genuine response.
@InferenceActor private final class SpinningVictim: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static let probe = RunProbe()
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "victim-llm", persistent: 60)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        if Self.probe.beginAttempt() == 1 {
            RunProgress.report(.generate, step: 1, totalSteps: 10)
            do {
                while true {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                Self.probe.noteCancelled()
                throw error
            }
        }
        return LLMResponse(text: "victim-after-requeue", finishReason: .stop)
    }
}

/// Same spin-until-cancelled behavior, but declares an LTX-scale transient peak (2 GB ≥ the
/// 1 GiB default cancel-trim threshold) — proves V1 hygiene fires on the preempt path.
@InferenceActor private final class BigTransientVictim: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static let probe = RunProbe()
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "bigvictim-llm", persistent: 1, transient: 2_000_000_000)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        if Self.probe.beginAttempt() == 1 {
            RunProgress.report(.denoise, step: 2, totalSteps: 20)
            do {
                while true {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                Self.probe.noteCancelled()
                throw error
            }
        }
        return LLMResponse(text: "bigvictim-after-requeue", finishReason: .stop)
    }
}

/// Reports NEARLY-DONE progress (step 9/10 ≥ the 0.8 default), then finishes on its own after
/// a bounded number of cooperative yields — the run the policy must wait for, never cancel.
@InferenceActor private final class NearlyDoneVictim: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static let probe = RunProbe()
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "neardone-llm", persistent: 60)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        _ = Self.probe.beginAttempt()
        RunProgress.report(.generate, step: 9, totalSteps: 10)
        do {
            for _ in 0 ..< 300 {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            Self.probe.noteCancelled()
            throw error
        }
        return LLMResponse(text: "victim-finished-naturally", finishReason: .stop)
    }
}

/// The queued contender: same capability, immediate genuine response.
@InferenceActor private final class QuickContender: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "contender-llm", persistent: 60)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "contender", finishReason: .stop)
    }
}

/// A contender sized so admitting it forces the big-transient victim out (2.5 GB vs a 3 GB
/// budget where the victim's transient reserve alone is 2 GB).
@InferenceActor private final class BigContender: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "bigcontender-llm", persistent: 2_500_000_000)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "bigcontender", finishReason: .stop)
    }
}

/// Idle co-residents for the LRU-protection test.
@InferenceActor private final class IdleTTS: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "idle-tts", capability: .tts, persistent: 60)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "tts", finishReason: .stop)
    }
}

@InferenceActor private final class IdleImage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "idle-t2i", capability: .textToImage, persistent: 60)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "t2i", finishReason: .stop)
    }
}

// MARK: - Harness

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

/// Symbolic byte budgets, injected nil phys reading (real-pressure trigger off), unmanaged
/// GPU-cache limit (never writes the process-global cap from tests).
private func engine(budget: UInt64,
                    gpuCache: GPUCacheConfiguration = .unmanaged,
                    preemption: PreemptionPolicy = PreemptionPolicy()) -> MLXServeEngine {
    let device = DeviceProfile(chipTier: .max,
                               macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                               backends: [.metalGPU],
                               totalMemoryBytes: 64_000_000_000)
    return MLXServeEngine(device: device, governor: MemoryGovernor(budgetBytes: budget),
                          gpuCache: gpuCache, preemption: preemption, physFootprint: { nil })
}

/// Poll until the named package's in-flight run has delivered a progress report to the
/// preemption policy — the "victim is genuinely mid-run, signal landed" barrier.
private func waitUntilRunning(_ e: MLXServeEngine, _ id: PackageID) async throws {
    for _ in 0 ..< 5000 {
        if await e.activeRunLatestReport(for: id) != nil { return }
        await Task.yield()
    }
    Issue.record("run of \(id) never reported progress")
}

/// Poll until the run monitor reads "not running" for a capability/package (MainActor hops lag).
private func waitUntilMonitorClear(_ e: MLXServeEngine, _ capability: Capability,
                                   package: String) async -> Bool {
    for _ in 0 ..< 5000 {
        let clear = await MainActor.run {
            e.runProgress.report(for: capability, package: package) == nil
        }
        if clear { return true }
        await Task.yield()
    }
    return false
}

// MARK: - Tests

@Suite(.serialized) struct RunPreemptionTests {

    // The USER lane: cancelling the Task wrapping engine.run() is the sanctioned app-side
    // cancel; it surfaces CancellationError (→ .cancelled), and nothing requeues.
    @Test func userCancelSurfacesCancellationErrorWithoutRequeue() async throws {
        SpinningVictim.probe.reset()
        let e = engine(budget: 200)
        try await e.register(PackageRegistration.of(SpinningVictim.self), configuration: cfg())

        let wrapper = Task { try await e.run(LLMRequest(prompt: "v"), package: "victim-llm") }
        try await waitUntilRunning(e, "victim-llm")
        wrapper.cancel()

        await #expect(throws: CancellationError.self) { _ = try await wrapper.value }
        #expect(SpinningVictim.probe.attempts == 1)           // no requeue on the user lane
        #expect(SpinningVictim.probe.cancelledMidRun)
        #expect(await waitUntilMonitorClear(e, .llm, package: "victim-llm"))  // V2 clears
    }

    // The GOVERNOR lane: a queued contender that can't fit preempts the victim; the victim's
    // caller keeps awaiting and gets a GENUINE response from the requeued attempt.
    @Test func governorPreemptionRequeuesAndCallerGetsGenuineResponse() async throws {
        SpinningVictim.probe.reset()
        let e = engine(budget: 60) // fits exactly ONE of the two 60-byte packages
        try await e.register(PackageRegistration.of(SpinningVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(QuickContender.self), configuration: cfg())

        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "victim-llm") }
        try await waitUntilRunning(e, "victim-llm")

        // The contender's admission must preempt the running victim (last resort: no idle
        // residents exist) and then serve a normal response.
        let contender = try await e.run(LLMRequest(prompt: "c"), package: "contender-llm")
        #expect((contender as? LLMResponse)?.text == "contender")

        // The preempted caller never saw a CancellationError — the requeued attempt answered.
        let victim = try await victimCall.value
        #expect((victim as? LLMResponse)?.text == "victim-after-requeue")
        #expect(SpinningVictim.probe.attempts == 2)         // preempted once, requeued once
        #expect(SpinningVictim.probe.cancelledMidRun)       // the preemption really cancelled it

        // Requeue re-ran through normal admission: the victim displaced the now-idle contender.
        let resident = await e.residentPackages
        #expect(resident["victim-llm"] == 60)
        #expect(resident["contender-llm"] == nil)

        // V2: no run in flight → the monitor reads nil for both packages.
        #expect(await waitUntilMonitorClear(e, .llm, package: "victim-llm"))
        #expect(await waitUntilMonitorClear(e, .llm, package: "contender-llm"))
    }

    // The retry bound: with maxRequeues = 0, a single preemption degrades to the clear error,
    // never an infinite requeue loop (and never a bare CancellationError the caller didn't cause).
    @Test func preemptionRetryBoundDegradesToClearError() async throws {
        SpinningVictim.probe.reset()
        let e = engine(budget: 60, preemption: PreemptionPolicy(maxRequeues: 0))
        try await e.register(PackageRegistration.of(SpinningVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(QuickContender.self), configuration: cfg())

        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "victim-llm") }
        try await waitUntilRunning(e, "victim-llm")
        _ = try await e.run(LLMRequest(prompt: "c"), package: "contender-llm")

        await #expect(throws: EngineError.preemptionRetryExhausted(requeues: 1)) {
            _ = try await victimCall.value
        }
        #expect(SpinningVictim.probe.attempts == 1) // the bound stopped the requeue
    }

    // Governor policy: a victim whose V2 progress reads nearly done (9/10 ≥ 0.8) is WAITED for,
    // not cancelled — its minutes of GPU work survive, the contender queues behind it.
    @Test func nearlyDoneVictimIsWaitedForNotPreempted() async throws {
        NearlyDoneVictim.probe.reset()
        let e = engine(budget: 60)
        try await e.register(PackageRegistration.of(NearlyDoneVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(QuickContender.self), configuration: cfg())

        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "neardone-llm") }
        try await waitUntilRunning(e, "neardone-llm")

        let contender = try await e.run(LLMRequest(prompt: "c"), package: "contender-llm")
        #expect((contender as? LLMResponse)?.text == "contender")

        let victim = try await victimCall.value
        #expect((victim as? LLMResponse)?.text == "victim-finished-naturally")
        #expect(NearlyDoneVictim.probe.attempts == 1)          // one attempt — no requeue
        #expect(!NearlyDoneVictim.probe.cancelledMidRun)       // and it was never cancelled
    }

    // V1 hygiene holds on the preempt path: the preempted run counts as a cancelled run, so a
    // large-transient victim triggers the immediate cancel-trim (trimAfterCancelBytes default).
    @Test func preemptionFiresCancelTrimHygiene() async throws {
        BigTransientVictim.probe.reset()
        let e = engine(budget: 3_000_000_000,
                       gpuCache: GPUCacheConfiguration(limit: .unmanaged))
        try await e.register(PackageRegistration.of(BigTransientVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(BigContender.self), configuration: cfg())

        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "bigvictim-llm") }
        try await waitUntilRunning(e, "bigvictim-llm")

        _ = try await e.run(LLMRequest(prompt: "c"), package: "bigcontender-llm")
        let victim = try await victimCall.value
        #expect((victim as? LLMResponse)?.text == "bigvictim-after-requeue")
        // Exactly the preempted attempt's cancel-trim (2 GB transient ≥ the 1 GiB default).
        #expect(await e.policyTrimCount == 1)
    }

    // A package with a run in flight is never the idle-LRU victim, even when it is the
    // least-recently-used resident (the v1 hazard V3 closes).
    @Test func runningPackageIsProtectedFromIdleLRUEviction() async throws {
        SpinningVictim.probe.reset()
        let e = engine(budget: 120)
        try await e.register(PackageRegistration.of(SpinningVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(IdleTTS.self), configuration: cfg())
        try await e.register(PackageRegistration.of(IdleImage.self), configuration: cfg())

        // Victim loads FIRST (oldest lastUsed tick), then idle tts fills the budget.
        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "victim-llm") }
        try await waitUntilRunning(e, "victim-llm")
        try await e.prepare(.tts)

        // Admitting textToImage needs 60: naive LRU would evict the long-running victim;
        // the idle-victim filter must pick tts instead.
        try await e.prepare(.textToImage)
        let snap = await e.memory
        #expect(snap.residents[.tts] == nil)
        #expect(snap.residents[.textToImage] == 60)
        #expect(snap.residents[.llm] == 60)

        // The victim was untouched throughout — cancel it via the user lane to finish.
        victimCall.cancel()
        await #expect(throws: CancellationError.self) { _ = try await victimCall.value }
        #expect(SpinningVictim.probe.attempts == 1)
    }

    // prepare() never preempts: warming a model must not throw away in-flight work. With no
    // idle residents to reclaim it falls back to v1 load-anyway (the reactive R-MEM-1 trigger
    // covers real overflow).
    @Test func prepareNeverPreemptsARunningInference() async throws {
        SpinningVictim.probe.reset()
        let e = engine(budget: 60)
        try await e.register(PackageRegistration.of(SpinningVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(QuickContender.self), configuration: cfg())

        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "victim-llm") }
        try await waitUntilRunning(e, "victim-llm")

        try await e.prepare(.llm, package: "contender-llm")
        // The victim is still running (not preempted, not requeued) after prepare returns.
        #expect(await e.activeRunLatestReport(for: "victim-llm") != nil)
        #expect(SpinningVictim.probe.attempts == 1)
        #expect(!SpinningVictim.probe.cancelledMidRun)

        victimCall.cancel()
        await #expect(throws: CancellationError.self) { _ = try await victimCall.value }
    }

    // Disabling the policy restores v1 admission exactly: the contender's run() does not
    // preempt; with nothing idle it loads anyway and both runs complete genuinely.
    @Test func disabledPolicyNeverPreempts() async throws {
        NearlyDoneVictim.probe.reset()
        let e = engine(budget: 60, preemption: PreemptionPolicy(enabled: false))
        try await e.register(PackageRegistration.of(NearlyDoneVictim.self), configuration: cfg())
        try await e.register(PackageRegistration.of(QuickContender.self), configuration: cfg())

        let victimCall = Task { try await e.run(LLMRequest(prompt: "v"), package: "neardone-llm") }
        try await waitUntilRunning(e, "neardone-llm")

        let contender = try await e.run(LLMRequest(prompt: "c"), package: "contender-llm")
        #expect((contender as? LLMResponse)?.text == "contender")
        let victim = try await victimCall.value
        #expect((victim as? LLMResponse)?.text == "victim-finished-naturally")
        #expect(!NearlyDoneVictim.probe.cancelledMidRun)
        #expect(NearlyDoneVictim.probe.attempts == 1)
    }
}
