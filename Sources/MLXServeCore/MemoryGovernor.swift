import Foundation
import MLXToolKit

/// Memory budgeting + watermark policy for resident working sets. The engine owns the resident set
/// and calls `charge`/`release` as packages load/unload; the governor answers "does this fit?" and
/// "are we under pressure?". v1 evicts **idle** residents (LRU) at admission; mid-run preemption +
/// requeue is the next layer.
public struct MemoryGovernor: Sendable {
    /// Total bytes the engine may hold resident.
    public let budgetBytes: UInt64
    /// Resident fraction at/above which the governor reports pressure (e.g. to gate auxiliary
    /// allocations like a retrieval WebView).
    public let highWatermark: Double
    public private(set) var residentBytes: UInt64

    public init(budgetBytes: UInt64, highWatermark: Double = 0.85) {
        self.budgetBytes = budgetBytes
        self.highWatermark = max(0, min(1, highWatermark))
        self.residentBytes = 0
    }

    /// Size a governor to a fraction of the device's unified memory (default 0.7).
    public static func forDevice(_ device: DeviceProfile, fraction: Double = 0.7) -> MemoryGovernor {
        MemoryGovernor(budgetBytes: UInt64(Double(device.totalMemoryBytes) * max(0, min(1, fraction))))
    }

    public var availableBytes: UInt64 { budgetBytes > residentBytes ? budgetBytes - residentBytes : 0 }
    public var underPressure: Bool { Double(residentBytes) >= Double(budgetBytes) * highWatermark }

    /// Whether `bytes` fits in the current headroom (after existing residents).
    public func canFit(_ bytes: UInt64) -> Bool { bytes <= availableBytes }
    /// Whether `bytes` could *ever* fit (ignoring current residents) — i.e. not larger than budget.
    public func fitsBudget(_ bytes: UInt64) -> Bool { bytes <= budgetBytes }

    /// The resident footprint to charge for a package: the largest declared footprint that still
    /// fits the budget, else the smallest. Single-footprint manifests resolve exactly.
    public func footprint(for requirements: RequirementsManifest) -> UInt64 {
        let sizes = requirements.footprints.map(\.residentBytes).sorted()
        guard let smallest = sizes.first else { return 0 }
        return sizes.last(where: { $0 <= budgetBytes }) ?? smallest
    }

    public mutating func charge(_ bytes: UInt64) {
        residentBytes = residentBytes &+ bytes
    }

    public mutating func release(_ bytes: UInt64) {
        residentBytes = residentBytes > bytes ? residentBytes - bytes : 0
    }
}

/// Observable snapshot of the engine's memory state.
public struct MemorySnapshot: Sendable, Equatable {
    public let budgetBytes: UInt64
    public let residentBytes: UInt64
    public let availableBytes: UInt64
    public let underPressure: Bool
    /// Resident capabilities and the bytes charged for each.
    public let residents: [Capability: UInt64]
}
