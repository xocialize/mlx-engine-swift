import MLXToolKit

// MLXMemoryPolicy — the governor's admission and eviction rules as pure functions (contract 1.58.0,
// AB-T-0357, AB-A-0206 item 6, AB-D-0170).
//
// The rules MLXServeEngine applies in-process, with no MLX, no actor and no clock: value-typed
// tenants, runs and sessions in, a decision or a whole plan out. The engine builds a `MemoryState`
// from its own bookkeeping at every step of an admission and executes what the policy decides; a
// host that runs each model in a process of its own (Gaea) builds the same state from its workers
// and gets the same answers. One rule, two executors.
//
// The ladder, cheapest lever first:
// 1. Refuse a working set that cannot fit the budget even alone (`ownPeakRefusal`).
// 2. Ask external tenants for the deficit, then refuse when what they still hold leaves no room
//    even with every tenant evicted (`externalTenantDeficit`, `externalRefusal`).
// 3. Evict idle tenants, least recently used first (`idleVictim`).
// 4. Reclaim a running tenant, lowest progress first: cancel it (`.preempting`, unless it reads
//    nearly done) or wait for it (`.waiting`), then evict it (`runVictim`).
// 5. End a live session, longest idle first, on a first attempt only (`liveSessionVictim`).
// 6. R-MEM-1: while the measured footprint, credited by what tenants dropped, is over
//    `budget × highWatermark`, evict idle tenants (`nextRealPressureStep`).
//
// The accounting under all of it is the serialized-inference rule: Σ persistent + ONE transient
// reserve (only one model computes at a time) + every external tenant's declaration.

/// One holder of memory the policy may evict: a package resident in the engine, or a worker
/// process in a multi-process host. Ids are opaque.
public struct MemoryTenant: Sendable, Equatable, Hashable, Codable {
    /// Opaque, unique within a `MemoryState`. The engine uses the `PackageID`'s raw value.
    public var id: String
    /// What the tenant holds between uses (its weights), declared.
    public var persistentBytes: UInt64
    /// The largest activation peak of what the tenant holds — the reserve one of its runs needs.
    public var peakTransientBytes: UInt64
    /// The tenant's measured footprint (a worker's `phys_footprint`), when the host reads one.
    /// Used only under `IdleCharge.largerOfDeclaredAndMeasured`, and by `plan`'s real-pressure
    /// projection.
    public var measuredBytes: UInt64?
    /// A monotonic last-use tick; lower = less recently used.
    public var lastUsed: UInt64
    /// `false` keeps the tenant off every victim list (the engine: a package mid-unload; a host:
    /// a worker it is still launching). Its bytes still count.
    public var evictable: Bool

    public init(id: String, persistentBytes: UInt64, peakTransientBytes: UInt64 = 0,
                measuredBytes: UInt64? = nil, lastUsed: UInt64 = 0, evictable: Bool = true) {
        self.id = id
        self.persistentBytes = persistentBytes
        self.peakTransientBytes = peakTransientBytes
        self.measuredBytes = measuredBytes
        self.lastUsed = lastUsed
        self.evictable = evictable
    }
}

/// One run in flight on a tenant. A tenant with a run is busy: never an idle victim, reclaimable
/// only through the run.
public struct MemoryRun: Sendable, Equatable, Hashable, Codable {
    /// Opaque, unique within a `MemoryState`; what `.preempt` / `.awaitRun` name.
    public var token: String
    /// The tenant the run computes on.
    public var tenant: String
    /// The transient this run was admitted against (its per-run reserve).
    public var transientBytes: UInt64
    /// `step / totalSteps` of its latest progress report, `0` when unknown.
    public var progress: Double

    public init(token: String, tenant: String, transientBytes: UInt64, progress: Double = 0) {
        self.token = token
        self.tenant = tenant
        self.transientBytes = transientBytes
        self.progress = progress
    }
}

/// One open live session holding a tenant (contract 1.39.0). Ranks below runs as a victim: a
/// preempted run requeues, a preempted session loses audio nobody can replay.
public struct MemoryLiveSession: Sendable, Equatable, Hashable, Codable {
    public var token: String
    public var tenant: String
    /// The reserve the session holds for its lifetime (0 for an open-ended one).
    public var reservedTransientBytes: UInt64
    /// Seconds since the session was last fed; the longest idle is the first victim.
    public var idleSeconds: Double

