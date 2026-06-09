import MLXToolKit

/// Errors the coordinator raises around admission and routing.
public enum EngineError: Error, Sendable, Equatable {
    /// No registered package backs the requested capability.
    case noPackage(Capability)
    /// The two-layer license gate rejected the package (names the failing layer).
    case licenseRejected(LicenseGateResult)
    /// The device can't run the package (C10): names the failing dimension.
    case ineligible(DeviceEligibility)
    /// The package's resident footprint exceeds the whole memory budget — it can't fit even alone.
    case exceedsMemoryBudget(required: UInt64, budget: UInt64)
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
/// Admission now enforces **C10 device eligibility** (`DeviceProfile`) at registration and
/// **memory headroom** (`MemoryGovernor`) at load: when a new working set won't fit, idle residents
/// are evicted **LRU** until it does. Still TODO and tracked elsewhere: `HubAssetSource` SHA256
/// verification, mid-run eviction-under-pressure + requeue, `MemoryPool` backend placement,
/// `MCPBridge`.
public actor MLXServeEngine {

    /// A registered package, its init-time configuration, and the resident footprint to charge.
    private struct Entry {
        let registration: PackageRegistration
        let configuration: any PackageConfiguration
        let footprint: UInt64
    }

    /// Capability → the registration backing it. One model can register N capabilities (Lance → 4).
    private var entries: [Capability: Entry] = [:]
    /// Capability → the constructed + resident instance (lazily built on first admission).
    private var residents: [Capability: any ModelPackage] = [:]
    /// Capability → bytes charged to the governor for its resident working set.
    private var residentFootprint: [Capability: UInt64] = [:]
    /// Capability → last-use tick (for LRU eviction).
    private var lastUsed: [Capability: UInt64] = [:]
    private var useClock: UInt64 = 0

    private let policy: LicensePolicy
    /// The host profile used for the C10 eligibility check.
    public nonisolated let deviceProfile: DeviceProfile
    /// Memory budgeting + watermark policy.
    private var governor: MemoryGovernor
    /// Where packages materialize weights + the marker the storage UI counts. Empty by default
    /// (packages use their own cache); a consuming app sets it once via `useModelStore`.
    private var modelStore: ModelStore = ModelStore()

    public init(policy: LicensePolicy = .permissiveOnly,
                device: DeviceProfile = .current(),
                governor: MemoryGovernor? = nil) {
        self.policy = policy
        self.deviceProfile = device
        self.governor = governor ?? .forDevice(device)
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
    /// - Throws: `.licenseRejected` (failing layer) or `.ineligible` (failing device dimension).
    public func register(_ registration: PackageRegistration,
                         configuration: any PackageConfiguration) throws {
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

        let footprint = governor.footprint(for: registration.manifest.requirements)
        for capability in registration.manifest.capabilities {
            entries[capability] = Entry(registration: registration,
                                        configuration: configuration,
                                        footprint: footprint)
        }
    }

    /// The capabilities currently backed by a registered package.
    public var registeredCapabilities: [Capability] { Array(entries.keys) }

    /// Observable memory state (budget / resident / available / pressure + per-capability charge).
    public var memory: MemorySnapshot {
        MemorySnapshot(
            budgetBytes: governor.budgetBytes,
            residentBytes: governor.residentBytes,
            availableBytes: governor.availableBytes,
            underPressure: governor.underPressure,
            residents: residentFootprint
        )
    }

    /// Evaluate requirements against the device (C10) + current memory budget **without loading** —
    /// for surfacing "what can this machine run?" and for a Model Manager to rank variants.
    public func admissibility(for requirements: RequirementsManifest) -> Admissibility {
        let footprint = governor.footprint(for: requirements)
        return Admissibility(
            eligibility: deviceProfile.eligibility(for: requirements),
            footprint: footprint,
            fitsBudget: governor.fitsBudget(footprint),
            fitsAvailable: governor.canFit(footprint)
        )
    }

    /// Admit + run one request: resolve the package for `request.capability`, lazily construct and
    /// page it in (evicting LRU residents if needed), then run on the `InferenceActor`.
    public func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        let capability = request.capability
        let instance = try await resident(for: capability)
        let response = try await instance.run(request)
        touch(capability) // mark recently used after a successful run
        return response
    }

    /// Ensure the package for a capability is constructed + loaded, returning it. Warms a model
    /// (and applies memory admission) before the first `run`.
    @discardableResult
    public func prepare(_ capability: Capability) async throws -> any ModelPackage {
        try await resident(for: capability)
    }

    /// Evict a capability's resident instance (`unload()` + release its budget); the registration
    /// remains so it can be admitted again later.
    public func evict(_ capability: Capability) async {
        await evictResident(capability)
    }

    // MARK: - Admission

    private func resident(for capability: Capability) async throws -> any ModelPackage {
        if let existing = residents[capability] {
            touch(capability)
            return existing
        }
        guard let entry = entries[capability] else { throw EngineError.noPackage(capability) }

        // Defensive re-gate — the engine constructs, never the package (C13).
        let gate = policy.evaluate(entry.registration.manifest.license)
        guard gate.isAdmitted else { throw EngineError.licenseRejected(gate) }

        // Memory admission: the working set must fit the budget; evict idle residents (LRU) to
        // make headroom. A footprint larger than the whole budget can never fit.
        let footprint = entry.footprint
        guard governor.fitsBudget(footprint) else {
            throw EngineError.exceedsMemoryBudget(required: footprint, budget: governor.budgetBytes)
        }
        await makeHeadroom(for: footprint, keeping: capability)

        let instance = try entry.registration.makePackage(entry.configuration)
        try await instance.load()
        // Weights are now materialized under the store root — stamp the marker the storage UI
        // counts (one per package). No-op when no store root is set.
        let manifest = entry.registration.manifest
        modelStore.writeMarker(repo: manifest.provenance.sourceRepo,
                               revision: manifest.provenance.revision,
                               capabilities: manifest.capabilities)
        residents[capability] = instance
        residentFootprint[capability] = footprint
        governor.charge(footprint)
        touch(capability)
        return instance
    }

    /// Evict least-recently-used idle residents until `bytes` fits the headroom. Terminates because
    /// `bytes ≤ budget` (checked by the caller): evicting every other resident frees the full budget.
    private func makeHeadroom(for bytes: UInt64, keeping capability: Capability) async {
        while !governor.canFit(bytes) {
            let candidates = residents.keys.filter { $0 != capability }
            guard let victim = candidates.min(by: { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }) else {
                break // nothing left to evict
            }
            await evictResident(victim)
        }
    }

    private func evictResident(_ capability: Capability) async {
        guard let instance = residents.removeValue(forKey: capability) else { return }
        await instance.unload()
        if let bytes = residentFootprint.removeValue(forKey: capability) {
            governor.release(bytes)
        }
        lastUsed.removeValue(forKey: capability)
    }

    private func touch(_ capability: Capability) {
        useClock &+= 1
        lastUsed[capability] = useClock
    }
}
