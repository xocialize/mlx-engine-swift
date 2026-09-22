//
//  ExternalTenantTests.swift
//  MLXServeCoreTests
//
//  Contract 1.43.0 — external GPU tenants (AB-R-0289 / AB-R-0292). A non-package tenant (the
//  Forge Canvas compositor) declares persistent + transient bytes; the engine counts them in
//  residency / the reserve / admissibility / the snapshot, asks the tenant to shrink before it
//  refuses or evicts, and never hangs on a handler that does not answer. Offline, mock packages,
//  no MLX, no GPU.
//
//  Budget 1 000 B throughout so every deficit is exact arithmetic.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private let budget: UInt64 = 1_000

private func engine(shrinkTimeout: Duration = .seconds(2)) -> MLXServeEngine {
    // physFootprint pinned to 0: the host's real footprint dwarfs a 1 000 B budget and would
    // drive the R-MEM-1 pass, which is not what these tests measure.
    MLXServeEngine(governor: MemoryGovernor(budgetBytes: budget),
                   externalTenants: ExternalTenantPolicy(shrinkTimeout: shrinkTimeout),
                   physFootprint: { 0 })
}

private func requirements(persistent: UInt64, transient: UInt64) -> RequirementsManifest {
    RequirementsManifest(
        footprints: [QuantFootprint(quant: .int4, residentBytes: persistent,
                                    peakActivationBytes: transient)],
        requiredBackends: [.metalGPU])
}

private func mockManifest(name: String, persistent: UInt64, transient: UInt64) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: requirements(persistent: persistent, transient: transient),
        surfaces: [ToolDescriptor(name: name, capability: .llm, summary: "mock")])
}

/// 600 persistent + 400 transient: exactly the whole budget.
@InferenceActor private final class WholeBudgetLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "whole-llm", persistent: 600, transient: 400)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "whole", finishReason: .stop)
    }
}

/// 500 persistent + 200 transient.
@InferenceActor private final class MidLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "mid-llm", persistent: 500, transient: 200)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mid", finishReason: .stop)
    }
}

/// 300 persistent + 0 transient — the idle co-resident the ladder may evict.
@InferenceActor private final class SmallLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "small-llm", persistent: 300, transient: 0)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "small", finishReason: .stop)
    }
}

/// A run that stays in flight until the test opens its gate.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    private var _started = false
    func open() { lock.withLock { _open = true } }
    func markStarted() { lock.withLock { _started = true } }
    var isOpen: Bool { lock.withLock { _open } }
    var started: Bool { lock.withLock { _started } }
}

@InferenceActor private final class GatedLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static let gate = Gate()
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "gated-llm", persistent: 100, transient: 100)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        Self.gate.markStarted()
        while !Self.gate.isOpen { try await Task.sleep(for: .milliseconds(1)) }
        return LLMResponse(text: "gated", finishReason: .stop)
    }
}

/// Counts shrink calls and the bytes asked for.
private final class ShrinkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [UInt64] = []
    func note(_ bytes: UInt64) { lock.withLock { _requests.append(bytes) } }
    var requests: [UInt64] { lock.withLock { _requests } }
}

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

private func llm() -> LLMRequest { LLMRequest(prompt: "hi") }

private func externalRefusal(_ error: any Error)
    -> (required: UInt64, external: UInt64, budget: UInt64)?
{
    guard case .externalTenantsHoldMemory(let required, let external, let budget)
            = error as? EngineError else { return nil }
    return (required, external, budget)
}

// MARK: - Declaration