    public init(token: String, tenant: String, reservedTransientBytes: UInt64 = 0,
                idleSeconds: Double = 0) {
        self.token = token
        self.tenant = tenant
        self.reservedTransientBytes = reservedTransientBytes
        self.idleSeconds = idleSeconds
    }
}

/// One external tenant's declaration (contract 1.43.0): memory the policy cannot evict, only ask
/// for back.
public struct ExternalTenantDeclaration: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var footprint: ExternalFootprint

    public init(id: String, footprint: ExternalFootprint) {
        self.id = id
        self.footprint = footprint
    }
}

/// Everything the policy reads: who holds what, what runs, what is external.
public struct MemoryState: Sendable, Equatable, Codable {
    public var tenants: [MemoryTenant]
    public var runs: [MemoryRun]
    public var liveSessions: [MemoryLiveSession]
    public var externalTenants: [ExternalTenantDeclaration]

    public init(tenants: [MemoryTenant] = [], runs: [MemoryRun] = [],
                liveSessions: [MemoryLiveSession] = [],
                externalTenants: [ExternalTenantDeclaration] = []) {
        self.tenants = tenants
        self.runs = runs
        self.liveSessions = liveSessions
        self.externalTenants = externalTenants
    }

    /// Σ every external tenant's declaration.
    public var external: ExternalFootprint {
        externalTenants.reduce(into: ExternalFootprint.zero) { sum, tenant in
            sum.persistentBytes &+= tenant.footprint.persistentBytes
            sum.transientBytes &+= tenant.footprint.transientBytes
        }
    }

    /// Whether a run or a live session holds `tenant`.
    public func isBusy(_ tenant: String) -> Bool {
        runs.contains { $0.tenant == tenant } || liveSessions.contains { $0.tenant == tenant }
    }
}

/// What is being admitted: a tenant's working set, or one run on a tenant already resident (its
/// persistent bytes are then the ones already charged, and the tenant is excluded from its own
/// accounting).
public struct MemoryAdmission: Sendable, Equatable, Hashable, Codable {
    public var tenant: String
    public var persistentBytes: UInt64
    /// The transient this admission reserves (a run's per-run reserve, or the tenant's peak).
    public var transientBytes: UInt64

    public init(tenant: String, persistentBytes: UInt64, transientBytes: UInt64) {
        self.tenant = tenant
        self.persistentBytes = persistentBytes
        self.transientBytes = transientBytes
    }
}

/// How an admission may claim headroom beyond idle eviction (run-lifecycle V3).
public enum AdmissionConduct: String, Sendable, Equatable, Hashable, Codable {
    /// Evict idle tenants only; never touch a running inference (the engine's `prepare`, and every
    /// admission when `PreemptionPolicy.enabled == false`).
    case idleOnly
    /// May preempt a running victim as a last resort (a request's first attempt).
    case preempting
    /// May wait for a running victim to finish and then evict it, never cancel it (a requeued
    /// attempt — structurally prevents two requests preempting each other in a loop).
    case waiting
}

/// One thing to do to make room. Executed in order; each ends with the named tenant's bytes free
/// (`.endLiveSession` frees the session's reserve; its tenant becomes idle).
public enum AdmissionStep: Sendable, Equatable, Hashable, Codable {
    /// Evict an idle tenant.
    case evict(tenant: String)
    /// Cancel the run, let it end, then evict its tenant. The run's caller requeues.
    case preempt(run: String, tenant: String)
    /// Wait for the run to finish, then evict its tenant.
    case awaitRun(run: String, tenant: String)
    /// End the live session (its caller sees it preempted).
    case endLiveSession(session: String, tenant: String)
}

/// The policy's answer at one step of an admission.
public enum AdmissionDecision: Sendable, Equatable, Hashable, Codable {
    /// The admission fits now.
    case fits
    /// Do this, then ask again.
    case step(AdmissionStep)
    /// Still short by this many bytes, and nothing is left that the conduct may take. The engine
    /// proceeds over-committed (the R-MEM-1 trigger covers what the declarations missed); a host
    /// may wait instead.
    case exhausted(shortByBytes: UInt64)
}

