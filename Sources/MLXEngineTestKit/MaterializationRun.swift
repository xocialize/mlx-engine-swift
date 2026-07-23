import Foundation
import MLXToolKit
import MLXServeCore

/// First-run materialization metrics for ONE package — the download-side sibling of
/// `ValidationRun`. Drive it against an EMPTY store root to measure the true fresh-machine
/// experience: per-source bytes, wall time, progress-event coverage (no silent phases), the
/// install marker, and the cold peak. Emit `logLine` for headless capture; results feed the
/// engine registry's per-package Val evidence the same way SPLIT lines do.
public struct MaterializationRun: Sendable {
    public struct SourceMetric: Sendable {
        public let role: String
        public let repo: String
        /// Bytes on disk under the store for this source's repo after prepare.
        public let bytes: UInt64
        public init(role: String, repo: String, bytes: UInt64) {
            self.role = role
            self.repo = repo
            self.bytes = bytes
        }
    }

    public var packageLabel = ""
    public var sources: [SourceMetric] = []
    public var totalBytes: UInt64 = 0
    public var prepareSeconds: Double = 0
    /// The PreparationMonitor surfaced a real `.downloading` phase (progress forwarding works).
    public var sawDownloadingPhase = false
    /// Distinct download-progress fractions observed (coverage; 0 with `sawDownloadingPhase`
    /// false ⇒ the package downloads silently — a conformance smell).
    public var downloadEventCount = 0
    /// Install marker present under the store after prepare (the storage UI's signal).
    public var markerPresent = false
    public var baselineFootprint: UInt64 = 0
    public var peakFootprint: UInt64 = 0

    public init() {}

    /// Machine-readable capture line (grep `[MAT]`).
    public var logLine: String {
        let per = sources.map { "\($0.role)=\($0.bytes)" }.joined(separator: ",")
        return String(format: "[MAT] pkg=%@ bytes=%llu (%@) secs=%.1f downloadPhase=%@ events=%d marker=%@ peak=%llu",
                      packageLabel, totalBytes, per, prepareSeconds,
                      sawDownloadingPhase ? "yes" : "NO", downloadEventCount,
                      markerPresent ? "yes" : "NO", peakFootprint)
    }
}

/// Drives one package's `prepare()` against a store root and captures a `MaterializationRun`.
/// Generic over packages: sources are attributed by walking the declared `WeightSourcing` repos
/// under the root (falls back to whole-root total when the configuration doesn't declare).
public enum MaterializationBench {

    /// - Parameters:
    ///   - engine: engine with the package REGISTERED and `useModelStore(ModelStore(root:))`
    ///     already called with `root` (the bench never mutates engine state beyond `prepare`).
    ///   - configuration: the SAME configuration the package was registered with (for source
    ///     attribution + marker lookup).
    ///   - sourceRepo: the manifest's provenance repo — the marker location only for a
    ///     configuration that declares no `WeightSourcing` (declared sources win otherwise).
    @MainActor
    public static func run(engine: MLXServeEngine,
                           capability: Capability,
                           package: PackageID? = nil,
                           configuration: any PackageConfiguration,
                           sourceRepo: String,
                           storeRoot root: URL) async throws -> MaterializationRun {
        var result = MaterializationRun()
        result.packageLabel = package?.description ?? capability.rawValue
        result.baselineFootprint = HostMemory.physFootprint() ?? 0

        let sampler = MemorySampler()
        sampler.start(initial: result.baselineFootprint)

        // Poll the PreparationMonitor for download-phase coverage while prepare runs.
        let monitor = engine.preparation
        let phasePoller = Task { @MainActor () -> (Bool, Int) in
            var saw = false
            var fractions = Set<Int>()
            while !Task.isCancelled {
                if case .downloading(let fraction, _) = monitor.phase(for: capability,
                                                                      package: package?.description) {
                    saw = true
                    fractions.insert(Int(fraction * 1000))
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return (saw, fractions.count)
        }

        let start = Date()
        do {
            try await engine.prepare(capability, package: package)
        } catch {
            phasePoller.cancel()
            sampler.stop()
            throw error
        }
        result.prepareSeconds = Date().timeIntervalSince(start)
        phasePoller.cancel()
        (result.sawDownloadingPhase, result.downloadEventCount) = await phasePoller.value
        sampler.stop()
        result.peakFootprint = sampler.peak

        // Attribute on-disk bytes per declared source repo; whole-root total either way.
        let store = ModelStore(root: root)
        if let sourcing = configuration as? WeightSourcing {
            for source in sourcing.weightSources {
                let dir = store.directory(for: source.repo)
                result.sources.append(MaterializationRun.SourceMetric(
                    role: source.role, repo: source.repo,
                    bytes: dir.map(directoryBytes) ?? 0))
            }
        }
        result.totalBytes = directoryBytes(root)
        // Markers land where the engine stamps them: one per declared `WeightSource` repo (ALL must
        // be present), falling back to the caller-passed provenance repo for non-declaring configs.
        // Checking the caller's repo alone false-negatives variant-multiplexed packages, whose
        // weights (and markers) live under repos the static provenance never names.
        let markerRepos: [String]
        if let sourcing = configuration as? WeightSourcing, !sourcing.weightSources.isEmpty {
            markerRepos = sourcing.weightSources.map(\.repo)
        } else {
            markerRepos = [sourceRepo]
        }
        result.markerPresent = markerRepos.allSatisfy(store.hasMarker(for:))
        return result
    }

    /// Recursive on-disk size (allocated file sizes) under `url`.
    public static func directoryBytes(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total &+= UInt64(size)
            }
        }
        return total
    }
}