// Acceptance 1 + 2: N declared persistent bytes lower `availableBytes` by N and flip an
// admissibility verdict that fit exactly; withdrawing restores both.
@Test func declaredPersistentBytesLowerAvailableAndFlipAnExactFit() async {
    let engine = engine()
    let exact = requirements(persistent: 600, transient: 400)
    #expect(await engine.memory.availableBytes == budget)
    #expect(await engine.admissibility(for: exact).fitsAvailable)

    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 1)
    let memory = await engine.memory
    #expect(memory.availableBytes == budget - 1)
    #expect(memory.externalBytes == 1)
    #expect(memory.residentBytes == 0)              // the packages' field stays the packages'
    #expect(memory.externalTenants == ["canvas": ExternalFootprint(persistentBytes: 1)])
    let flipped = await engine.admissibility(for: exact)
    #expect(!flipped.fitsAvailable)
    #expect(flipped.fitsBudget)                     // the machine can still run it

    tenant.withdraw()
    #expect(await engine.memory.availableBytes == budget)
    #expect(await engine.memory.externalTenants.isEmpty)
    #expect(await engine.admissibility(for: exact).fitsAvailable)
}

@Test func updatesTakeEffectAtTheNextAccountingStep() async {
    let engine = engine()
    let tenant = await engine.registerExternalTenant(id: "canvas")
    #expect(await engine.memory.availableBytes == budget)
    tenant.update(persistentBytes: 250, transientBytes: 50)
    #expect(await engine.memory.availableBytes == 700)
    tenant.update(persistentBytes: 100, transientBytes: 0)
    #expect(await engine.memory.availableBytes == 900)
    #expect(tenant.footprint == ExternalFootprint(persistentBytes: 100))
}

@Test func droppingTheHandleWithdrawsTheTenant() async {
    let engine = engine()
    do {
        let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 400)
        #expect(await engine.memory.availableBytes == 600)
        _ = tenant
    }
    #expect(await engine.memory.availableBytes == budget)
    #expect(await engine.memory.externalBytes == 0)
}

@Test func reRegisteringAnIDReplacesTheEarlierTenant() async {
    let engine = engine()
    let first = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300)
    let second = await engine.registerExternalTenant(id: "canvas", persistentBytes: 100)
    #expect(first.isWithdrawn)
    #expect(!second.isWithdrawn)
    #expect(await engine.memory.externalBytes == 100)
    first.update(persistentBytes: 900, transientBytes: 0)     // a no-op once withdrawn
    #expect(await engine.memory.externalBytes == 100)
}

// The canvas's render is not on @InferenceActor, so its transient overlaps a model's peak:
// it is ADDED to the packages' one serialized reserve, never folded into the max.
@Test func tenantTransientAddsToThePackageReserveRatherThanCompeting() async throws {
    let engine = engine()
    try await engine.register(PackageRegistration.of(MidLLM.self),
                              configuration: cfg())
    try await engine.prepare(.llm)                                 // 500 + reserve 200
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 0,
                                                     transientBytes: 100)
    let memory = await engine.memory
    #expect(memory.transientReserveBytes == 200)                   // packages' own max
    #expect(memory.externalBytes == 100)
    #expect(memory.availableBytes == budget - 500 - 200 - 100)     // not budget − 500 − max(200,100)

    // And admissibility sees the sum: a 100 + 100 candidate fits the 200 left only if its
    // transient competes with the 200 package max — it does — plus the tenant's 100 on top.
    let candidate = requirements(persistent: 100, transient: 100)
    #expect(await engine.admissibility(for: candidate).fitsAvailable)   // 500+100+200+100 = 900
    let bigger = requirements(persistent: 201, transient: 100)
    #expect(!(await engine.admissibility(for: bigger).fitsAvailable))   // 1 001
    #expect(!tenant.isWithdrawn)   // held to here: dropping the handle withdraws the tenant
}

// MARK: - Shrink requests

// Acceptance 3: the handler is invoked before a refusal, and admission succeeds when it
// releases enough.
@Test func aShrinkThatReleasesEnoughAdmits() async throws {
    let engine = engine()
    let log = ShrinkLog()
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 500)
    tenant.setShrinkHandler { [weak tenant] requested in
        log.note(requested)
        tenant?.update(persistentBytes: 0, transientBytes: 0)      // trim(): drop the cache
        return 500
    }
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self),
                              configuration: cfg())
    try await engine.prepare(.llm)
    #expect(log.requests == [500])                                 // exactly the deficit
    #expect(await engine.residentPackages["whole-llm"] == 600)
    #expect(await engine.memory.externalBytes == 0)
}