/// Why an admission is refused before anything is evicted.
public enum AdmissionRefusal: Error, Sendable, Equatable, Hashable, Codable {
    /// The working set (persistent + transient) exceeds the budget even with nothing else held.
    case exceedsBudget(required: UInt64, budget: UInt64)
    /// The working set does not fit beside what external tenants still declare, even with every
    /// tenant evicted.
    case externalTenantsHoldMemory(required: UInt64, external: UInt64, budget: UInt64)
}

/// A whole admission, projected without executing anything: what `MemoryPolicy.plan` returns.
public struct AdmissionPlan: Sendable, Equatable, Codable {
    public enum Outcome: Sendable, Equatable, Hashable, Codable {
        /// After `steps`, the admission fits.
        case fits
        /// After `steps`, still short: nothing more the conduct may take.
        case overcommitted(shortByBytes: UInt64)
        /// Refused before any step; `steps` is empty.
        case refused(AdmissionRefusal)
    }

    /// The four answers a scheduler switches on.
    public enum Verdict: Sendable, Equatable, Hashable, Codable {
        case fits
        /// Evict these idle tenants, in order.
        case evict([String])
        /// Reclaim running tenants: the runs to cancel or await, and every tenant evicted, in order.
        case preempt(runs: [String], evicting: [String])
        case refuse(AdmissionRefusal)
    }

    /// Bytes to ask external tenants for before the first step (0 = none). The plan assumes they
    /// release nothing; re-plan after asking.
    public var externalTenantRequestBytes: UInt64
    public var steps: [AdmissionStep]
    public var outcome: Outcome
    /// Further idle evictions R-MEM-1 would make against the measured reading `plan` was given,
    /// after `steps` (each eviction credited with the tenant's `measuredBytes`, else its
    /// persistent bytes).
    public var realPressureEvictions: [String]

    public init(externalTenantRequestBytes: UInt64 = 0, steps: [AdmissionStep] = [],
                outcome: Outcome, realPressureEvictions: [String] = []) {
        self.externalTenantRequestBytes = externalTenantRequestBytes
        self.steps = steps
        self.outcome = outcome
        self.realPressureEvictions = realPressureEvictions
    }

    /// Every tenant the plan evicts, in order (idle, reclaimed, then R-MEM-1).
    public var evictions: [String] {
        steps.compactMap { step -> String? in
            switch step {
            case .evict(let tenant), .preempt(_, let tenant), .awaitRun(_, let tenant):
                return tenant
            case .endLiveSession:
                return nil
            }
        } + realPressureEvictions
    }

    /// The runs and live sessions the plan cancels, awaits or ends, in order.
    public var reclaimedRuns: [String] {
        steps.compactMap { step -> String? in
            switch step {
            case .evict: return nil
            case .preempt(let run, _), .awaitRun(let run, _): return run
            case .endLiveSession(let session, _): return session
            }
        }
    }

    /// `.overcommitted` reads as the steps it would still take (the engine proceeds that way).
    public var verdict: Verdict {
        if case .refused(let refusal) = outcome { return .refuse(refusal) }
        if !reclaimedRuns.isEmpty { return .preempt(runs: reclaimedRuns, evicting: evictions) }
        if !evictions.isEmpty { return .evict(evictions) }
        return .fits
    }
}

/// The admission and eviction rules (contract 1.58.0). Pure: every function reads the
/// `MemoryState` it is given and nothing else.
public struct MemoryPolicy: Sendable, Equatable {
    /// Which tenants hold a transient reserve while idle.
    public enum TransientAccounting: String, Sendable, Equatable, Hashable, Codable {
        /// Every tenant's peak is in the one-max reserve, idle or not: a resident package may run
        /// again without a new admission, so its reserve is kept (MLXServeEngine).
        case everyResident
        /// Only runs in flight, live sessions and the admission itself reserve a transient: every
        /// run is admitted, so an idle tenant is charged its bytes, not its peak (a host that
        /// admits each job across workers, one GPU job at a time).
        case admittedRunsOnly
    }

    /// What an idle tenant is charged.
    public enum IdleCharge: String, Sendable, Equatable, Hashable, Codable {
        /// Its declared persistent bytes (MLXServeEngine).
        case declared
        /// The larger of declared persistent and `measuredBytes`, when measured. A busy tenant is
        /// still charged its declared bytes: its measured reading includes the activations its
        /// run's reserve already covers.
        case largerOfDeclaredAndMeasured
    }

