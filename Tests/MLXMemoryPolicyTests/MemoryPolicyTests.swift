import Foundation
import Testing
import MLXMemoryPolicy

/// Table tests of the pure admission ladder (1.58.0, AB-T-0357): one row per rung, then whole
/// plans, the accounting knobs a multi-process host uses, and the wire form. The engine-side
/// suites (RunPreemptionTests, ExternalTenantTests, RealPressureTenantTests, MLXGovernorTests)
/// prove MLXServeEngine executes these decisions unchanged.

private let GB: UInt64 = 1_000_000_000

private func tenant(_ id: String, _ persistentGB: UInt64, peak peakGB: UInt64 = 0,
                    measured: UInt64? = nil, lastUsed: UInt64 = 0,
                    evictable: Bool = true) -> MemoryTenant {
    MemoryTenant(id: id, persistentBytes: persistentGB * GB, peakTransientBytes: peakGB * GB,
                 measuredBytes: measured, lastUsed: lastUsed, evictable: evictable)
}

private func admit(_ id: String, _ persistentGB: UInt64, _ transientGB: UInt64) -> MemoryAdmission {
    MemoryAdmission(tenant: id, persistentBytes: persistentGB * GB, transientBytes: transientGB * GB)
}

/// One row: a state, an admission and a conduct, and the decision the ladder must give.
struct LadderCase: CustomTestStringConvertible, Sendable {
    let name: String
    let state: MemoryState
    let admission: MemoryAdmission
    let conduct: AdmissionConduct
    let expected: AdmissionDecision
    var testDescription: String { name }
}

private let policy = MemoryPolicy(budgetBytes: 40 * GB)

