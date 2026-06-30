import Foundation
import MLXServeCore

/// Polls process `phys_footprint` on a background cadence so a run's **peak** working set is captured,
/// not just the value at completion. Lifted from the retired proving-ground app's `MemorySampler`,
/// generalized to reuse `HostMemory.physFootprint` (one reader, shared with the engine's R-MEM-1 path).
@MainActor
public final class MemorySampler {
    private var task: Task<Void, Never>?
    public private(set) var peak: UInt64 = 0
    private let intervalMs: Int

    public init(intervalMs: Int = 150) { self.intervalMs = intervalMs }

    public func start(initial: UInt64? = nil) {
        peak = initial ?? (HostMemory.physFootprint() ?? 0)
        let ms = intervalMs
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let now = HostMemory.physFootprint() { self?.peak = max(self?.peak ?? 0, now) }
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }
}

/// Phase-tagged memory trace: a sampler that also records named markers, so a peak can be **attributed
/// to a stage** (encode / denoise / decode) — the seam that visually proves per-stage eviction. Call
/// `mark(_:)` at phase boundaries; `samples` holds `(phase, phys, elapsed)` and `peakByPhase` rolls up.
@MainActor
public final class PhaseTrace {
    public struct Sample: Sendable { public let phase: String; public let bytes: UInt64; public let elapsed: TimeInterval }

    public private(set) var samples: [Sample] = []
    private var task: Task<Void, Never>?
    private var phase = "start"
    private var start = Date()
    private let intervalMs: Int

    public init(intervalMs: Int = 150) { self.intervalMs = intervalMs }

    public func begin(referenceDate: Date) {
        start = referenceDate
        let ms = intervalMs
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled { self?.tick(); try? await Task.sleep(for: .milliseconds(ms)) }
        }
    }

    /// Mark a phase boundary (records an immediate sample too).
    public func mark(_ phase: String) { self.phase = phase; tick() }

    public func end() { task?.cancel(); task = nil }

    private func tick() {
        guard let bytes = HostMemory.physFootprint() else { return }
        samples.append(Sample(phase: phase, bytes: bytes, elapsed: Date().timeIntervalSince(start)))
    }

    /// Peak `phys_footprint` per phase label — the attribution table.
    public var peakByPhase: [(phase: String, peak: UInt64)] {
        var m: [String: UInt64] = [:]
        var order: [String] = []
        for s in samples { if m[s.phase] == nil { order.append(s.phase) }; m[s.phase] = max(m[s.phase] ?? 0, s.bytes) }
        return order.map { ($0, m[$0] ?? 0) }
    }
}