    public var budgetBytes: UInt64
    /// `budget × highWatermark` is the R-MEM-1 ceiling for a measured reading.
    public var highWatermark: Double
    public var preemption: PreemptionPolicy
    public var transientAccounting: TransientAccounting
    public var idleCharge: IdleCharge

    /// The defaults are the engine's own rules.
    public init(budgetBytes: UInt64, highWatermark: Double = 0.85,
                preemption: PreemptionPolicy = PreemptionPolicy(),
                transientAccounting: TransientAccounting = .everyResident,
                idleCharge: IdleCharge = .declared) {
        self.budgetBytes = budgetBytes
        self.highWatermark = max(0, min(1, highWatermark))
        self.preemption = preemption
        self.transientAccounting = transientAccounting
        self.idleCharge = idleCharge
    }

    /// The policy a governor budgets: its budget and watermark.
    public init(governor: MemoryGovernor, preemption: PreemptionPolicy = PreemptionPolicy(),
                transientAccounting: TransientAccounting = .everyResident,
                idleCharge: IdleCharge = .declared) {
        self.init(budgetBytes: governor.budgetBytes, highWatermark: governor.highWatermark,
                  preemption: preemption, transientAccounting: transientAccounting,
                  idleCharge: idleCharge)
    }

    /// The R-MEM-1 ceiling: `budget × highWatermark`, compared against a measured footprint.
    public var realPressureCeiling: UInt64 { UInt64(Double(budgetBytes) * highWatermark) }

    // MARK: - Accounting

    /// What `tenant` is charged in residency.
    public func charge(_ tenant: MemoryTenant, in state: MemoryState) -> UInt64 {
        guard idleCharge == .largerOfDeclaredAndMeasured, let measured = tenant.measuredBytes,
              !state.isBusy(tenant.id) else { return tenant.persistentBytes }
        return max(tenant.persistentBytes, measured)
    }

    /// Σ charged tenants (optionally excluding one) + every external tenant's persistent bytes.
    public func residency(_ state: MemoryState, excluding skip: String? = nil) -> UInt64 {
        state.tenants.reduce(0) { $1.id == skip ? $0 : $0 &+ charge($1, in: state) }
            &+ state.external.persistentBytes
    }

    /// The tenants' ONE serialized transient reserve: the max of `extra`, the runs in flight, the
    /// live sessions and (under `.everyResident`) every tenant's peak — `skip` excluded throughout.
    public func tenantReserve(_ state: MemoryState, extra: UInt64 = 0,
                              excluding skip: String? = nil) -> UInt64 {
        var m = extra
        if transientAccounting == .everyResident {
            for tenant in state.tenants where tenant.id != skip { m = max(m, tenant.peakTransientBytes) }
        }
        for run in state.runs where run.tenant != skip { m = max(m, run.transientBytes) }
        for live in state.liveSessions where live.tenant != skip {
            m = max(m, live.reservedTransientBytes)
        }
        return m
    }

    /// The whole transient reserve: the tenants' one max plus every external tenant's transient
    /// (those are not serialized with runs).
    public func transientReserve(_ state: MemoryState, extra: UInt64 = 0,
                                 excluding skip: String? = nil) -> UInt64 {
        tenantReserve(state, extra: extra, excluding: skip) &+ state.external.transientBytes
    }

    /// The budget `admission` needs beside everything else held: Σ persistent + one max transient.
    public func required(_ admission: MemoryAdmission, in state: MemoryState) -> UInt64 {
        residency(state, excluding: admission.tenant) &+ admission.persistentBytes
            &+ transientReserve(state, extra: admission.transientBytes, excluding: admission.tenant)
    }

    /// What is free now: budget − residency − the transient reserve.
    public func availableBytes(_ state: MemoryState) -> UInt64 {
        let used = residency(state) &+ transientReserve(state)
        return budgetBytes > used ? budgetBytes - used : 0
    }

    /// What would be free if every idle tenant (except `keeping`) were evicted — nothing is
    /// committed. A host choosing among a model's lanes (G-23) asks this before it plans.
    public func availableBytes(_ state: MemoryState, afterEvictingIdleExcept keeping: String?) -> UInt64 {
        let idle = Set(idleTenants(state, excluding: keeping))
        var remaining = state
        remaining.tenants.removeAll { idle.contains($0.id) }
        return availableBytes(remaining)
    }

