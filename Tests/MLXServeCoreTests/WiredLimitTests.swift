import Testing
import Foundation
import MLX
import MLXToolKit
@testable import MLXServeCore

// HV1 (NEUROSTREAM-ACTIONS): the engine's WiredMemoryManager ticket adoption.
//
// Determinism rules (the forDevice pattern): every engine here fabricates a DeviceProfile whose
// total ≠ this host's physical memory (decimal e9 values never equal a binary-power host total),
// so ceilings resolve by pure arithmetic — never the host's queried working set. Ticket flows are
// observed on an ISOLATED WiredMemoryManager (`makeForTesting`, DEBUG-only — mlx-swift declares
// multiple managers undefined, which scopes to the process-global backend writes; an isolated
// manager in a policy-only-or-tiny-sizes test is the sanctioned upstream test pattern) configured
// with `useRecommendedWorkingSetWhenUnsupported: false` so a no-Metal CI runner resolves the same
// baseline (0) as a Metal machine. Ticket sizes are symbolic bytes (60/30), so a real backend
// apply is trivially below any machine's working set and the event stream is identical either way.

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

@InferenceActor private final class WiredMockLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .llm, footprint: 60, transient: 30)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

/// Honors cooperative cancellation immediately — the cancel-path ticket-pairing probe.
@InferenceActor private final class WiredCancellingLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .llm, footprint: 60, transient: 30)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        throw CancellationError()
    }
}

/// Big symbolic footprints for the ceiling-clamp test (3 GB + 2 GB against a 4 GB ceiling).
@InferenceActor private final class WiredBigLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(capability: .llm, footprint: 3_000_000_000, transient: 2_000_000_000)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

/// Fabricated-profile engine (total 64e9 ≠ any host's binary-power RAM) with symbolic budgets.
private func engine(budget: UInt64, totalMemory: UInt64 = 64_000_000_000,
                    wired: WiredLimitConfiguration = WiredLimitConfiguration()) -> MLXServeEngine {
    let device = DeviceProfile(chipTier: .max,
                               macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                               backends: [.metalGPU],
                               totalMemoryBytes: totalMemory)
    return MLXServeEngine(device: device, governor: MemoryGovernor(budgetBytes: budget),
                          wiredLimit: wired, physFootprint: { nil })
}

/// An isolated manager whose baseline resolves to 0 on every machine (no host recommended-set
/// fallback on no-Metal runners).
private func isolatedManager() -> WiredMemoryManager {
    WiredMemoryManager.makeForTesting(
        configuration: WiredMemoryManagerConfiguration(useRecommendedWorkingSetWhenUnsupported: false))
}

/// Collects a manager's DEBUG event stream for polling assertions.
private actor EventLog {
    private(set) var events: [WiredMemoryEvent] = []
    func append(_ e: WiredMemoryEvent) { events.append(e) }
    func snapshot() -> [WiredMemoryEvent] { events }
}

private func subscribe(_ manager: WiredMemoryManager, into log: EventLog) async -> Task<Void, Never> {
    let stream = await manager.events()
    return Task { for await e in stream { await log.append(e) } }
}

/// Poll until `condition` holds over the log (events pump asynchronously) or ~2 s elapse.
private func eventually(_ log: EventLog,
                        _ condition: @Sendable ([WiredMemoryEvent]) -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition(await log.snapshot()) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition(await log.snapshot())
}

// MARK: - Ceiling arithmetic (pure)

@Test func osReserveScalesWithinTheSixToSixteenBracket() {
    let GiB: UInt64 = 1_073_741_824
    // Floor: small machines reserve 6 GiB (16 GB → ceiling ≈ 60% — the conservative end).
    #expect(WiredLimitConfiguration.osReserveBytes(totalMemoryBytes: 16_000_000_000) == 6 * GiB)
    // /8 arm between the clamps.
    #expect(WiredLimitConfiguration.osReserveBytes(totalMemoryBytes: 96_000_000_000)
            == 12_000_000_000)
    // Cap: huge machines never reserve more than 16 GiB.
    #expect(WiredLimitConfiguration.osReserveBytes(totalMemoryBytes: 200_000_000_000) == 16 * GiB)
    // Tiny totals reserve at most half (no underflow).
    #expect(WiredLimitConfiguration.osReserveBytes(totalMemoryBytes: 8_000_000_000)
            == 4_000_000_000)
}

