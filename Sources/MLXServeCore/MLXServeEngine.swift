import Foundation
import MLXToolKit

/// Errors the coordinator raises around admission and routing.
public enum EngineError: Error, Sendable, Equatable {
    /// No registered package backs the requested capability.
    case noPackage(Capability)
    /// The capability is registered, but not by the requested package id.
    case unknownPackage(Capability, PackageID)
    /// The two-layer license gate rejected the package (names the failing layer).
    case licenseRejected(LicenseGateResult)
    /// The device can't run the package (C10): names the failing dimension.
    case ineligible(DeviceEligibility)
    /// The package's resident footprint exceeds the whole memory budget — it can't fit even alone.
    case exceedsMemoryBudget(required: UInt64, budget: UInt64)
}

/// Engine-side identity for a registered package — lets several packages back the SAME
/// capability ("modularity on top of MLXEngine": the app decides which modules it wants
/// per capability). Defaults to the manifest's first surface (tool) name — unique and
/// human-meaningful ("lens-t2i", "qwen-image-edit") — falling back to
/// `provenance.sourceRepo`; pass an explicit id to register the same package twice
/// (e.g. bf16 vs 4-bit variants).
public struct PackageID: Hashable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// A non-mutating verdict on whether a package's requirements can run on this engine's device +
/// memory budget, without loading anything — the Model-Manager seam for ranking/filtering variants.
public struct Admissibility: Sendable, Equatable {
    public let eligibility: DeviceEligibility
    public let footprint: UInt64
    /// Fits the whole budget (could load, possibly after evicting idle residents).
    public let fitsBudget: Bool
    /// Fits the current free headroom (could load right now without eviction).
    public let fitsAvailable: Bool

    public var admissible: Bool { eligibility.isEligible && fitsBudget }
    public var admissibleNow: Bool { eligibility.isEligible && fitsAvailable }
}