private let ladder: [LadderCase] = [
    LadderCase(
        name: "fits: Σ persistent + one max transient within budget",
        state: MemoryState(tenants: [tenant("a", 10, peak: 5)]),
        admission: admit("new", 10, 8), conduct: .preempting,
        expected: .fits),
    LadderCase(
        name: "rung 3: idle LRU — the least recently used goes first",
        state: MemoryState(tenants: [tenant("recent", 10, lastUsed: 9), tenant("old", 10, lastUsed: 1),
                                     tenant("middle", 10, lastUsed: 5)]),
        admission: admit("new", 12, 2), conduct: .idleOnly,
        expected: .step(.evict(tenant: "old"))),
    LadderCase(
        name: "rung 3: a tenant with a run is never idle",
        state: MemoryState(tenants: [tenant("busy", 15, lastUsed: 1), tenant("idle", 15, lastUsed: 9)],
                           runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 0)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.evict(tenant: "idle"))),
    LadderCase(
        name: "rung 3: a tenant with a live session is never idle",
        state: MemoryState(tenants: [tenant("live", 15, lastUsed: 1), tenant("idle", 15, lastUsed: 9)],
                           liveSessions: [MemoryLiveSession(token: "7", tenant: "live")]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.evict(tenant: "idle"))),
    LadderCase(
        name: "rung 3: a non-evictable tenant is skipped but still counted",
        state: MemoryState(tenants: [tenant("pinned", 15, lastUsed: 1, evictable: false),
                                     tenant("idle", 15, lastUsed: 9)]),
        admission: admit("new", 12, 2), conduct: .idleOnly,
        expected: .step(.evict(tenant: "idle"))),
    LadderCase(
        name: "rung 3: the admitted tenant never evicts itself",
        state: MemoryState(tenants: [tenant("self", 30, peak: 9, lastUsed: 0)]),
        admission: admit("self", 30, 12), conduct: .preempting,
        expected: .exhausted(shortByBytes: 2 * GB)),
    LadderCase(
        name: "idleOnly stops at the idle rung: short, nothing it may take",
        state: MemoryState(tenants: [tenant("busy", 30)],
                           runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 2 * GB)]),
        admission: admit("new", 12, 2), conduct: .idleOnly,
        expected: .exhausted(shortByBytes: 4 * GB)),
    LadderCase(
        name: "rung 4: preempting cancels a run below the nearly-done fraction",
        state: MemoryState(tenants: [tenant("busy", 30)],
                           runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 2 * GB,
                                            progress: 0.5)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.preempt(run: "1", tenant: "busy"))),
    LadderCase(
        name: "rung 4: a run at the nearly-done fraction is awaited, not cancelled",
        state: MemoryState(tenants: [tenant("busy", 30)],
                           runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 2 * GB,
                                            progress: 0.8)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.awaitRun(run: "1", tenant: "busy"))),
    LadderCase(
        name: "rung 4: a requeued attempt (.waiting) only ever waits",
        state: MemoryState(tenants: [tenant("busy", 30)],
                           runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 2 * GB)]),
        admission: admit("new", 12, 2), conduct: .waiting,
        expected: .step(.awaitRun(run: "1", tenant: "busy"))),
    LadderCase(
        name: "rung 4: lowest progress is reclaimed first",
        state: MemoryState(tenants: [tenant("far", 15), tenant("near", 15)],
                           runs: [MemoryRun(token: "1", tenant: "near", transientBytes: 0, progress: 0.6),
                                  MemoryRun(token: "2", tenant: "far", transientBytes: 0, progress: 0.1)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.preempt(run: "2", tenant: "far"))),
    LadderCase(
        name: "rung 4: a run on a non-evictable tenant is not a victim",
        state: MemoryState(tenants: [tenant("leaving", 30, evictable: false)],
                           runs: [MemoryRun(token: "1", tenant: "leaving", transientBytes: 0)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .exhausted(shortByBytes: 4 * GB)),
    LadderCase(
        name: "rung 5: runs go before live sessions",
        state: MemoryState(tenants: [tenant("batch", 15), tenant("mic", 15)],
                           runs: [MemoryRun(token: "1", tenant: "batch", transientBytes: 0)],
                           liveSessions: [MemoryLiveSession(token: "2", tenant: "mic", idleSeconds: 60)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.preempt(run: "1", tenant: "batch"))),
    LadderCase(
        name: "rung 5: the longest-idle live session is ended",
        state: MemoryState(tenants: [tenant("talking", 15), tenant("abandoned", 15)],
                           liveSessions: [MemoryLiveSession(token: "1", tenant: "talking", idleSeconds: 2),
                                          MemoryLiveSession(token: "2", tenant: "abandoned",
                                                            idleSeconds: 600)]),
        admission: admit("new", 12, 2), conduct: .preempting,
        expected: .step(.endLiveSession(session: "2", tenant: "abandoned"))),
    LadderCase(
        name: "rung 5: a requeued attempt cannot take a live session",
        state: MemoryState(tenants: [tenant("mic", 30)],
                           liveSessions: [MemoryLiveSession(token: "1", tenant: "mic")]),
        admission: admit("new", 12, 2), conduct: .waiting,
        expected: .exhausted(shortByBytes: 4 * GB)),
    LadderCase(
        name: "accounting: an in-flight run's per-run reserve outranks the idle peaks",
        state: MemoryState(tenants: [tenant("a", 10, peak: 2)],
                           runs: [MemoryRun(token: "1", tenant: "a", transientBytes: 20 * GB)]),
        admission: admit("new", 10, 2), conduct: .idleOnly,
        expected: .fits),   // 10 + 10 + max(2, 20, 2) = 40
    LadderCase(
        name: "accounting: external tenants' transients add on top of the one max",
        state: MemoryState(tenants: [tenant("a", 10, peak: 5, lastUsed: 1)],
                           externalTenants: [ExternalTenantDeclaration(
                               id: "compositor",
                               footprint: ExternalFootprint(persistentBytes: 2 * GB,
                                                            transientBytes: 1 * GB))]),
        admission: admit("new", 23, 5), conduct: .idleOnly,
        expected: .step(.evict(tenant: "a"))),   // 10 + 2 + 23 + max(5, 5) + 1 = 41
]

@Suite("MemoryPolicy ladder")
struct MemoryPolicyLadderTests {

    @Test("nextStep", arguments: ladder)
    func nextStep(_ row: LadderCase) {
        #expect(policy.nextStep(row.admission, in: row.state, conduct: row.conduct) == row.expected)
    }

    @Test("rung 1: a working set larger than the budget alone is refused")
    func ownPeak() {
        #expect(policy.ownPeakRefusal(persistentBytes: 30 * GB, transientBytes: 10 * GB) == nil)
        #expect(policy.ownPeakRefusal(persistentBytes: 30 * GB, transientBytes: 11 * GB)
                == .exceedsBudget(required: 41 * GB, budget: 40 * GB))
        #expect(policy.plan(admit("new", 30, 11), in: MemoryState(), conduct: .preempting).outcome
                == .refused(.exceedsBudget(required: 41 * GB, budget: 40 * GB)))
    }

    @Test("rung 2: external tenants are asked for the deficit, then refused if they still hold too much")
    func externalClaim() {
        let compositor = ExternalTenantDeclaration(
            id: "compositor", footprint: ExternalFootprint(persistentBytes: 15 * GB, transientBytes: 0))
        let state = MemoryState(tenants: [tenant("a", 10, lastUsed: 1)], externalTenants: [compositor])
        // 10 + 15 + 20 + 5 = 50: ask for the 10 over.
        #expect(policy.externalTenantDeficit(admit("new", 20, 5), in: state) == 10 * GB)
        #expect(policy.externalRefusal(admit("new", 20, 5), in: state) == nil)
        // 25 + 15 = 40 still fits beside the compositor with every package gone; 26 does not.
        #expect(policy.externalRefusal(admit("new", 21, 5), in: state)
                == .externalTenantsHoldMemory(required: 26 * GB, external: 15 * GB, budget: 40 * GB))
        let refused = policy.plan(admit("new", 21, 5), in: state, conduct: .preempting)
        #expect(refused.externalTenantRequestBytes == 11 * GB)
        #expect(refused.steps.isEmpty)
        #expect(refused.verdict == .refuse(.externalTenantsHoldMemory(required: 26 * GB,
                                                                       external: 15 * GB,
                                                                       budget: 40 * GB)))
        // No tenants: nothing to ask, nothing external refuses.
        #expect(policy.plan(admit("new", 20, 5), in: MemoryState(tenants: [tenant("a", 10)]),
                            conduct: .idleOnly).externalTenantRequestBytes == 0)
    }

    @Test("rung 6: R-MEM-1 evicts idle LRU while the credited reading is over the ceiling")
    func realPressure() {
        let state = MemoryState(tenants: [tenant("new", 5), tenant("old", 5, lastUsed: 1),
                                          tenant("busy", 5, lastUsed: 0)],
                                runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 0)])
        let ceiling = policy.realPressureCeiling   // 40 GB × 0.85, in Double
        #expect(ceiling == UInt64(Double(40 * GB) * 0.85))
        #expect(policy.nextRealPressureStep(admitting: "new", reading: ceiling, in: state) == .fits)
        #expect(policy.nextRealPressureStep(admitting: "new", reading: 36 * GB, in: state)
                == .step(.evict(tenant: "old")))
        var drained = state
        drained.tenants.removeAll { $0.id == "old" }
        #expect(policy.nextRealPressureStep(admitting: "new", reading: 36 * GB, in: drained)
                == .exhausted(shortByBytes: 36 * GB - ceiling))
        // The tenants' declared drop is credited: a lagging 36 GB reading after a 3 GB release fits.
        #expect(MemoryPolicy.credited(36 * GB, released: 3 * GB) == 33 * GB)
        #expect(MemoryPolicy.credited(2 * GB, released: 3 * GB) == 0)
    }

    @Test("external tenants are asked largest declaration first")
    func shrinkOrder() {
        let tenants = [("small", 1), ("large", 9), ("middle", 4)].map {
            ExternalTenantDeclaration(id: $0.0, footprint: ExternalFootprint(persistentBytes: UInt64($0.1)))
        }
        #expect(MemoryPolicy.shrinkOrder(tenants, footprint: \.footprint).map(\.id)
                == ["large", "middle", "small"])
    }
}