    // MARK: - Victims

    /// The evictable idle tenants other than `skip`, least recently used first (ties keep the
    /// order of `state.tenants`).
    public func idleTenants(_ state: MemoryState, excluding skip: String? = nil) -> [String] {
        state.tenants.enumerated()
            .filter { $0.element.id != skip && $0.element.evictable && !state.isBusy($0.element.id) }
            .sorted { ($0.element.lastUsed, $0.offset) < ($1.element.lastUsed, $1.offset) }
            .map(\.element.id)
    }

    /// The least-recently-used idle tenant other than `skip`. A tenant with a run or a live
    /// session is never idle.
    public func idleVictim(_ state: MemoryState, excluding skip: String? = nil) -> String? {
        idleTenants(state, excluding: skip).first
    }

    /// The run to reclaim next: on an evictable tenant other than `skip`, lowest progress first
    /// (an unreported run reads 0 — nothing measurable to preserve; ties keep `state.runs` order).
    public func runVictim(_ state: MemoryState, excluding skip: String? = nil) -> MemoryRun? {
        let evictable = Set(state.tenants.filter(\.evictable).map(\.id))
        return state.runs
            .filter { $0.tenant != skip && evictable.contains($0.tenant) }
            .min { $0.progress < $1.progress }
    }

    /// The live session to end next: on an evictable tenant other than `skip`, longest idle first.
    public func liveSessionVictim(_ state: MemoryState,
                                  excluding skip: String? = nil) -> MemoryLiveSession? {
        let evictable = Set(state.tenants.filter(\.evictable).map(\.id))
        return state.liveSessions
            .filter { $0.tenant != skip && evictable.contains($0.tenant) }
            .max { $0.idleSeconds < $1.idleSeconds }
    }

    // MARK: - The ladder

    /// Rung 1: the working set cannot fit the budget even alone.
    public func ownPeakRefusal(persistentBytes: UInt64, transientBytes: UInt64) -> AdmissionRefusal? {
        let peak = persistentBytes &+ transientBytes
        return peak > budgetBytes ? .exceedsBudget(required: peak, budget: budgetBytes) : nil
    }

    /// Rung 2a: the bytes to ask external tenants for before evicting anything (0 = none needed).
    public func externalTenantDeficit(_ admission: MemoryAdmission, in state: MemoryState) -> UInt64 {
        let needed = required(admission, in: state)
        return needed > budgetBytes ? needed - budgetBytes : 0
    }

    /// Rung 2b: after asking, the working set does not fit beside what external tenants still
    /// declare even with every tenant evicted — so evicting would throw weights away for nothing.
    public func externalRefusal(_ admission: MemoryAdmission, in state: MemoryState) -> AdmissionRefusal? {
        let peak = admission.persistentBytes &+ admission.transientBytes
        let external = state.external.totalBytes
        return peak &+ external > budgetBytes
            ? .externalTenantsHoldMemory(required: peak, external: external, budget: budgetBytes)
            : nil
    }

    /// Rungs 3–5, one step at a time under the declared accounting: fits, or the next victim —
    /// idle LRU, then (unless `.idleOnly`) a running tenant, then (`.preempting` only) a live
    /// session. A run at or past `preemption.preserveNearlyDoneFraction` is awaited, never
    /// cancelled.
    public func nextStep(_ admission: MemoryAdmission, in state: MemoryState,
                         conduct: AdmissionConduct) -> AdmissionDecision {
        let needed = required(admission, in: state)
        guard needed > budgetBytes else { return .fits }
        if let victim = idleVictim(state, excluding: admission.tenant) {
            return .step(.evict(tenant: victim))
        }
        let short = AdmissionDecision.exhausted(shortByBytes: needed - budgetBytes)
        guard conduct != .idleOnly else { return short }
        if let run = runVictim(state, excluding: admission.tenant) {
            let cancel = conduct == .preempting && run.progress < preemption.preserveNearlyDoneFraction
            return .step(cancel ? .preempt(run: run.token, tenant: run.tenant)
                                : .awaitRun(run: run.token, tenant: run.tenant))
        }
        if conduct == .preempting, let live = liveSessionVictim(state, excluding: admission.tenant) {
            return .step(.endLiveSession(session: live.token, tenant: live.tenant))
        }
        return short
    }