/// The minimal MLXEngine runtime coordinator.
///
/// The first real slice of `MLXServeCore`: a registry + admission path that realizes the
/// architecture's **inversion of control** — the engine, not the package, constructs / loads /
/// drives / evicts each `ModelPackage`. Consumers talk to the engine (`register` + `run`).
///
/// **Multi-package per capability:** a capability can be backed by several registered packages
/// (e.g. Lens AND ERNIE-Turbo both serving `textToImage`); each capability routes to its
/// *default* package unless a request names one explicitly. Registering a package for an
/// already-backed capability ADDS it and makes it the new default (preserving the historical
/// "last registration wins routing" swap flow); `setDefault` re-points routing without
/// re-registering. Residents are keyed by package — one registration serving N capabilities
/// is constructed once and shared.
///
/// Admission enforces **C10 device eligibility** (`DeviceProfile`) at registration and
/// **memory headroom** (`MemoryGovernor`) at load: when a new working set won't fit, idle residents
/// are evicted **LRU** until it does. Still TODO and tracked elsewhere: `HubAssetSource` SHA256
/// verification, mid-run eviction-under-pressure + requeue, `MemoryPool` backend placement,
/// `MCPBridge`.
public actor MLXServeEngine {

    /// A registered package, its init-time configuration, and the resolved memory footprint split:
    /// `persistent` weights (charged for the whole residency) and the `transient` activation peak
    /// (reserved once across residents, since inference is serialized — see R-MEM-1).
    private struct Entry {
        let registration: PackageRegistration
        let configuration: any PackageConfiguration
        let persistent: UInt64
        let transient: UInt64
    }

    /// Package id → the registration backing it.
    private var packages: [PackageID: Entry] = [:]
    /// Capability → the package ids backing it, in registration order.
    private var backing: [Capability: [PackageID]] = [:]
    /// Capability → the package routing defaults to (set at registration; `setDefault` re-points).
    private var defaults: [Capability: PackageID] = [:]
    /// Package id → the constructed + resident instance (lazily built on first admission;
    /// shared across every capability the registration serves).
    private var residents: [PackageID: any ModelPackage] = [:]
    /// Package id → persistent bytes charged to the governor for its resident weights.
    private var residentFootprint: [PackageID: UInt64] = [:]
    /// Package id → its transient activation peak (the reserve is the max of these across residents).
    private var residentTransient: [PackageID: UInt64] = [:]
    /// Package id → last-use tick (for LRU eviction).
    private var lastUsed: [PackageID: UInt64] = [:]
    private var useClock: UInt64 = 0

    private let policy: LicensePolicy
    /// The host profile used for the C10 eligibility check.
    public nonisolated let deviceProfile: DeviceProfile
    /// Memory budgeting + watermark policy.
    private var governor: MemoryGovernor
    /// Where packages materialize weights + the marker the storage UI counts. Empty by default
    /// (packages use their own cache); a consuming app sets it once via `useModelStore`.
    private var modelStore: ModelStore = ModelStore()
    /// Real-memory reading for the R-MEM-1 pressure trigger (`phys_footprint`). Injectable so tests
    /// can drive admission with a controlled footprint; defaults to the live host reading.
    private let physFootprint: @Sendable () -> UInt64?

    /// Observable preparation progress per capability/package (registering → prewarming → downloading
    /// → loading → ready/failed). A consuming app binds `MLXEngineUI.ModelStateView` to this to show a
    /// consistent download/first-load affordance. Updated as `prepare()`/`resident()` runs.
    public nonisolated let preparation = PreparationMonitor()

    public init(policy: LicensePolicy = .permissiveOnly,
                device: DeviceProfile = .current(),
                governor: MemoryGovernor? = nil,
                physFootprint: @Sendable @escaping () -> UInt64? = HostMemory.physFootprint) {
        self.policy = policy
        self.deviceProfile = device
        self.governor = governor ?? .forDevice(device)
        self.physFootprint = physFootprint
    }

    /// Point the engine's model store at a download root (the app's chosen, security-scoped models
    /// folder). Applies to packages registered *after* this call — set it before `register`. Every
    /// `ModelStorable` configuration is then stamped to download here, and the engine writes the
    /// storage marker after each successful `load()`.
    public func useModelStore(_ store: ModelStore) {
        modelStore = store
    }

    /// Register a package + its configuration. Runs the two-layer **license gate** and the **C10
    /// device-eligibility** check now (before any instance exists); construction is deferred to first
    /// admission and is always the engine's move (C13).
    ///
    /// The package's capabilities each gain this package as a backer AND as their new default
    /// (last registration wins routing — `setDefault` re-points later without re-registering).
    /// Re-registering an existing `id` replaces that entry (and evicts any stale resident).
    ///
    /// - Parameter id: engine-side identity; defaults to the manifest's first surface name
    ///   (falling back to `provenance.sourceRepo`).
    /// - Throws: `.licenseRejected` (failing layer) or `.ineligible` (failing device dimension).
    @discardableResult
    public func register(_ registration: PackageRegistration,
                         configuration: any PackageConfiguration,
                         id: PackageID? = nil) async throws -> PackageID {
        let gate = policy.evaluate(registration.manifest.license)
        guard gate.isAdmitted else { throw EngineError.licenseRejected(gate) }

        let eligibility = deviceProfile.eligibility(for: registration.manifest.requirements)
        guard eligibility.isEligible else { throw EngineError.ineligible(eligibility) }

        // Stamp the download root onto the configuration so the package materializes weights in the
        // engine's model store rather than its default cache. Configs that don't opt in (don't
        // conform to `ModelStorable`) are left untouched.
        var configuration = configuration
        if var storable = configuration as? ModelStorable {
            storable.modelsRootDirectory = modelStore.root
            if let restamped = storable as? any PackageConfiguration { configuration = restamped }
        }

        let packageID = id ?? PackageID(
            registration.manifest.surfaces.first?.name
                ?? registration.manifest.provenance.sourceRepo)
        if packages[packageID] != nil {
            // Replacement: drop any resident built from the stale registration.
            await evictResident(packageID)
            for capability in backing.keys {
                backing[capability]?.removeAll { $0 == packageID }
            }
        }

        // Resolve the registered variant's (persistent weights, transient activation peak) split:
        // a `FootprintConfigured` hint (measured per-mode bytes — resolves same-quant multi-mode configs
        // like BiRefNet fast/best) wins; else the `QuantConfigured` quant match (avoids the largest-
        // that-fits under-reserve of bf16 when bf16 > budget); else largest-that-fits. Transient defaults
        // to 0 when undeclared (the reactive R-MEM-1 trigger covers any overflow).
        let fc = configuration as? FootprintConfigured
        let split = governor.footprintSplit(
            for: registration.manifest.requirements,
            quant: (configuration as? QuantConfigured)?.quant,
            persistentHint: fc?.residentBytesHint,
            transientHint: fc?.peakActivationBytesHint)
        packages[packageID] = Entry(registration: registration,
                                    configuration: configuration,
                                    persistent: split.persistent,
                                    transient: split.transient)
        for capability in registration.manifest.capabilities {
            backing[capability, default: []].append(packageID)
            defaults[capability] = packageID
        }
        return packageID
    }

    /// The capabilities currently backed by at least one registered package.
    public var registeredCapabilities: [Capability] { Array(backing.keys) }

    /// Every package backing a capability, in registration order.
    public func packages(for capability: Capability) -> [PackageID] {
        backing[capability] ?? []
    }

    /// The package a capability currently routes to by default.
    public func defaultPackage(for capability: Capability) -> PackageID? {
        defaults[capability]
    }

    /// Re-point a capability's default routing to one of its registered backers.
    public func setDefault(_ id: PackageID, for capability: Capability) throws {
        guard backing[capability]?.contains(id) == true else {
            throw EngineError.unknownPackage(capability, id)
        }
        defaults[capability] = id
    }

    /// A registered package's manifest (for Model-Manager UI / variant ranking).
    public func manifest(for id: PackageID) -> PackageManifest? {
        packages[id]?.registration.manifest
    }

    /// Observable memory state (budget / resident / available / pressure + per-package charge).
    public var memory: MemorySnapshot {
        // Per-capability view (API-stable): each resident package's charge is reported under
        // every capability it backs whose default is that package.
        var byCapability: [Capability: UInt64] = [:]
        for (capability, id) in defaults {
            if let bytes = residentFootprint[id] { byCapability[capability] = bytes }
        }
        let real = physFootprint()
        let realCeiling = UInt64(Double(governor.budgetBytes) * governor.highWatermark)
        // Reserve-aware available: budget − Σ persistent − one transient reserve.
        let reserve = transientReserve()
        let used = governor.residentBytes &+ reserve
        let available = governor.budgetBytes > used ? governor.budgetBytes &- used : 0
        return MemorySnapshot(
            budgetBytes: governor.budgetBytes,
            residentBytes: governor.residentBytes,
            availableBytes: available,
            underPressure: governor.underPressure,
            residents: byCapability,
            realResidentBytes: real,
            underRealPressure: (real ?? 0) > realCeiling,
            transientReserveBytes: reserve
        )
    }

    /// Resident packages and the bytes charged for each (the package-keyed memory view).
    public var residentPackages: [PackageID: UInt64] { residentFootprint }

    /// Evaluate requirements against the device (C10) + current memory budget **without loading** —
    /// for surfacing "what can this machine run?" and for a Model Manager to rank variants.
    ///
    /// Pass `quant`/`hint` to evaluate the **selected** variant (the same footprint a real
    /// registration of that config would charge) rather than the variant-agnostic largest-that-fits
    /// survey — closing the static-manifest-vs-configured-variant gap on the admissibility side. Both
    /// default to `nil`, so `admissibility(for: requirements)` keeps the survey behavior.
    public func admissibility(for requirements: RequirementsManifest,
                              quant: Quant? = nil,
                              hint: UInt64? = nil,
                              transientHint: UInt64? = nil) -> Admissibility {
        let split = governor.footprintSplit(for: requirements, quant: quant,
                                            persistentHint: hint, transientHint: transientHint)
        let ownPeak = split.persistent &+ split.transient                       // weights + its scratch
        // Right-now fit under the serialized-inference accounting (none excluded — it isn't resident).
        let required = residency() &+ split.persistent &+ transientReserve(extra: split.transient)
        return Admissibility(
            eligibility: deviceProfile.eligibility(for: requirements),
            footprint: ownPeak,
            fitsBudget: ownPeak <= governor.budgetBytes,
            fitsAvailable: required <= governor.budgetBytes
        )
    }

    /// Config-aware admissibility: evaluate exactly the variant a given configuration would load,
    /// reading its `QuantConfigured` quant and `FootprintConfigured` hints (persistent + transient) the
    /// same way `register` does. The ergonomic seam for a Model Manager ranking a concrete configuration.
    public func admissibility(for requirements: RequirementsManifest,
                              configuration: any PackageConfiguration) -> Admissibility {
        let fc = configuration as? FootprintConfigured
        return admissibility(for: requirements,
                             quant: (configuration as? QuantConfigured)?.quant,
                             hint: fc?.residentBytesHint,
                             transientHint: fc?.peakActivationBytesHint)
    }

    /// Admit + run one request: resolve the package for `request.capability` (the capability's
    /// default, or `package` when the caller selects a specific module), lazily construct and
    /// page it in (evicting LRU residents if needed), then run on the `InferenceActor`.
    public func run(_ request: any CapabilityRequest,
                    package: PackageID? = nil) async throws -> any CapabilityResponse {
        let capability = request.capability
        let id = try resolve(capability, package)
        let instance = try await resident(id)
        let response = try await instance.run(request)
        touch(id) // mark recently used after a successful run
        return response
    }

    /// Ensure the package for a capability is constructed + loaded, returning it. Warms a model
    /// (and applies memory admission) before the first `run`.
    @discardableResult
    public func prepare(_ capability: Capability,
                        package: PackageID? = nil) async throws -> any ModelPackage {
        try await resident(resolve(capability, package))
    }

    /// Evict a capability's resident instance (`unload()` + release its budget); the registration
    /// remains so it can be admitted again later. Pass `package` to evict a specific backer;
    /// otherwise the capability's default is evicted.
    public func evict(_ capability: Capability, package: PackageID? = nil) async {
        guard let id = package ?? defaults[capability] else { return }
        await evictResident(id)
    }

    /// Evict a specific package's resident instance regardless of capability routing.
    public func evict(package id: PackageID) async {
        await evictResident(id)
    }

    // MARK: - Memory accounting (serialized-inference reserve)

    /// Σ persistent resident weights, optionally excluding one id (the incoming, not yet charged).
    private func residency(excluding skip: PackageID? = nil) -> UInt64 {
        residentFootprint.reduce(0) { $1.key == skip ? $0 : $0 &+ $1.value }
    }

    /// The single transient activation headroom to reserve: `max(peakActivation)` across residents,
    /// since only one model runs at a time. `extra` folds in an incoming model's transient; `skip`
    /// excludes one id.
    private func transientReserve(extra: UInt64 = 0, excluding skip: PackageID? = nil) -> UInt64 {
        var m = extra
        for (id, t) in residentTransient where id != skip { m = max(m, t) }
        return m
    }

    /// Total budget to account for if `(persistent, transient)` were resident alongside the current
    /// residents (excluding `id`): Σ persistent + one max transient.
    private func accountedRequired(persistent p: UInt64, transient t: UInt64,
                                   excluding id: PackageID) -> UInt64 {
        residency(excluding: id) &+ p &+ transientReserve(extra: t, excluding: id)
    }

    // MARK: - Admission

    private func resolve(_ capability: Capability, _ package: PackageID?) throws -> PackageID {
        if let package {
            guard backing[capability]?.contains(package) == true else {
                throw EngineError.unknownPackage(capability, package)
            }
            return package
        }
        guard let id = defaults[capability] else { throw EngineError.noPackage(capability) }
        return id
    }

    private func resident(_ id: PackageID) async throws -> any ModelPackage {
        if let existing = residents[id] {
            touch(id)
            return existing
        }
        guard let entry = packages[id] else {
            throw EngineError.noPackage(.llm) // unreachable: resolve() validated the id
        }
        let manifest = entry.registration.manifest
        let caps = manifest.capabilities
        let pkg = id.description

        do {
            await updatePhase(.registering, caps: caps, package: pkg)

            // Defensive re-gate — the engine constructs, never the package (C13).
            let gate = policy.evaluate(manifest.license)
            guard gate.isAdmitted else { throw EngineError.licenseRejected(gate) }

            // Memory admission (serialized-inference reserve): residency = Σ persistent weights, plus a
            // single transient activation reserve (only one model runs at a time). The model's own peak
            // (persistent + transient) must fit the budget; then evict idle LRU until the co-resident
            // accounting fits.
            let persistent = entry.persistent
            let transient = entry.transient
            guard governor.fitsBudget(persistent &+ transient) else {
                throw EngineError.exceedsMemoryBudget(required: persistent &+ transient,
                                                      budget: governor.budgetBytes)
            }
            await makeHeadroom(persistent: persistent, transient: transient, keeping: id)

            // Stamp the headroom this model is loading into onto a BudgetAware config (for memory-adaptive
            // dtype), computed AFTER eviction so it reflects the real available room. Mirrors how
            // ModelStorable is stamped — additive, non-conformers untouched.
            var configuration = entry.configuration
            if var budgetAware = configuration as? BudgetAware {
                let used = residency(excluding: id) &+ transientReserve(excluding: id)
                budgetAware.availableBudgetBytes = governor.budgetBytes > used
                    ? governor.budgetBytes &- used : 0
                if let restamped = budgetAware as? any PackageConfiguration { configuration = restamped }
            }
            let instance = try entry.registration.makePackage(configuration)
            // Cold-start watchdog mitigation: page the package's declared weight files into the OS cache
            // before load() issues GPU evals, so file-I/O latency never stalls a live Metal command
            // buffer. Opt-in (config conforms to WeightPrewarming) + best-effort (never fails prepare()).
            if let prewarming = entry.configuration as? WeightPrewarming {
                let onPrewarm: @Sendable (Double) -> Void = { [preparation] fraction in
                    Task { @MainActor in
                        for cap in caps {
                            preparation.update(cap, package: pkg, to: .prewarming(fraction: fraction))
                        }
                    }
                }
                await WeightPrewarmer.prewarm(prewarming.prewarmPaths, label: pkg, onProgress: onPrewarm)
            }

            // Bind the ambient download-progress sink around load() so a package that forwards its
            // downloader's progress (WeightDownloadProgress.report) surfaces a real download fraction.
            await updatePhase(.loading, caps: caps, package: pkg)
            let sink: WeightDownloadProgress.Sink = { [preparation] fraction, bps in
                Task { @MainActor in
                    for cap in caps {
                        preparation.update(cap, package: pkg,
                                           to: .downloading(fraction: fraction, bytesPerSecond: bps))
                    }
                }
            }
            try await WeightDownloadProgress.$sink.withValue(sink) {
                try await instance.load()
            }

            // Weights are now materialized under the store root — stamp the marker the storage UI
            // counts (one per package). No-op when no store root is set.
            modelStore.writeMarker(repo: manifest.provenance.sourceRepo,
                                   revision: manifest.provenance.revision,
                                   capabilities: manifest.capabilities)
            residents[id] = instance
            residentFootprint[id] = persistent
            residentTransient[id] = transient
            governor.charge(persistent)
            touch(id)
            await updatePhase(.ready, caps: caps, package: pkg)
            return instance
        } catch {
            await updatePhase(.failed("\(error)"), caps: caps, package: pkg)
            throw error
        }
    }

    /// Record a preparation phase across every capability the package backs (so a consumer can observe
    /// by capability alone or by exact package id). Hops to the main actor where the monitor lives.
    private func updatePhase(_ phase: PreparePhase, caps: [Capability], package: String) async {
        await MainActor.run {
            for cap in caps { preparation.update(cap, package: package, to: phase) }
        }
    }

    /// Best-effort pre-`prepare` check: will this capability's package still need to materialize weights
    /// from the network? A consumer uses it to route the user into the download UI first.
    ///
    /// Heuristic: if the configuration declares local weight paths (`WeightPrewarming`) and they all
    /// exist → no download. Otherwise → needs download when the per-package install marker is absent
    /// under the current store root (the same signal the storage UI counts). NB this reads as `true`
    /// the first time for *bundled* packages too (they have no marker yet but won't actually hit the
    /// network); their phase will simply skip `.downloading`.
    public func needsDownload(_ capability: Capability, package: PackageID? = nil) -> Bool {
        guard let id = try? resolve(capability, package), let entry = packages[id] else { return false }
        if let prewarming = entry.configuration as? WeightPrewarming {
            let paths = prewarming.prewarmPaths
            if !paths.isEmpty,
               paths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return false
            }
        }
        let repo = entry.registration.manifest.provenance.sourceRepo
        guard let dir = modelStore.directory(for: repo) else { return true }
        return !FileManager.default.fileExists(atPath: dir.appending(path: ModelStore.markerName).path)
    }

    /// Evict least-recently-used idle residents until the incoming model's accounting fits the budget.
    /// Terminates because the caller has checked `persistent + transient ≤ budget`: evicting every other
    /// resident frees the full budget.
    ///
    /// Two passes: (1) **declared-byte** headroom under the serialized-inference accounting (Σ persistent
    /// weights + one max transient); (2) **R-MEM-1 real-pressure** — declared `QuantFootprint` bytes are
    /// a *floor*,
    /// so even when the declared sum fits, the process's *actual* `phys_footprint` may be over the
    /// governor's high-watermark (activations/scratch the declarations omit). In that case evict idle
    /// LRU residents until real pressure clears or none remain. Conservative and bounded: it only
    /// reclaims our own idle residents (never the incoming `id`), and stops when nothing's left to
    /// evict, so external (non-engine) memory pressure can't loop. Degrades to the declared-byte pass
    /// when no host reading is available.
    private func makeHeadroom(persistent p: UInt64, transient t: UInt64, keeping id: PackageID) async {
        // (1) Declared-byte headroom under the serialized-inference accounting (Σ persistent + one
        // max transient). Evict idle LRU until the incoming model's accounting fits the budget.
        while accountedRequired(persistent: p, transient: t, excluding: id) > governor.budgetBytes {
            guard let victim = lruIdleVictim(excluding: id) else {
                break // nothing left to evict
            }
            await evictResident(victim)
        }

        // (2) R-MEM-1: real-memory pressure trigger.
        let ceiling = UInt64(Double(governor.budgetBytes) * governor.highWatermark)
        while let real = physFootprint(), real > ceiling {
            guard let victim = lruIdleVictim(excluding: id) else {
                break // reclaimed everything we can; remaining pressure is external
            }
            await evictResident(victim)
        }
    }

    /// The least-recently-used resident other than `id`, or nil if none remain.
    private func lruIdleVictim(excluding id: PackageID) -> PackageID? {
        residents.keys
            .filter { $0 != id }
            .min(by: { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) })
    }

    private func evictResident(_ id: PackageID) async {
        guard let instance = residents.removeValue(forKey: id) else { return }
        await instance.unload()
        if let bytes = residentFootprint.removeValue(forKey: id) {
            governor.release(bytes)
        }
        residentTransient.removeValue(forKey: id)
        lastUsed.removeValue(forKey: id)
    }

    private func touch(_ id: PackageID) {
        useClock &+= 1
        lastUsed[id] = useClock
    }
}