// Tenants are asked BEFORE any package is evicted: their memory rebuilds in milliseconds,
// a model's weights in seconds to minutes.
@Test func tenantsAreAskedBeforeAnIdlePackageIsEvicted() async throws {
    let engine = engine()
    try await engine.register(PackageRegistration.of(SmallLLM.self),
                              configuration: cfg(), id: "small")
    try await engine.register(PackageRegistration.of(MidLLM.self),
                              configuration: cfg(), id: "mid")
    try await engine.prepare(.llm, package: "small")               // 300 idle
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300)
    tenant.setShrinkHandler { [weak tenant] _ in
        tenant?.update(persistentBytes: 0, transientBytes: 0)
        return 300
    }
    // 300 small + 300 canvas + 500 + 200 = 1 300 → deficit 300, which the canvas covers.
    try await engine.prepare(.llm, package: "mid")
    let residents = await engine.residentPackages
    #expect(residents["small"] == 300)                             // NOT evicted
    #expect(residents["mid"] == 500)
}

// A partial release: the tenant is asked first, then the ladder evicts what remains.
@Test func aPartialShrinkIsFollowedByTheEvictionLadder() async throws {
    let engine = engine()
    let log = ShrinkLog()
    try await engine.register(PackageRegistration.of(SmallLLM.self),
                              configuration: cfg(), id: "small")
    try await engine.register(PackageRegistration.of(MidLLM.self),
                              configuration: cfg(), id: "mid")
    try await engine.prepare(.llm, package: "small")
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300)
    tenant.setShrinkHandler { [weak tenant] requested in
        log.note(requested)
        tenant?.update(persistentBytes: 200, transientBytes: 0)    // releases only 100
        return 100
    }
    try await engine.prepare(.llm, package: "mid")
    #expect(log.requests == [300])
    let residents = await engine.residentPackages
    #expect(residents["small"] == nil)                             // evicted for the rest
    #expect(residents["mid"] == 500)
    #expect(await engine.memory.availableBytes == budget - 500 - 200 - 200)
}

// Acceptance 4: a handler that releases nothing yields the refusal, promptly, having been
// asked exactly once — and nothing was evicted to get there.
@Test func aShrinkThatReleasesNothingRefusesWithoutLoopingOrEvicting() async throws {
    let engine = engine()
    let log = ShrinkLog()
    try await engine.register(PackageRegistration.of(SmallLLM.self),
                              configuration: cfg(), id: "small")
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self),
                              configuration: cfg(), id: "whole")
    try await engine.prepare(.llm, package: "small")
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 1) {
        requested in
        log.note(requested)
        return 0
    }
    do {
        try await engine.prepare(.llm, package: "whole")
        Issue.record("expected externalTenantsHoldMemory")
    } catch {
        let refusal = try #require(externalRefusal(error))
        #expect(refusal.required == 1_000)
        #expect(refusal.external == 1)
        #expect(refusal.budget == budget)
    }
    #expect(log.requests.count == 1)
    let residents = await engine.residentPackages
    #expect(residents["small"] == 300)                             // refused BEFORE evicting
    #expect(residents["whole"] == nil)
    #expect(!tenant.isWithdrawn)
}

@Test func aTenantWithNoHandlerRefusesTheSameWay() async throws {
    let engine = engine()
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self),
                              configuration: cfg())
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 0,
                                                     transientBytes: 10)
    await #expect(throws: EngineError.externalTenantsHoldMemory(required: 1_000, external: 10,
                                                                budget: budget)) {
        try await engine.prepare(.llm)
    }
    tenant.withdraw()
    try await engine.prepare(.llm)                                 // and admits once it's gone
}

