import Foundation

/// A memory ceiling assigned to an engine from OUTSIDE its process (contract 1.57.0, AB-A-0206
/// item 5).
///
/// An engine sizes itself against the whole machine by default: the governor budgets Metal's
/// recommended working set, the GPU pool caps at a share of that, and the wired ceiling leaves an
/// OS reserve. A host that runs each model in a worker process of its own (Gaea) schedules memory
/// ACROSS processes, so each worker must live inside the slice the host gave it instead.
/// `MLXServeEngine(workerBudget:)` derives all three limits from this value. `Codable`, so a host
/// passes it to a worker on the wire; MLX-free, so the host needs no MLX to build one.
public struct WorkerBudget: Sendable, Codable, Equatable {
    /// The ceiling, in bytes, for everything the worker's engine holds: persistent weights plus
    /// the one transient reserve. The governor admits against it; the wired ceiling is it.
    public let ceilingBytes: UInt64
    /// The MLX buffer-pool cap. `nil` (default) = the engine's automatic rule against the
    /// ceiling, `min(2 GB, 5% of ceiling)`; `0` disables buffer recycling.
    public let cacheLimitBytes: UInt64?
    /// Coordinate the wired limit up to `ceilingBytes` while a run is active (default). `false`
    /// leaves MLX's wired limit untouched.
    public let wiresWeights: Bool

    public init(ceilingBytes: UInt64, cacheLimitBytes: UInt64? = nil, wiresWeights: Bool = true) {
        self.ceilingBytes = ceilingBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.wiresWeights = wiresWeights
    }
}

/// What a worker's engine holds right now, reported back to the host that assigned its budget
/// (contract 1.57.0, AB-A-0206 item 5). `MLXServeEngine.workerMemoryReport()`.
///
/// `residentBytes` and `transientReserveBytes` are the DECLARED charge (what the governor
/// accounts); `physFootprintBytes` is the process's measured `phys_footprint`, the same number a
/// host reads from outside with `proc_pid_rusage`. A host comparing the two sees a package whose
/// declaration under-reads.
public struct WorkerMemoryReport: Sendable, Codable, Equatable {
    /// The governor's budget — the `WorkerBudget` ceiling for a worker engine.
    public let budgetBytes: UInt64
    /// Σ persistent weights of the resident packages.
    public let residentBytes: UInt64
    /// The single transient activation reserve the governor holds (max over residents, and the
    /// running request's per-run reserve when larger).
    public let transientReserveBytes: UInt64
    /// `budgetBytes` minus everything accounted.
    public let availableBytes: UInt64
    /// The process's `phys_footprint`, when the host syscall answered.
    public let physFootprintBytes: UInt64?
    /// MLX's active and pooled GPU bytes, when MLX's Metal device is up.
    public let gpuActiveBytes: UInt64?
    public let gpuCacheBytes: UInt64?
    /// Each resident package's persistent charge, by package id.
    public let residents: [String: UInt64]
    /// Package ids with a run in flight.
    public let running: [String]
    public let date: Date

    public init(budgetBytes: UInt64, residentBytes: UInt64, transientReserveBytes: UInt64,
                availableBytes: UInt64, physFootprintBytes: UInt64?, gpuActiveBytes: UInt64?,
                gpuCacheBytes: UInt64?, residents: [String: UInt64], running: [String],
                date: Date = Date()) {
        self.budgetBytes = budgetBytes
        self.residentBytes = residentBytes
        self.transientReserveBytes = transientReserveBytes
        self.availableBytes = availableBytes
        self.physFootprintBytes = physFootprintBytes
        self.gpuActiveBytes = gpuActiveBytes
        self.gpuCacheBytes = gpuCacheBytes
        self.residents = residents
        self.running = running
        self.date = date
    }
}

/// What `MLXServeEngine.materialize(package:)` did (contract 1.57.0, AB-A-0206 item 2): the
/// download-only half of `prepare`, so a host can fetch a model on the operator's command and load
/// it only when a job needs it.
public struct MaterializationReport: Sendable, Codable, Equatable {
    public let packageID: String
    /// The store the weights are in (`ModelStore.root`).
    public let storeRoot: URL?
    /// Who materializes this package's weights. `.engine` is the only kind `materialize` fetches;
    /// `.bundled` returns at once with nothing to do.
    public let materialization: ResolvedLane.Materialization
    /// Sources that were missing and are now on disk.
    public let downloaded: [WeightSource]
    /// Sources that were already on disk.
    public let alreadyPresent: [WeightSource]

    public init(packageID: String, storeRoot: URL?, materialization: ResolvedLane.Materialization,
                downloaded: [WeightSource], alreadyPresent: [WeightSource]) {
        self.packageID = packageID
        self.storeRoot = storeRoot
        self.materialization = materialization
        self.downloaded = downloaded
        self.alreadyPresent = alreadyPresent
    }
}