@Test func resolvedCeilingArms() {
    let auto = WiredLimitConfiguration()
    // Fabricated profile (recommended nil): pure arithmetic — total − reserve.
    #expect(auto.resolvedCeilingBytes(totalMemoryBytes: 64_000_000_000, recommendedBytes: nil)
            == 56_000_000_000)
    // Host profile: the queried working set wins when it is the lower arm.
    #expect(auto.resolvedCeilingBytes(totalMemoryBytes: 64_000_000_000,
                                      recommendedBytes: 50_000_000_000) == 50_000_000_000)
    // Explicit ceilings are still clamped to a known working set (the allocator rejects above it).
    let explicit = WiredLimitConfiguration(coordination: .ceiling(bytes: 60_000_000_000))
    #expect(explicit.resolvedCeilingBytes(totalMemoryBytes: 64_000_000_000,
                                          recommendedBytes: 50_000_000_000) == 50_000_000_000)
    #expect(explicit.resolvedCeilingBytes(totalMemoryBytes: 64_000_000_000, recommendedBytes: nil)
            == 60_000_000_000)
    #expect(WiredLimitConfiguration.disabled
        .resolvedCeilingBytes(totalMemoryBytes: 64_000_000_000, recommendedBytes: nil) == nil)
}

@Test func fabricatedProfileCeilingIsPureArithmetic() {
    // The engine-resolved ceiling for a fabricated profile must be exactly total − reserve —
    // never the host's queried working set (the forDevice determinism rule). Nil is legitimate
    // only in a process that can't initialize MLX's Metal device (coordination off there).
    let e = engine(budget: 100)
    #expect(e.wiredLimitCeilingBytes == 56_000_000_000 || e.wiredLimitCeilingBytes == nil)
}

@Test func hostProfileCeilingNeverExceedsQueriedWorkingSet() {
    // The real-profile arm (QW3-style guarded): with Metal available, the ceiling honors BOTH
    // constraints — ≤ queried working set AND ≤ total − reserve(6–16 GiB).
    let profile = DeviceProfile.current()
    let e = MLXServeEngine(device: profile, governor: MemoryGovernor(budgetBytes: 1_000),
                           physFootprint: { nil })
    guard let ceiling = e.wiredLimitCeilingBytes else { return } // no Metal in this runner
    if let recommended = HostMemory.recommendedGPUWorkingSetBytes(), recommended > 0 {
        #expect(ceiling <= recommended)
    }
    let reserve = WiredLimitConfiguration.osReserveBytes(totalMemoryBytes: profile.totalMemoryBytes)
    #expect(ceiling <= profile.totalMemoryBytes - reserve)
}

// MARK: - Ticket lifecycle through the engine (isolated manager)

@Test func reservationParticipatesWithoutElevatingAndRunElevates() async throws {
    let e = engine(budget: 100)
    guard e.wiredLimitCeilingBytes != nil else { return } // no Metal in this runner
    let manager = isolatedManager()
    let log = EventLog()
    let pump = await subscribe(manager, into: log)
    defer { pump.cancel() }
    await e._useWiredManager(manager)

    try await e.register(PackageRegistration.of(WiredMockLLM.self), configuration: cfg())
    _ = try await e.prepare(.llm)

    // prepare(): a .reservation for the persistent 60 — and no elevated apply while idle.
    let sizes = await e.wiredReservationSizes()
    #expect(sizes.values.sorted() == [60])
    let sawReservation = await eventually(log) { events in
        events.contains { $0.kind == .ticketStarted && $0.size == 60 }
    }
    #expect(sawReservation)
    let idleApplies = await log.snapshot()
        .filter { $0.kind == .limitApplied }.compactMap(\.appliedLimit).filter { $0 > 0 }
    #expect(idleApplies.isEmpty, "reservation alone must not elevate the wired limit")

    // run(): the .active transient elevates to Σ(60 persistent + 30 transient) = 90.
    _ = try await e.run(LLMRequest(prompt: "hi"))
    let sawRunApply = await eventually(log) { events in
        events.contains { $0.kind == .limitApplied && $0.appliedLimit == 90 }
    }
    #expect(sawRunApply, "run must elevate the limit to persistent + transient")
    // …and the run's end restores the baseline (0) while the reservation stays live.
    let restored = await eventually(log) { events in
        guard let lastApply = events.last(where: { $0.kind == .limitApplied }) else { return false }
        return lastApply.appliedLimit == 0 && events.contains { $0.kind == .baselineRestored }
    }
    #expect(restored, "idle restore must be immediate after the last active ticket ends")
    #expect(await e.wiredReservationSizes().values.sorted() == [60])

    // evict(): the reservation ends and the manager drains.
    await e.evict(.llm)
    #expect(await e.wiredReservationSizes().isEmpty)
    let reservationEnded = await eventually(log) { events in
        events.contains { $0.kind == .ticketEnded && $0.size == 60 }
    }
    #expect(reservationEnded)
}