// A handler that never answers is bounded by the policy timeout, then counted as-declared.
@Test func anUnresponsiveHandlerIsBoundedByTheTimeout() async throws {
    let engine = engine(shrinkTimeout: .milliseconds(50))
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self),
                              configuration: cfg())
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 100) { _ in
        // Ignores cancellation on purpose (a plain dispatch timer, not Task.sleep): the engine
        // must stop waiting at its deadline, not when the handler gets around to returning.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { done.resume() }
        }
        return 0
    }
    let start = ContinuousClock.now
    do {
        try await engine.prepare(.llm)
        Issue.record("expected externalTenantsHoldMemory")
    } catch {
        #expect(externalRefusal(error) != nil)
    }
    #expect(ContinuousClock.now - start < .seconds(5))
    _ = tenant
}

// A tenant that grew AFTER a package was admitted: the package's next run is an admission too,
// so it asks the tenant rather than running on an over-committed budget — and refuses when the
// tenant keeps what it holds.
@Test func aResidentRunAsksATenantThatGrewSinceAdmission() async throws {
    let engine = engine()
    let log = ShrinkLog()
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self),
                              configuration: cfg())
    try await engine.prepare(.llm)                                 // 600 + 400 = the budget
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 200)
    tenant.setShrinkHandler { [weak tenant] requested in
        log.note(requested)
        tenant?.update(persistentBytes: 0, transientBytes: 0)
        return requested
    }
    let response = try await engine.run(llm())
    #expect((response as? LLMResponse)?.text == "whole")
    #expect(log.requests == [200])

    tenant.update(persistentBytes: 50, transientBytes: 0)
    tenant.setShrinkHandler { _ in 0 }
    do {
        _ = try await engine.run(llm())
        Issue.record("expected externalTenantsHoldMemory")
    } catch {
        #expect(externalRefusal(error)?.external == 50)
    }
    #expect(await engine.residentPackages["whole-llm"] == 600)    // refused, not evicted
}

// No tenant registered → no shrink step, no new refusal: the pre-1.43 path exactly.
@Test func withoutTenantsAdmissionIsUnchanged() async throws {
    let engine = engine()
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self),
                              configuration: cfg())
    try await engine.prepare(.llm)
    let memory = await engine.memory
    #expect(memory.availableBytes == 0)
    #expect(memory.externalBytes == 0)
    #expect(memory.externalTenants.isEmpty)
}

// MARK: - Concurrency

// Acceptance 5: concurrent `update` calls — from many tasks, while a run is in flight and other
// tasks read the snapshot — are safe, and the engine reads the last declaration.
@Test func concurrentUpdatesDuringAnInFlightRunAreSafe() async throws {
    let engine = engine()
    try await engine.register(PackageRegistration.of(GatedLLM.self),
                              configuration: cfg())
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 0)
    let run = Task { try await engine.run(llm()) }
    while !GatedLLM.gate.started { try await Task.sleep(for: .milliseconds(1)) }

    await withTaskGroup(of: Void.self) { group in
        for i in 0..<200 {
            group.addTask {
                tenant.update(persistentBytes: UInt64(i % 50), transientBytes: UInt64(i % 7))
                let memory = await engine.memory
                // Whatever interleaving: one snapshot is one consistent accounting step —
                // the gated package's 100 + 100 plus whatever the tenants declared then.
                #expect(memory.availableBytes + memory.externalBytes == budget - 100 - 100)
            }
            group.addTask {
                let other = await engine.registerExternalTenant(id: "scratch-\(i)",
                                                                persistentBytes: 1)
                other.update(persistentBytes: 2, transientBytes: 0)
                other.withdraw()
            }
        }
    }
    tenant.update(persistentBytes: 40, transientBytes: 10)
    GatedLLM.gate.open()
    let response = try await run.value
    #expect((response as? LLMResponse)?.text == "gated")
    let memory = await engine.memory
    #expect(memory.externalTenants == ["canvas": ExternalFootprint(persistentBytes: 40,
                                                                   transientBytes: 10)])
    #expect(memory.availableBytes == budget - 100 - 100 - 50)
}