    /// Rung 6, R-MEM-1: `reading` is the measured footprint, already credited
    /// (`credited(_:released:)`). Over the ceiling, evict the next idle tenant; none left, the
    /// remaining pressure is not ours to reclaim.
    public func nextRealPressureStep(admitting tenant: String, reading: UInt64,
                                     in state: MemoryState) -> AdmissionDecision {
        let ceiling = realPressureCeiling
        guard reading > ceiling else { return .fits }
        guard let victim = idleVictim(state, excluding: tenant) else {
            return .exhausted(shortByBytes: reading - ceiling)
        }
        return .step(.evict(tenant: victim))
    }

    /// A measured reading net of the bytes external tenants declared dropping during this
    /// admission: the reading lags a Metal release, the declaration does not.
    public static func credited(_ reading: UInt64, released: UInt64) -> UInt64 {
        reading > released ? reading - released : 0
    }

    /// The order to ask external tenants in: largest declaration first.
    public static func shrinkOrder<T>(_ tenants: [T], footprint: (T) -> ExternalFootprint) -> [T] {
        tenants.sorted { footprint($0).totalBytes > footprint($1).totalBytes }
    }

    // MARK: - The whole plan

    /// Project a whole admission without executing it: the refusal, or the steps in order and
    /// whether they make it fit. Each step is applied to a copy of `state` — an evicted tenant
    /// leaves, a reclaimed run and its tenant leave, an ended session leaves — and the ladder asked
    /// again. With a `measuredReading` (in-process: `phys_footprint`; across processes: Σ the
    /// workers'), R-MEM-1's further idle evictions are projected too, each crediting the evicted
    /// tenant's `measuredBytes` (else its persistent bytes).
    ///
    /// The engine does not run this: it asks `nextStep` against fresh state between steps, since
    /// a run can end and a tenant can shrink while it waits. A host that cannot execute steps
    /// concurrently with the state changing gets the same answer from either.
    public func plan(_ admission: MemoryAdmission, in state: MemoryState,
                     conduct: AdmissionConduct, measuredReading: UInt64? = nil) -> AdmissionPlan {
        if let refusal = ownPeakRefusal(persistentBytes: admission.persistentBytes,
                                        transientBytes: admission.transientBytes) {
            return AdmissionPlan(outcome: .refused(refusal))
        }
        let ask = state.externalTenants.isEmpty ? 0 : externalTenantDeficit(admission, in: state)
        if let refusal = externalRefusal(admission, in: state) {
            return AdmissionPlan(externalTenantRequestBytes: ask, outcome: .refused(refusal))
        }
        var s = state
        var steps: [AdmissionStep] = []
        var outcome = AdmissionPlan.Outcome.fits
        var removedMeasured: UInt64 = 0
        func evict(_ id: String) {
            if let tenant = s.tenants.first(where: { $0.id == id }) {
                removedMeasured &+= tenant.measuredBytes ?? tenant.persistentBytes
            }
            s.tenants.removeAll { $0.id == id }
        }
        // Every step removes a tenant, a run or a session, so this ends.
        declared: while true {
            switch nextStep(admission, in: s, conduct: conduct) {
            case .fits:
                break declared
            case .exhausted(let short):
                outcome = .overcommitted(shortByBytes: short)
                break declared
            case .step(let step):
                steps.append(step)
                switch step {
                case .evict(let tenant):
                    evict(tenant)
                case .preempt(let run, let tenant), .awaitRun(let run, let tenant):
                    s.runs.removeAll { $0.token == run }
                    evict(tenant)
                case .endLiveSession(let session, _):
                    s.liveSessions.removeAll { $0.token == session }
                }
            }
        }
        var realEvictions: [String] = []
        if let measuredReading {
            while case .step(.evict(let tenant)) = nextRealPressureStep(
                admitting: admission.tenant,
                reading: Self.credited(measuredReading, released: removedMeasured), in: s) {
                realEvictions.append(tenant)
                evict(tenant)
            }
        }
        return AdmissionPlan(externalTenantRequestBytes: ask, steps: steps, outcome: outcome,
                             realPressureEvictions: realEvictions)
    }
}
