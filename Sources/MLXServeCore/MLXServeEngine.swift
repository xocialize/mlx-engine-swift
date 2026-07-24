import Foundation
import MLX
import MLXHubMetadata
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
    /// The request was governor-preempted more times than `PreemptionPolicy.maxRequeues`
    /// tolerates. `requeues` counts the preemptions suffered. The clear-error degradation of
    /// the requeue loop (V3) — the caller sees this, never a `CancellationError` it didn't cause.
    case preemptionRetryExhausted(requeues: Int)
    /// `deleteWeights(repo:)` refused: a **resident** package is loaded from that repo (MS-4).
    /// Evict it first. Registered-but-not-resident is deletable by design — the weights
    /// re-materialize on the next prepare.
    case weightsInUse(repo: String, packageID: PackageID)
    /// The store's volume can't hold what this package still has to download (MS-3): refused
    /// **before** materialization rather than failing mid-write, gigabytes in. Only raised when a
    /// size preview was actually obtainable — an unreachable hub never blocks a load.
    case insufficientDisk(required: UInt64, free: UInt64)
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
/// are evicted **LRU** until it does; as a *last resort* the governor may preempt a running
/// inference and requeue it (V3, `PreemptionPolicy` — see `run(_:package:)`). Weight **integrity**
/// is the hub client's responsibility (xet chunk hashes / ETag verification in swift-huggingface);
/// the engine verifies presence, not content. Still TODO and tracked elsewhere: `MemoryPool`
/// backend placement, `MCPBridge`.
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

    /// Engine-internal handle to one in-flight `run()` attempt — the seam the governor cancels
    /// for mid-run preemption (V3). All mutable state is engine-actor-confined; `task.cancel()`
    /// itself is thread-safe (also called from the caller-cancellation handler).
    private struct ActiveRun {
        let id: PackageID
        let task: Task<any CapabilityResponse, Error>
        /// The transient activation peak charged for the package at admission, carried on the
        /// handle so cancel-trim hygiene can't race the victim's eviction (which removes the
        /// `residentTransient` entry before the preempted attempt's catch path may run).
        let transientBytes: UInt64
        /// Set (on the engine actor) BEFORE the governor cancels `task` — the engine-internal
        /// marker that distinguishes its own preemption from the caller's cancellation. Both
        /// reach the package as the same `CancellationError`; this is how the engine tells
        /// "requeue" from "surface `.cancelled`".
        var preempted = false
        /// Latest report from the run's `RunProgress` sink — the V2 signal the preemption
        /// policy weighs before picking a mid-run victim. Advisory (hops the actor to land).
        var latestReport: RunPhaseReport?
    }

    /// Run token → in-flight run. Bookkeeping supports N entries (actor reentrancy means runs
    /// overlap at await points even though `InferenceActor` serializes the compute), but the
    /// preemption story is the serialized one: a QUEUED contender needing residency a runner
    /// holds — not concurrent runs racing.
    private var activeRuns: [UInt64: ActiveRun] = [:]
    private var runTokenClock: UInt64 = 0

    /// Admission serialization (V3): `lockAdmission`/`unlockAdmission` make each admission
    /// (headroom → construct → load → charge → run-handle registration) one critical section.
    /// Actor reentrancy would otherwise interleave two admissions at their awaits — e.g. a
    /// requeued victim re-loading into the very headroom its preemptor is mid-`load()` into
    /// (the charge lands only after `load()` returns). Runs themselves are NOT serialized by
    /// this gate — only their admission bookkeeping is.
    private var admissionLocked = false
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []

    private let policy: LicensePolicy
    /// The host profile used for the C10 eligibility check.
    public nonisolated let deviceProfile: DeviceProfile
    /// Memory budgeting + watermark policy.
    private var governor: MemoryGovernor
    /// Mid-run preemption policy (V3) — last-resort cancellation of a running inference when a
    /// queued contender can't fit after idle-LRU eviction. See `PreemptionPolicy`.
    private let preemption: PreemptionPolicy
    /// Where packages materialize weights + the marker the storage UI counts. Empty by default
    /// (packages use their own cache); a consuming app sets it once via `useModelStore`.
    private var modelStore: ModelStore = ModelStore()
    /// Real-memory reading for the R-MEM-1 pressure trigger (`phys_footprint`). Injectable so tests
    /// can drive admission with a controlled footprint; defaults to the live host reading.
    private let physFootprint: @Sendable () -> UInt64?
    /// Metadata-only hub client used to size a pending materialization (MS-3). Injectable so tests
    /// (and offline consumers) never touch the network.
    private let hubMetadata: any HubMetadataProviding
    /// The engine-executed materializer (contract 1.24): downloads a `WeightSourcing`
    /// configuration's missing sources into the store before `load()`. Injectable so tests
    /// exercise the pre-load hook without a network; defaults to the live `WeightMaterializer`
    /// sharing `hubMetadata` for enumeration.
    private let materializer: any WeightMaterializing
    /// Whether `resident()` refuses a load whose pending download can't fit the store volume.
    /// On by default; the escape hatch exists for hosts that manage disk themselves.
    public var diskPrecheckEnabled: Bool

    /// Observable preparation progress per capability/package (registering → prewarming → downloading
    /// → loading → ready/failed). A consuming app binds `MLXEngineUI.ModelStateView` to this to show a
    /// consistent download/first-load affordance. Updated as `prepare()`/`resident()` runs.
    public nonisolated let preparation = PreparationMonitor()

    /// Observable run-time phase progress per capability/package (contract 1.18.0, ENGINE-NEEDS V2):
    /// the latest `RunPhaseReport` a package reported from inside `run()` (encode → denoise →
    /// upsample → decode, with step counts), or `nil` when no run is in flight. The run-time sibling
    /// of `preparation` — a consuming app binds its generation UI to this for a real phase seam
    /// instead of one indeterminate "Generating…".
    public nonisolated let runProgress = RunMonitor()

    /// GPU buffer-pool policy (N5). Applied once here; see `GPUCacheConfiguration` for the
    /// precedence rules against hosts that write `MLX.Memory.cacheLimit` themselves.
    private let gpuCache: GPUCacheConfiguration
    /// The cap init actually wrote, or nil when the policy was `.unmanaged` OR the write
    /// failed because this process can't initialize MLX's Metal device (see init).
    public private(set) var appliedGPUCacheLimitBytes: UInt64?
    /// Every unregistered `Specialty` seen at `register()` (C6 governance, warn-only). Diagnostic:
    /// a host can surface it, and the fleet sweep reads it to know what to add to
    /// `Specialty.registeredVocabulary`.
    public private(set) var unregisteredSpecialties: Set<Specialty> = []
    /// `run`s (returned or thrown) since the last `trimEveryRuns` trim.
    private var runsSinceTrim = 0
    /// Engine-policy pool trims performed so far (`trimEveryRuns` / `trimAfterEvict` / cancel
    /// hygiene). Internal observability: offline tests prove the trim accounting fires through
    /// this counter, because the `clearCache()` itself is best-effort in a process without
    /// MLX's Metal device.
    private(set) var policyTrimCount = 0

    public init(policy: LicensePolicy = .permissiveOnly,
                device: DeviceProfile = .current(),
                governor: MemoryGovernor? = nil,
                gpuCache: GPUCacheConfiguration = GPUCacheConfiguration(),
                preemption: PreemptionPolicy = PreemptionPolicy(),
                physFootprint: @Sendable @escaping () -> UInt64? = HostMemory.physFootprint,
                hubMetadata: any HubMetadataProviding = HubMetadataClient(),
                materializer: (any WeightMaterializing)? = nil,
                diskPrecheckEnabled: Bool = true) {
        self.policy = policy
        self.deviceProfile = device
        self.governor = governor ?? .forDevice(device)
        self.gpuCache = gpuCache
        self.preemption = preemption
        self.physFootprint = physFootprint
        self.hubMetadata = hubMetadata
        self.materializer = materializer ?? WeightMaterializer(listing: hubMetadata)
        self.diskPrecheckEnabled = diskPrecheckEnabled
        // Bound MLX's process-global buffer-recycling pool NOW (before any package loads or
        // runs) so interactive consumers stop ratcheting phys_footprint by GBs per turn
        // (ENGINE-NEEDS N5). `.unmanaged` resolves to nil and leaves the global untouched.
        //
        // BEST-EFFORT: the first allocator call initializes MLX's Metal device, which can
        // fail in processes that can't load the bundled metallib (the known SPM `swift test`
        // runner gap — engines are constructed in every package's offline admissibility
        // tests). `withError` scopes that to a caught throw instead of the default aborting
        // handler; a process where this fails cannot run GPU work anyway, so degrading to
        // "unmanaged" there is exact, not lossy. `appliedGPUCacheLimitBytes` records the
        // outcome for diagnostics.
        if let cap = gpuCache.resolvedLimitBytes(budgetBytes: self.governor.budgetBytes) {
            let clamped = cap > UInt64(Int.max) ? Int.max : Int(cap)
            let applied = (try? MLX.withError { Memory.cacheLimit = clamped }) != nil
            self.appliedGPUCacheLimitBytes = applied ? cap : nil
        } else {
            self.appliedGPUCacheLimitBytes = nil
        }
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

        // C6 vocabulary governance (3.5): a `Specialty` is a string literal, so an unregistered
        // term silently forks the namespace ("line-art" vs "lineart") and quietly breaks
        // Model-Manager ranking. WARN, never reject — a hard rejection would break unknown
        // third-party conformers with no deprecation window (promotion to rejection is a
        // next-major decision).
        let unregistered = registration.manifest.specialties.map(\.specialty).filter { !$0.isRegistered }
        if !unregistered.isEmpty {
            unregisteredSpecialties.formUnion(unregistered)
            print("[Specialty] \(registration.manifest.provenance.sourceRepo) declares unregistered "
                  + "specialt\(unregistered.count == 1 ? "y" : "ies"): "
                  + unregistered.map(\.rawValue).sorted().joined(separator: ", ")
                  + " — add to Specialty.registeredVocabulary or use an existing term.")
        }

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
        // Per-surface quant eligibility (3.2): a surface declaring a `quantFloor` above the
        // configuration's selected quant is NOT backed by this registration — while the package's
        // other surfaces still are. `nil` floor (every existing conformer) admits everything.
        let selectedQuant = (configuration as? QuantConfigured)?.quant
        let admittedCapabilities = registration.manifest.surfaces
            .filter { Self.meetsSurfaceFloor($0, quant: selectedQuant) }
            .map(\.capability)
        guard !admittedCapabilities.isEmpty else {
            let surface = registration.manifest.surfaces[0]
            throw EngineError.ineligible(.quantBelowSurfaceFloor(
                capability: surface.capability,
                required: surface.quantFloor ?? .fp32,
                selected: selectedQuant ?? .int4))
        }

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
        for capability in admittedCapabilities {
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

    /// Does a surface's declared `quantFloor` admit this configuration's quant? `nil` floor always
    /// admits; a config with no declared quant (`QuantConfigured` not adopted) can't be judged, so
    /// it admits too — the floor is a declaration-vs-declaration check, never a guess.
    static func meetsSurfaceFloor(_ surface: ToolDescriptor, quant: Quant?) -> Bool {
        guard let floor = surface.quantFloor, let quant else { return true }
        return quant.meets(floor: floor)
    }

    /// Per-surface admissibility (3.2): the config-aware verdict for ONE capability of a package.
    ///
    /// Identical to `admissibility(for:configuration:)` except that a surface whose declared
    /// `ToolDescriptor.quantFloor` outranks the configuration's quant reports
    /// `.quantBelowSurfaceFloor` — the seam a Model Manager uses to see that an int4 config backs a
    /// package's analysis surface but not its generation surface.
    public func admissibility(for manifest: PackageManifest,
                              configuration: any PackageConfiguration,
                              capability: Capability) -> Admissibility {
        let base = admissibility(for: manifest.requirements, configuration: configuration)
        let quant = (configuration as? QuantConfigured)?.quant
        guard let surface = manifest.surfaces.first(where: { $0.capability == capability }),
              let floor = surface.quantFloor, let quant, !quant.meets(floor: floor)
        else { return base }
        return Admissibility(
            eligibility: .quantBelowSurfaceFloor(capability: capability, required: floor,
                                                 selected: quant),
            footprint: base.footprint,
            fitsBudget: base.fitsBudget,
            fitsAvailable: base.fitsAvailable)
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
    ///
    /// **Two cancellation lanes** (V3, run-lifecycle program — the `ModelPackage.run` contract
    /// made real):
    /// - **User cancel** — the sanctioned app seam is *cancelling the `Task` that wraps this
    ///   call*. The engine forwards that cancellation into the run (structured propagation via
    ///   a cancellation handler on the engine-scoped run task), the package's cooperative
    ///   checkpoints throw, and the `CancellationError` surfaces to the caller **unchanged**
    ///   (classify it `.cancelled`, not failed).
    /// - **Governor preemption** — when a queued contender can't fit after idle-LRU eviction,
    ///   the governor may cancel this run as a *last resort* (see `PreemptionPolicy`). The
    ///   engine marks the run-handle preempted *before* cancelling, so the same
    ///   `CancellationError` is recognized as its own doing and the request is **requeued**
    ///   through normal admission — the caller keeps awaiting and eventually gets a genuine
    ///   response. Repeated preemption is bounded by `PreemptionPolicy.maxRequeues`, degrading
    ///   to `EngineError.preemptionRetryExhausted`. If the caller cancels *while* a preemption
    ///   is in flight, the user lane wins: `CancellationError` surfaces, nothing requeues.
    ///   A requeued attempt never preempts others — it waits — so two requests can't
    ///   preempt-ping-pong.
    ///
    /// **Pool hygiene runs on every outcome of every attempt** (V1): a run that throws — a user
    /// cancel, a governor preemption, or a genuine failure — has already churned the GPU buffer
    /// pool, so it still counts toward `trimEveryRuns`; a cancelled/preempted run whose package
    /// declares a large transient peak additionally trims the pool right now
    /// (`GPUCacheConfiguration.trimAfterCancelBytes` — the LTX-scale multi-GB mid-denoise
    /// abandonment case). A thrown run also still `touch`es LRU recency — deliberate: its
    /// weights are hot and the measured post-cancel pattern is an immediate re-run (the LTX
    /// cancel→re-run recovery). Genuine errors propagate to the caller unchanged.
    public func run(_ request: any CapabilityRequest,
                    package: PackageID? = nil) async throws -> any CapabilityResponse {
        let capability = request.capability
        let id = try resolve(capability, package)
        var requeues = 0
        while true {
            // A user cancel that lands between attempts (e.g. during a requeue wait, where the
            // in-flight awaits are not cancellation-responsive) surfaces here, at the next
            // admission boundary.
            try Task.checkCancellation()
            let conduct: AdmissionConduct = !preemption.enabled ? .idleOnly
                : (requeues == 0 ? .preempting : .waiting)
            switch try await runAttempt(request, id: id, capability: capability, conduct: conduct) {
            case .response(let response):
                return response
            case .preempted:
                requeues += 1
                guard requeues <= preemption.maxRequeues else {
                    throw EngineError.preemptionRetryExhausted(requeues: requeues)
                }
                // Queue behavior on requeue: let the in-flight runs (including the admission
                // that preempted us) finish before re-admitting, rather than contending for
                // residency they hold.
                await drainActiveRuns()
            }
        }
    }

    /// How an admission may claim headroom beyond idle-LRU eviction (V3).
    private enum AdmissionConduct {
        /// v1 semantics: evict idle residents only; never touch a running inference
        /// (`prepare`, and all admissions when `PreemptionPolicy.enabled == false`).
        case idleOnly
        /// May preempt a running victim as a last resort (a request's FIRST attempt).
        case preempting
        /// May wait for a running victim to finish and then evict it, but never cancels it
        /// (REQUEUED attempts — structurally prevents preemption ping-pong).
        case waiting
    }

    private enum RunAttemptOutcome {
        case response(any CapabilityResponse)
        case preempted
    }

    /// One admission + execution attempt. Admission (residency + run-handle registration) runs
    /// inside the admission gate; the package's `run()` executes in an engine-scoped task — the
    /// run-handle the governor can cancel — while a cancellation handler keeps the caller's own
    /// cancellation structurally propagating into it.
    private func runAttempt(_ request: any CapabilityRequest,
                            id: PackageID,
                            capability: Capability,
                            conduct: AdmissionConduct) async throws -> RunAttemptOutcome {
        await lockAdmission()
        let instance: any ModelPackage
        do {
            instance = try await resident(id, conduct: conduct)
        } catch {
            unlockAdmission()
            throw error
        }

        // Bind the ambient run-progress sink around the package's run() — the run-time mirror
        // of the WeightDownloadProgress binding in resident() (V2). Reports land on the
        // observable `runProgress` monitor AND on the run-handle (the governor's preemption-
        // policy signal). Task-local, so the binding scopes to exactly this attempt; cleared on
        // EVERY exit (return, throw, cancel): no run in flight must read as nil.
        let pkg = id.description
        runTokenClock &+= 1
        let token = runTokenClock
        let sink: RunProgress.Sink = { [runProgress] report in
            Task { @MainActor in
                runProgress.update(capability, package: pkg, to: report)
            }
            Task { await self.noteRunProgress(token: token, report: report) }
        }
        let task = Task {
            try await RunProgress.$sink.withValue(sink) {
                try await instance.run(request)
            }
        }
        activeRuns[token] = ActiveRun(id: id, task: task,
                                      transientBytes: residentTransient[id] ?? 0)
        unlockAdmission()

        defer {
            activeRuns[token] = nil
            Task { @MainActor [runProgress] in
                runProgress.clear(capability, package: pkg)
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel() // the user lane: caller's Task cancel → the run-handle
            }
            touch(id) // mark recently used after a completed run
            noteRunForTrimPolicy()
            return .response(response)
        } catch {
            touch(id) // hot weights + likely re-run — keep the package most-recently-used
            noteRunForTrimPolicy()
            if error is CancellationError {
                noteCancelledRun(transientBytes: activeRuns[token]?.transientBytes ?? 0)
                // Engine-initiated AND the caller still wants the result → requeue. If the
                // caller cancelled too (or instead), the user lane wins and `.cancelled`
                // surfaces below.
                if activeRuns[token]?.preempted == true, !Task.isCancelled {
                    return .preempted
                }
            }
            throw error
        }
    }

    /// Record a run's latest phase report on its handle (the preemption-policy signal).
    private func noteRunProgress(token: UInt64, report: RunPhaseReport) {
        activeRuns[token]?.latestReport = report
    }

    /// Internal observability for offline tests: the latest phase report an in-flight run of
    /// `id` has delivered to the preemption policy (nil = no active run, or no report landed).
    func activeRunLatestReport(for id: PackageID) -> RunPhaseReport? {
        activeRuns.values.first { $0.id == id }?.latestReport
    }

    /// Await completion of every currently in-flight run (snapshot; runs started later are not
    /// waited). Cheap when nothing is running.
    private func drainActiveRuns() async {
        for run in activeRuns.values {
            _ = try? await run.task.value
        }
    }

    // MARK: - Admission gate (V3)

    /// Acquire the admission critical section. FIFO-ish: each `unlockAdmission` wakes one
    /// waiter, which re-checks and claims the gate.
    private func lockAdmission() async {
        while admissionLocked {
            await withCheckedContinuation { admissionWaiters.append($0) }
        }
        admissionLocked = true
    }

    private func unlockAdmission() {
        admissionLocked = false
        if !admissionWaiters.isEmpty { admissionWaiters.removeFirst().resume() }
    }

    /// The `trimEveryRuns` knob: drop the buffer pool after every N runs (returned or thrown).
    private func noteRunForTrimPolicy() {
        guard let every = gpuCache.trimEveryRuns, every > 0 else { return }
        runsSinceTrim += 1
        if runsSinceTrim >= every {
            runsSinceTrim = 0
            performPolicyTrim()
        }
    }

    /// The `trimAfterCancelBytes` knob: a cancelled run abandoned its in-flight activations
    /// into the pool, so when the package's resolved transient peak says those are big,
    /// return them to the OS now rather than waiting for the next managed-limit rollover.
    /// Takes the bytes (carried on the run-handle) rather than a package id: on the preempt
    /// path the victim's `residentTransient` entry is already gone by eviction time.
    private func noteCancelledRun(transientBytes: UInt64) {
        guard let threshold = gpuCache.trimAfterCancelBytes,
              transientBytes >= threshold else { return }
        performPolicyTrim()
    }

    /// One engine-policy pool trim: count it (offline-test observable), then best-effort drop
    /// the pool (no-op in a process that can't initialize MLX's Metal device).
    private func performPolicyTrim() {
        policyTrimCount += 1
        try? MLX.withError { Memory.clearCache() }
    }

    /// Ensure the package for a capability is constructed + loaded, returning it. Warms a model
    /// (and applies memory admission) before the first `run`. Prepare never preempts a running
    /// inference — warming is not worth throwing away in-flight work (v1 idle-LRU semantics).
    @discardableResult
    public func prepare(_ capability: Capability,
                        package: PackageID? = nil) async throws -> any ModelPackage {
        let id = try resolve(capability, package)
        await lockAdmission()
        defer { unlockAdmission() }
        return try await resident(id)
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

    private func resident(_ id: PackageID,
                          conduct: AdmissionConduct = .idleOnly) async throws -> any ModelPackage {
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
            await makeHeadroom(persistent: persistent, transient: transient, keeping: id,
                               conduct: conduct)

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
            // Disk admission (MS-3), the storage-side sibling of the memory check above: refuse a
            // load whose pending download can't fit the store volume, instead of discovering it
            // gigabytes into the write. Skipped silently whenever the size isn't knowable.
            try await assertDiskFits(entry)

            // Ambient download-progress sink: bound around the engine's own materialization pass
            // below AND around load(), so both the engine executor and a package that forwards its
            // native downloader's progress surface a real `.downloading` fraction.
            let sink: WeightDownloadProgress.Sink = { [preparation] fraction, bps in
                Task { @MainActor in
                    for cap in caps {
                        preparation.update(cap, package: pkg,
                                           to: .downloading(fraction: fraction, bytesPerSecond: bps))
                    }
                }
            }

            // Engine-executed materialization (contract 1.24): download the declared-but-missing
            // sources into the store BEFORE the package is constructed, so `load()` just loads.
            // `SelfMaterializing` configurations keep executing their own downloads (non-HF hosts,
            // wrappers whose runtime fetches internally); packages that still self-materialize
            // defensively stay correct — their own missing-check finds nothing left. No store
            // root ⇒ nothing the engine can execute into; the package falls back to its cache.
            if let root = modelStore.root,
               let sourcing = configuration as? WeightSourcing,
               !(configuration is SelfMaterializing) {
                let missing = sourcing.missingWeightSources(storeRoot: root)
                if !missing.isEmpty {
                    await updatePhase(.downloading(fraction: 0, bytesPerSecond: nil),
                                      caps: caps, package: pkg)
                    try await WeightDownloadProgress.$sink.withValue(sink) {
                        try await materializer.materialize(missing, into: root)
                    }
                }
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

            // Keep the sink bound around load() too: a `SelfMaterializing` package (or one still
            // shipping its own executor) forwards its downloader's progress from inside load().
            await updatePhase(.loading, caps: caps, package: pkg)
            try await WeightDownloadProgress.$sink.withValue(sink) {
                try await instance.load()
            }

            // Weights are now materialized under the store root — stamp the marker(s) the storage
            // UI counts. Declared `WeightSource`s first (the precise signal — a variant-multiplexed
            // package materializes under repos its static provenance never names, so a provenance
            // marker would credit the wrong row), then the manifest's provenance repo for packages
            // that declare no sources. Mirrors `residentHolder(of:)`. No-op when no store root is set.
            if let sourcing = configuration as? WeightSourcing, !sourcing.weightSources.isEmpty {
                for source in sourcing.weightSources {
                    modelStore.writeMarker(repo: source.repo,
                                           revision: source.revision ?? "main",
                                           capabilities: manifest.capabilities)
                }
            } else {
                modelStore.writeMarker(repo: manifest.provenance.sourceRepo,
                                       revision: manifest.provenance.revision,
                                       capabilities: manifest.capabilities)
            }
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
    /// Bundled-only packages (`BundledWeightSourcing`, no `WeightSourcing`) read `false` as soon as
    /// their vendored sources resolve — they can never need the network. Otherwise, heuristic: if the
    /// configuration declares local weight paths (`WeightPrewarming`) and they all exist → no
    /// download. If it declares its network sources (`WeightSourcing`) → the MS-2 missing-set probe
    /// decides (the precise signal — a variant-multiplexed package materializes under repos its
    /// static provenance never names, and this is the same set the install markers are stamped
    /// for). Otherwise → needs download when the per-package install marker is absent under the
    /// current store root (the same signal the storage UI counts).
    public func needsDownload(_ capability: Capability, package: PackageID? = nil) -> Bool {
        guard let id = try? resolve(capability, package), let entry = packages[id] else { return false }
        if let bundled = entry.configuration as? BundledWeightSourcing,
           !(entry.configuration is WeightSourcing) {   // hybrids fall through to the network heuristics
            let sources = bundled.bundledWeightSources
            if !sources.isEmpty, sources.allSatisfy({ source in
                source.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }) {
                return false
            }
        }
        if let prewarming = entry.configuration as? WeightPrewarming {
            let paths = prewarming.prewarmPaths
            if !paths.isEmpty,
               paths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return false
            }
        }
        // Declared sources beat the provenance marker: probe them directly (an override honoring
        // an explicit local-path escape hatch can clear this even without a store root).
        if let sourcing = entry.configuration as? WeightSourcing, !sourcing.weightSources.isEmpty {
            return !sourcing.missingWeightSources(storeRoot: modelStore.root).isEmpty
        }
        let repo = entry.registration.manifest.provenance.sourceRepo
        guard modelStore.root != nil else { return true }
        return !modelStore.hasMarker(for: repo)
    }

    /// What this capability's package would still have to download, and whether the store volume
    /// can take it (MS-3) — the "needs 34 GB, 41 GB free" affordance, computed **before** any
    /// package code runs.
    ///
    /// Sizes only the sources the MS-2 probe reports **missing**: an already-materialized source
    /// costs nothing. Returns `nil` when the capability resolves to no package or its configuration
    /// declares no `WeightSourcing` (nothing to preview). Degrades honestly when the hub is
    /// unreachable — unknown sizes, `fits == nil`, never a refusal.
    public func materializationPreview(_ capability: Capability,
                                       package: PackageID? = nil) async -> MaterializationPreview? {
        guard let id = try? resolve(capability, package), let entry = packages[id],
              let sourcing = entry.configuration as? WeightSourcing else { return nil }
        return await MaterializationPreview.make(
            missing: sourcing.missingWeightSources(storeRoot: modelStore.root),
            storeRoot: modelStore.root,
            provider: hubMetadata)
    }

    /// The `resident()` precheck: throw rather than let a downloader fail mid-write, but ONLY on a
    /// preview we could actually obtain (known total, known free, and it doesn't fit). Unknown
    /// sizes — offline, private repo, no store root — proceed exactly as before.
    private func assertDiskFits(_ entry: Entry) async throws {
        guard diskPrecheckEnabled, modelStore.root != nil,
              let sourcing = entry.configuration as? WeightSourcing else { return }
        let missing = sourcing.missingWeightSources(storeRoot: modelStore.root)
        guard !missing.isEmpty else { return }
        let preview = await MaterializationPreview.make(missing: missing,
                                                        storeRoot: modelStore.root,
                                                        provider: hubMetadata)
        guard let required = preview.totalBytes, let free = preview.freeBytes,
              required > free else { return }
        throw EngineError.insufficientDisk(required: required, free: free)
    }

    /// Delete a repo's weights from the model store (MS-4) — the disk-side sibling of `evict`.
    ///
    /// Refuses while a **resident** package draws on that repo (declared `WeightSource`, or its
    /// manifest provenance for packages that don't declare sources): unloading is the caller's
    /// decision, and pulling files out from under a loaded package is not the engine's to do.
    /// Registered-but-not-resident IS deletable — the weights re-materialize on the next prepare,
    /// which is the design, not a hazard.
    ///
    /// - Throws: `.weightsInUse` when a resident holds the repo; `FileManager`'s error on a real
    ///   deletion failure. Deleting an unmaterialized repo is a no-op.
    public func deleteWeights(repo: String) throws {
        if let holder = residentHolder(of: repo) {
            throw EngineError.weightsInUse(repo: repo, packageID: holder)
        }
        try modelStore.remove(repo: repo)
    }

    /// The first resident package drawing on `repo`, or nil. Declared `WeightSource`s first (the
    /// precise signal — a multi-source package holds repos its provenance never names), then the
    /// manifest's provenance repo for packages that declare no sources.
    private func residentHolder(of repo: String) -> PackageID? {
        for id in residents.keys {
            guard let entry = packages[id] else { continue }
            if let sourcing = entry.configuration as? WeightSourcing {
                if sourcing.weightSources.contains(where: { $0.repo == repo }) { return id }
            } else if entry.registration.manifest.provenance.sourceRepo == repo {
                return id
            }
        }
        return nil
    }

    /// Evict least-recently-used idle residents until the incoming model's accounting fits the budget.
    /// Terminates because the caller has checked `persistent + transient ≤ budget`: evicting every other
    /// resident frees the full budget.
    ///
    /// Passes, cheapest lever first:
    /// (1) **Declared-byte** headroom under the serialized-inference accounting (Σ persistent
    /// weights + one max transient): evict **idle** LRU residents — a package with a run in
    /// flight is never idle (V3 closed the v1 hazard where a long run's stale `lastUsed` tick
    /// made it the LRU "idle" victim and it was unloaded mid-inference). When idle eviction
    /// isn't enough and `conduct` allows, reclaim from a RUNNING victim as a **last resort**:
    /// `.preempting` cancels it (unless its V2 progress reads nearly done, in which case it is
    /// waited for); `.waiting` (requeued admissions) only ever waits. Either way the victim's
    /// run ends before its weights are evicted and the contender loads — the preempted
    /// request's own `run()` requeues it (see `runAttempt`).
    /// (2) **R-MEM-1 real-pressure** — declared `QuantFootprint` bytes are a *floor*, so even
    /// when the declared sum fits, the process's *actual* `phys_footprint` may be over the
    /// governor's high-watermark (activations/scratch the declarations omit). In that case evict
    /// idle LRU residents until real pressure clears or none remain. Conservative and bounded:
    /// it only reclaims our own idle residents (never the incoming `id`), and stops when
    /// nothing's left to evict, so external (non-engine) memory pressure can't loop. Degrades to
    /// the declared-byte pass when no host reading is available.
    private func makeHeadroom(persistent p: UInt64, transient t: UInt64, keeping id: PackageID,
                              conduct: AdmissionConduct = .idleOnly) async {
        // (1) Declared-byte headroom under the serialized-inference accounting (Σ persistent + one
        // max transient). Idle LRU first; a running victim only as a last resort.
        while accountedRequired(persistent: p, transient: t, excluding: id) > governor.budgetBytes {
            if let victim = lruIdleVictim(excluding: id) {
                await evictResident(victim)
                continue
            }
            guard conduct != .idleOnly, let token = activeVictimToken(excluding: id) else {
                break // nothing left to evict (or reclaim)
            }
            await reclaimActiveRun(token, conduct: conduct)
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

    /// The least-recently-used **idle** resident other than `id`, or nil if none remain.
    /// A package with a run in flight is not idle — it is never an LRU victim (V3).
    private func lruIdleVictim(excluding id: PackageID) -> PackageID? {
        let running = Set(activeRuns.values.map(\.id))
        return residents.keys
            .filter { $0 != id && !running.contains($0) }
            .min(by: { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) })
    }

    /// The in-flight run whose eviction the governor should consider next: backs a resident
    /// package other than the contender's, lowest reported progress first (an unreported run
    /// reads as fraction 0 — nothing measurable to preserve).
    private func activeVictimToken(excluding id: PackageID) -> UInt64? {
        activeRuns
            .filter { $0.value.id != id && residents[$0.value.id] != nil }
            .min(by: { progressFraction($0.value) < progressFraction($1.value) })?
            .key
    }

    /// The V2 progress signal as a fraction: `step/totalSteps` of the run's latest report,
    /// 0 when unknown. Deliberately coarse — a denoise step 90/100 with decode still ahead
    /// reads as 0.9; good enough for "don't throw away minutes of GPU work".
    private func progressFraction(_ run: ActiveRun) -> Double {
        guard let report = run.latestReport,
              let step = report.step, let total = report.totalSteps, total > 0 else { return 0 }
        return Double(step) / Double(total)
    }

    /// Last-resort reclaim of a running victim's residency. `.preempting` cancels it first —
    /// marking the handle so the victim's own `run()` recognizes the engine's doing and
    /// requeues — unless its progress reads at/past the nearly-done threshold, where waiting
    /// preserves the work. `.waiting` never cancels. Either way the run ends before its weights
    /// are evicted. The handle stays in `activeRuns` (the victim's catch path still reads its
    /// `preempted` marker; the victim's own `runAttempt` defer removes it) — eviction makes the
    /// package non-resident, which is what disqualifies it from being picked again.
    private func reclaimActiveRun(_ token: UInt64, conduct: AdmissionConduct) async {
        guard let run = activeRuns[token] else { return }
        if conduct == .preempting,
           progressFraction(run) < preemption.preserveNearlyDoneFraction {
            activeRuns[token]?.preempted = true
            run.task.cancel()
        }
        _ = try? await run.task.value // prompt if cancelled; else runs to completion
        await evictResident(run.id)
    }

    private func evictResident(_ id: PackageID) async {
        guard let instance = residents.removeValue(forKey: id) else { return }
        await instance.unload()
        if let bytes = residentFootprint.removeValue(forKey: id) {
            governor.release(bytes)
        }
        residentTransient.removeValue(forKey: id)
        lastUsed.removeValue(forKey: id)
        // Belt-and-braces on top of the package's own unload()-time clearCache: with the
        // knob on, eviction also returns pooled transients to the OS immediately.
        if gpuCache.trimAfterEvict {
            performPolicyTrim()
        }
    }

    private func touch(_ id: PackageID) {
        useClock &+= 1
        lastUsed[id] = useClock
    }

    // MARK: - GPU buffer-pool policy (N5)

    /// Drop MLX's buffer-recycling pool now, returning pooled (unreferenced) GPU memory to
    /// the OS. The explicit "after a burst of work" hook — mirrors what
    /// `MLXEngineTestKit.ValidationRun` does between measurement phases. Live tensors
    /// (`GPUPoolSnapshot.activeBytes`) are unaffected. Process-global and cheap; `nonisolated`
    /// so hosts can call it from any context without hopping the actor. Best-effort no-op in
    /// a process that can't initialize MLX's Metal device.
    public nonisolated func trimCaches() {
        try? MLX.withError { Memory.clearCache() }
    }

    /// A point-in-time reading of MLX's GPU buffer accounting (active / cache / peak / the
    /// effective cache limit) so consumers get pool observability without importing MLX.
    /// Process-global — one MLX pool per process, whichever engine reads it. `nil` when the
    /// process can't initialize MLX's Metal device (some CI/test runners) — a process where
    /// this is nil has no pool to observe.
    public nonisolated func gpuPoolSnapshot() -> GPUPoolSnapshot? {
        GPUPoolSnapshot.current()
    }

    /// The GPU cache policy this engine was constructed with (the *configured* intent;
    /// `gpuPoolSnapshot().cacheLimitBytes` is the *effective* process-global value, which a
    /// later host write may have changed — last-write-wins).
    public nonisolated var gpuCachePolicy: GPUCacheConfiguration { gpuCache }
}