@Suite("MemoryPolicy plans")
struct MemoryPolicyPlanTests {

    @Test("idle evictions in LRU order until it fits")
    func evictPlan() {
        let state = MemoryState(tenants: [tenant("c", 10, lastUsed: 3), tenant("a", 10, lastUsed: 1),
                                          tenant("b", 10, lastUsed: 2)])
        let plan = policy.plan(admit("new", 19, 2), in: state, conduct: .preempting)
        #expect(plan.steps == [.evict(tenant: "a"), .evict(tenant: "b")])
        #expect(plan.outcome == .fits)
        #expect(plan.verdict == .evict(["a", "b"]))
    }

    @Test("idle first, then the running tenant, then fits")
    func preemptPlan() {
        let state = MemoryState(tenants: [tenant("idle", 10, lastUsed: 1), tenant("busy", 20, lastUsed: 2)],
                                runs: [MemoryRun(token: "42", tenant: "busy", transientBytes: 4 * GB,
                                                 progress: 0.3)])
        let plan = policy.plan(admit("new", 20, 4), in: state, conduct: .preempting)
        #expect(plan.steps == [.evict(tenant: "idle"), .preempt(run: "42", tenant: "busy")])
        #expect(plan.verdict == .preempt(runs: ["42"], evicting: ["idle", "busy"]))
        #expect(plan.outcome == .fits)
    }

