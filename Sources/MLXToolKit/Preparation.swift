import Foundation
import Synchronization

/// The lifecycle phase of a `prepare()` (register → materialize weights → page in → run-ready), surfaced
/// so a consuming app can present a consistent "downloading weights / first load is heavy" affordance
/// instead of an indeterminate spinner. Observed via `MLXServeEngine.preparation` (a `PreparationMonitor`).
public enum PreparePhase: Sendable, Equatable {
    /// Not yet prepared (or evicted). The default for any capability the monitor hasn't seen.
    case idle
    /// Admission + construction (license/eligibility/memory gate, package init).
    case registering
    /// Paging already-present weights into the OS cache before load (cold-start prewarm). `fraction`
    /// is bytes-read / bytes-total over the prewarm set ([0, 1]).
    case prewarming(fraction: Double)
    /// Materializing weights from the network. `fraction` is [0, 1]; `bytesPerSecond` is the current
    /// download speed when the downloader reports it.
    case downloading(fraction: Double, bytesPerSecond: Double?)
    /// Weights present; building the working set on the GPU.
    case loading
    /// Resident and ready to run.
    case ready
    /// Preparation failed; carries a human-readable reason.
    case failed(String)
}

/// Identity for a phase-monitor entry (shared by `PreparationMonitor` and `RunMonitor`): a
/// capability, optionally narrowed to a specific backing package (when several packages back
/// one capability). `packageID` is the package's string id.
public struct PreparationKey: Hashable, Sendable, Codable {
    public let capability: Capability
    public let packageID: String?
    public init(capability: Capability, packageID: String? = nil) {
        self.capability = capability
        self.packageID = packageID
    }
}

/// Observable, engine-owned record of the current `PreparePhase` per capability/package. SwiftUI views
/// (see `MLXEngineUI.ModelStateView`) bind to it directly; the engine updates it as `prepare()` runs.
/// `@MainActor` so reads/writes are UI-safe; the engine hops here via `await`.
@MainActor
@Observable
public final class PreparationMonitor {
    public private(set) var phases: [PreparationKey: PreparePhase] = [:]

    public nonisolated init() {}

    /// Current phase for a capability (optionally a specific package). Falls back to the
    /// capability-wide entry, then `.idle`.
    public func phase(for capability: Capability, package: String? = nil) -> PreparePhase {
        if let package, let p = phases[PreparationKey(capability: capability, packageID: package)] {
            return p
        }
        return phases[PreparationKey(capability: capability, packageID: nil)] ?? .idle
    }

    /// Engine-internal: record a phase under both the package-specific and capability-wide keys, so a
    /// consumer can observe by capability alone or by exact package.
    public func update(_ capability: Capability, package: String?, to phase: PreparePhase) {
        phases[PreparationKey(capability: capability, packageID: package)] = phase
        phases[PreparationKey(capability: capability, packageID: nil)] = phase
        broadcaster.yield(PreparationEvent(capability: capability, packageID: package, phase: phase))
    }

    private nonisolated let broadcaster = EventBroadcaster<PreparationEvent>()

    /// Every phase change from now on, in the order the engine recorded them (contract 1.57.0,
    /// AB-A-0206 item 4) — the push counterpart of `phases`, for a consumer outside SwiftUI:
    /// a plugin worker relays each event to its host as a progress message. Callable from any
    /// isolation; each call returns an independent stream, which ends when its consuming task is
    /// cancelled. A slow consumer loses intermediate `.downloading` fractions, never a terminal
    /// phase: the stream buffers the newest `bufferLimit` events.
    public nonisolated func events(bufferLimit: Int = 256) -> AsyncStream<PreparationEvent> {
        broadcaster.stream(bufferLimit: bufferLimit)
    }
}

/// One `PreparationMonitor` update: a package's preparation reached `phase` (contract 1.57.0).
public struct PreparationEvent: Sendable, Equatable, Codable {
    public let capability: Capability
    /// The package's string id, when the engine recorded one (it always does).
    public let packageID: String?
    public let phase: PreparePhase
    public let date: Date

    public init(capability: Capability, packageID: String?, phase: PreparePhase, date: Date = Date()) {
        self.capability = capability
        self.packageID = packageID
        self.phase = phase
        self.date = date
    }
}

/// A flat, stable wire form for `PreparePhase` (contract 1.57.0):
/// `{"phase": "downloading", "fraction": 0.42, "bytesPerSecond": 6.1e7}`, `{"phase": "failed",
/// "reason": "…"}`, `{"phase": "ready"}`. An unknown `phase` string decodes as `.failed` naming
/// it, so an older reader of a newer writer degrades instead of throwing.
extension PreparePhase: Codable {
    private enum CodingKeys: String, CodingKey { case phase, fraction, bytesPerSecond, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .phase) {
        case "idle": self = .idle
        case "registering": self = .registering
        case "prewarming": self = .prewarming(fraction: try c.decode(Double.self, forKey: .fraction))
        case "downloading":
            self = .downloading(fraction: try c.decode(Double.self, forKey: .fraction),
                                bytesPerSecond: try c.decodeIfPresent(Double.self, forKey: .bytesPerSecond))
        case "loading": self = .loading
        case "ready": self = .ready
        case "failed": self = .failed(try c.decode(String.self, forKey: .reason))
        case let other: self = .failed("unknown preparation phase \"\(other)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle: try c.encode("idle", forKey: .phase)
        case .registering: try c.encode("registering", forKey: .phase)
        case .prewarming(let fraction):
            try c.encode("prewarming", forKey: .phase)
            try c.encode(fraction, forKey: .fraction)
        case .downloading(let fraction, let bytesPerSecond):
            try c.encode("downloading", forKey: .phase)
            try c.encode(fraction, forKey: .fraction)
            try c.encodeIfPresent(bytesPerSecond, forKey: .bytesPerSecond)
        case .loading: try c.encode("loading", forKey: .phase)
        case .ready: try c.encode("ready", forKey: .phase)
        case .failed(let reason):
            try c.encode("failed", forKey: .phase)
            try c.encode(reason, forKey: .reason)
        }
    }
}

/// Fan-out of one event sequence to any number of `AsyncStream` subscribers (contract 1.57.0).
/// Lock-protected so the monitors can publish from the main actor while consumers subscribe from
/// anywhere.
final class EventBroadcaster<Event: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Event>.Continuation]>([:])

    func stream(bufferLimit: Int) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit)))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ event: Event) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(event) }
    }

    deinit {
        continuations.withLock { for c in $0.values { c.finish() } }
    }
}

/// Ambient download-progress reporter. The engine binds a sink around a package's `load()`; a package
/// forwards its downloader's progress here to surface a real `.downloading(fraction:…)` phase. No-op
/// when unbound, so reporting is always safe to call.
///
/// A package adopts it by switching its `HubApi.snapshot(...)` to the progress overload and forwarding:
/// ```swift
/// try await hub.snapshot(from: repo, matching: globs) { progress, speed in
///     WeightDownloadProgress.report(fraction: progress.fractionCompleted, bytesPerSecond: speed)
/// }
/// ```
public enum WeightDownloadProgress {
    public typealias Sink = @Sendable (_ fraction: Double, _ bytesPerSecond: Double?) -> Void

    @TaskLocal public static var sink: Sink?

    /// Report download progress to the ambient sink (no-op if none is bound).
    public static func report(fraction: Double, bytesPerSecond: Double? = nil) {
        sink?(fraction, bytesPerSecond)
    }
}
