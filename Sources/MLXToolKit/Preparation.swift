import Foundation

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

/// Identity for a preparation phase: a capability, optionally narrowed to a specific backing package
/// (when several packages back one capability). `packageID` is the package's string id.
public struct PreparationKey: Hashable, Sendable {
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