    @Test("nothing fits and nothing may be taken: overcommitted, with what it did take")
    func overcommittedPlan() {
        let state = MemoryState(tenants: [tenant("idle", 5, lastUsed: 1), tenant("busy", 25)],
                                runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 0)])
        let plan = policy.plan(admit("new", 15, 5), in: state, conduct: .idleOnly)
        #expect(plan.steps == [.evict(tenant: "idle")])
        #expect(plan.outcome == .overcommitted(shortByBytes: 5 * GB))
        #expect(plan.verdict == .evict(["idle"]))
    }

    @Test("an already-fitting admission plans nothing")
    func fitsPlan() {
        let plan = policy.plan(admit("new", 5, 1), in: MemoryState(tenants: [tenant("a", 10)]),
                               conduct: .preempting)
        #expect(plan == AdmissionPlan(outcome: .fits))
        #expect(plan.verdict == .fits)
    }

    @Test("a measured reading over the ceiling projects R-MEM-1's further evictions")
    func realPressurePlan() {
        let state = MemoryState(tenants: [tenant("a", 5, measured: 9 * GB, lastUsed: 1),
                                          tenant("b", 5, measured: 9 * GB, lastUsed: 2),
                                          tenant("c", 5, lastUsed: 3)])
        // Declared: 15 + 5 = 20 fits. Measured 40 GB > 34: evict a (−9 → 31), done.
        let plan = policy.plan(admit("new", 5, 0), in: state, conduct: .preempting,
                               measuredReading: 40 * GB)
        #expect(plan.steps.isEmpty)
        #expect(plan.realPressureEvictions == ["a"])
        #expect(plan.evictions == ["a"])
    }
}

@Suite("MemoryPolicy across processes")
struct MemoryPolicyHostTests {

    /// AB-T-0363's finding in Gaea: an idle Z-Image worker (11.9 GB declared, 28 GB peak, 17.3 GB
    /// measured) was charged its peak and evicted for a 2.37 GB job. Under the engine's in-process
    /// accounting its peak stays in the reserve; under the host accounting only the admitted job
    /// reserves a transient, and the idle worker is charged what it measures.
    @Test("an idle worker is charged its bytes, not its peak")
    func idleWorkerCharge() {
        let zImage = MemoryTenant(id: "z-image", persistentBytes: 11_900_000_000,
                                  peakTransientBytes: 28_000_000_000, measuredBytes: 17_300_000_000,
                                  lastUsed: 1)
        let state = MemoryState(tenants: [zImage])
        let job = MemoryAdmission(tenant: "demo", persistentBytes: 1_200_000_000,
                                  transientBytes: 1_170_000_000)
        let inProcess = MemoryPolicy(budgetBytes: 30 * GB)
        #expect(inProcess.required(job, in: state) == 41_100_000_000)
        #expect(inProcess.nextStep(job, in: state, conduct: .idleOnly) == .step(.evict(tenant: "z-image")))

        let host = MemoryPolicy(budgetBytes: 30 * GB, transientAccounting: .admittedRunsOnly,
                                idleCharge: .largerOfDeclaredAndMeasured)
        #expect(host.charge(zImage, in: state) == 17_300_000_000)
        #expect(host.required(job, in: state) == 19_670_000_000)
        #expect(host.nextStep(job, in: state, conduct: .idleOnly) == .fits)
        #expect(host.plan(job, in: state, conduct: .preempting) == AdmissionPlan(outcome: .fits))
    }

