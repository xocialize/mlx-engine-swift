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

    /// A registered package, its init-time configuration, and the resident footprint to charge.
    private struct Entry {
        let registration: PackageRegistration
        let configuration: any PackageConfiguration
        let footprint: UInt64
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
    /// Package id → bytes charged to the governor for its resident working set.
    private var residentFootprint: [PackageID: UInt64] = [:]
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

        let footprint = governor.footprint(for: registration.manifest.requirements)
        packages[packageID] = Entry(registration: registration,
                                    configuration: configuration,
                                    footprint: footprint)
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
        return MemorySnapshot(
            budgetBytes: governor.budgetBytes,
            residentBytes: governor.residentBytes,
            availableBytes: governor.availableBytes,
            underPressure: governor.underPressure,
            residents: byCapability
        )
    }

    /// Resident packages and the bytes charged for each (the package-keyed memory view).
    public var residentPackages: [PackageID: UInt64] { residentFootprint }

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

        // Defensive re-gate — the engine constructs, never the package (C13).
        let gate = policy.evaluate(entry.registration.manifest.license)
        guard gate.isAdmitted else { throw EngineError.licenseRejected(gate) }

        // Memory admission: the working set must fit the budget; evict idle residents (LRU) to
        // make headroom. A footprint larger than the whole budget can never fit.
        let footprint = entry.footprint
        guard governor.fitsBudget(footprint) else {
            throw EngineError.exceedsMemoryBudget(required: footprint, budget: governor.budgetBytes)
        }
        await makeHeadroom(for: footprint, keeping: id)

        let instance = try entry.registration.makePackage(entry.configuration)
        // Cold-start watchdog mitigation: page the package's declared weight files into the OS cache
        // before load() issues GPU evals, so file-I/O latency never stalls a live Metal command
        // buffer. Opt-in (config conforms to WeightPrewarming) + best-effort (never fails prepare()).
        if let prewarming = entry.configuration as? WeightPrewarming {
            await WeightPrewarmer.prewarm(prewarming.prewarmPaths, label: id.description)
        }
        try await instance.load()
        // Weights are now materialized under the store root — stamp the marker the storage UI
        // counts (one per package). No-op when no store root is set.
        let manifest = entry.registration.manifest
        modelStore.writeMarker(repo: manifest.provenance.sourceRepo,
                               revision: manifest.provenance.revision,
                               capabilities: manifest.capabilities)
        residents[id] = instance
        residentFootprint[id] = footprint
        governor.charge(footprint)
        touch(id)
        return instance
    }

    /// Evict least-recently-used idle residents until `bytes` fits the headroom. Terminates because
    /// `bytes ≤ budget` (checked by the caller): evicting every other resident frees the full budget.
    private func makeHeadroom(for bytes: UInt64, keeping id: PackageID) async {
        while !governor.canFit(bytes) {
            let candidates = residents.keys.filter { $0 != id }
            guard let victim = candidates.min(by: { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }) else {
                break // nothing left to evict
            }
            await evictResident(victim)
        }
    }

    private func evictResident(_ id: PackageID) async {
        guard let instance = residents.removeValue(forKey: id) else { return }
        await instance.unload()
        if let bytes = residentFootprint.removeValue(forKey: id) {
            governor.release(bytes)
        }
        lastUsed.removeValue(forKey: id)
    }

    private func touch(_ id: PackageID) {
        useClock &+= 1
        lastUsed[id] = useClock
    }
}