@Test func appliedLimitClampsToTheResolvedCeiling() async throws {
    // Fabricated 8e9 total → reserve 4e9 → ceiling 4e9. Persistent 3e9 + transient 2e9 sums to
    // 5e9; the applied limit must clamp at the 4e9 ceiling (the §3.2 safety property).
    let e = engine(budget: 6_000_000_000, totalMemory: 8_000_000_000)
    guard e.wiredLimitCeilingBytes != nil else { return } // no Metal in this runner
    #expect(e.wiredLimitCeilingBytes == 4_000_000_000)
    let manager = isolatedManager()
    let log = EventLog()
    let pump = await subscribe(manager, into: log)
    defer { pump.cancel() }
    await e._useWiredManager(manager)

    try await e.register(PackageRegistration.of(WiredBigLLM.self), configuration: cfg())
    _ = try await e.run(LLMRequest(prompt: "hi"))
    let clamped = await eventually(log) { events in
        events.contains { $0.kind == .limitApplied && $0.appliedLimit == 4_000_000_000 }
    }
    #expect(clamped, "the applied limit must clamp to the ceiling, not the 5e9 sum")
    let overCeiling = await log.snapshot()
        .filter { $0.kind == .limitApplied }
        .compactMap(\.appliedLimit).filter { $0 > 4_000_000_000 }
    #expect(overCeiling.isEmpty, "no apply may ever exceed the resolved ceiling")
}

@Test func cancelledRunStillEndsItsActiveTicket() async throws {
    let e = engine(budget: 100)
    guard e.wiredLimitCeilingBytes != nil else { return } // no Metal in this runner
    let manager = isolatedManager()
    let log = EventLog()
    let pump = await subscribe(manager, into: log)
    defer { pump.cancel() }
    await e._useWiredManager(manager)

    try await e.register(PackageRegistration.of(WiredCancellingLLM.self), configuration: cfg())
    await #expect(throws: CancellationError.self) {
        _ = try await e.run(LLMRequest(prompt: "hi"))
    }
    // The cooperative cancel takes the wrapper's catch path: active ticket ends, baseline
    // restores, and the reservation survives (cancel ≠ evict).
    let activeEnded = await eventually(log) { events in
        events.contains { $0.kind == .ticketEnded && $0.size == 30 }
            && events.last(where: { $0.kind == .limitApplied })?.appliedLimit == 0
    }
    #expect(activeEnded, "a thrown run must still end its .active ticket and restore baseline")
    #expect(await e.wiredReservationSizes().values.sorted() == [60])
}

@Test func disabledCoordinationMintsNoTickets() async throws {
    let e = engine(budget: 100, wired: .disabled)
    #expect(e.wiredLimitCeilingBytes == nil)
    let manager = isolatedManager()
    let log = EventLog()
    let pump = await subscribe(manager, into: log)
    defer { pump.cancel() }
    await e._useWiredManager(manager)

    try await e.register(PackageRegistration.of(WiredMockLLM.self), configuration: cfg())
    _ = try await e.run(LLMRequest(prompt: "hi"))
    await e.evict(.llm)
    #expect(await e.wiredReservationSizes().isEmpty)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await log.snapshot().isEmpty, ".disabled must never touch the manager")
}