    @Test("a busy worker is charged its declared bytes; its run carries the transient")
    func busyWorkerCharge() {
        let worker = MemoryTenant(id: "w", persistentBytes: 10 * GB, peakTransientBytes: 20 * GB,
                                  measuredBytes: 25 * GB)
        let state = MemoryState(tenants: [worker],
                                runs: [MemoryRun(token: "job-1", tenant: "w", transientBytes: 12 * GB)])
        let host = MemoryPolicy(budgetBytes: 64 * GB, transientAccounting: .admittedRunsOnly,
                                idleCharge: .largerOfDeclaredAndMeasured)
        #expect(host.charge(worker, in: state) == 10 * GB)
        #expect(host.availableBytes(state) == 42 * GB)
    }

    @Test("what would be free after evicting every idle worker, without committing")
    func headroomAfterIdle() {
        let host = MemoryPolicy(budgetBytes: 64 * GB, transientAccounting: .admittedRunsOnly)
        let state = MemoryState(tenants: [tenant("idle-1", 20, peak: 10, lastUsed: 1),
                                          tenant("idle-2", 10, lastUsed: 2),
                                          tenant("busy", 8),
                                          tenant("keep", 6, lastUsed: 0)],
                                runs: [MemoryRun(token: "1", tenant: "busy", transientBytes: 4 * GB)])
        #expect(host.availableBytes(state) == 16 * GB)                                // 64 − 44 − 4
        #expect(host.availableBytes(state, afterEvictingIdleExcept: "keep") == 46 * GB) // 64 − 14 − 4
        #expect(host.availableBytes(state, afterEvictingIdleExcept: nil) == 52 * GB)    // 64 − 8 − 4
        #expect(host.idleTenants(state, excluding: "keep") == ["idle-1", "idle-2"])
    }

    @Test("ties break by the order the host lists tenants and runs")
    func deterministicTies() {
        let state = MemoryState(tenants: [tenant("first", 10), tenant("second", 10)],
                                runs: [])
        #expect(policy.idleVictim(state) == "first")
        let busy = MemoryState(tenants: [tenant("x", 10), tenant("y", 10)],
                               runs: [MemoryRun(token: "b", tenant: "y", transientBytes: 0),
                                      MemoryRun(token: "a", tenant: "x", transientBytes: 0)])
        #expect(policy.runVictim(busy)?.token == "b")
    }

    @Test("state and plan round-trip through JSON")
    func codable() throws {
        let state = MemoryState(
            tenants: [tenant("a", 10, peak: 2, measured: 11 * GB, lastUsed: 3)],
            runs: [MemoryRun(token: "1", tenant: "a", transientBytes: 2 * GB, progress: 0.25)],
            liveSessions: [MemoryLiveSession(token: "2", tenant: "a", idleSeconds: 1.5)],
            externalTenants: [ExternalTenantDeclaration(
                id: "ui", footprint: ExternalFootprint(persistentBytes: 1, transientBytes: 2))])
        let plan = AdmissionPlan(externalTenantRequestBytes: 3,
                                 steps: [.evict(tenant: "a"), .awaitRun(run: "1", tenant: "a"),
                                         .endLiveSession(session: "2", tenant: "a")],
                                 outcome: .refused(.exceedsBudget(required: 5, budget: 4)),
                                 realPressureEvictions: ["b"])
        let coder = (JSONEncoder(), JSONDecoder())
        #expect(try coder.1.decode(MemoryState.self, from: coder.0.encode(state)) == state)
        #expect(try coder.1.decode(AdmissionPlan.self, from: coder.0.encode(plan)) == plan)
    }
}
