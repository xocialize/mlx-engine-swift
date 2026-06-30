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
    /// fits the budget, else the smallest. Single-footprint manifests resolve exactly. Use this for
    /// variant-agnostic surveys (admissibility / "what can this machine run"); for a *registered*
    /// package prefer `footprint(for:quant:)` so the charge matches the chosen variant.
    public func footprint(for requirements: RequirementsManifest) -> UInt64 {
        let sizes = requirements.footprints.map(\.residentBytes).sorted()
        guard let smallest = sizes.first else { return 0 }
        return sizes.last(where: { $0 <= budgetBytes }) ?? smallest
    }

    /// Config-aware footprint: when `quant` is the registered config's variant AND the manifest
    /// declares a matching `QuantFootprint`, charge exactly that variant's bytes (ISSUES W1 — fixes
    /// the variant-unaware over/under-reserve: largest-that-fits silently charged the smaller int4
    /// figure for a bf16 registration whenever bf16 exceeded budget). Falls back to the
    /// largest-that-fits heuristic when `quant` is nil (config didn't opt into `QuantConfigured`) or
    /// no declared footprint matches it (author mismatch) — both safe.
    public func footprint(for requirements: RequirementsManifest, quant: Quant?) -> UInt64 {
        if let quant, let match = requirements.footprints.first(where: { $0.quant == quant }) {
            return match.residentBytes
        }
        return footprint(for: requirements)
    }

    /// Fully config-aware footprint. Resolution order: an explicit `hint` (from a `FootprintConfigured`
    /// config — the measured max-phase bytes for the selected variant) wins over the `quant`-keyed
    /// `QuantFootprint` match, which wins over the largest-that-fits survey. The `hint` resolves the
    /// same-quant multi-mode case (e.g. BiRefNet `fast` vs `best`, both fp16) that `quant` alone can't
    /// express. Every fallback is safe — it never under-reserves a single-footprint manifest.
    public func footprint(for requirements: RequirementsManifest, quant: Quant?, hint: UInt64?) -> UInt64 {
        if let hint { return hint }
        return footprint(for: requirements, quant: quant)
    }

    /// Resolve the `(persistent weights, transient activation peak)` split the engine accounts for —
    /// the basis of the serialized-inference reserve (residency = Σ persistent; reserve = one max
    /// transient). Picks the base `QuantFootprint` by quant match, else largest-that-fits, else
    /// smallest; `persistentHint`/`transientHint` (from a `FootprintConfigured` config) override the
    /// chosen footprint's `residentBytes`/`peakActivationBytes`. Safe defaults: transient falls back to
    /// `0` (no declared activation peak → the reactive R-MEM-1 trigger covers any overflow).
    public func footprintSplit(for requirements: RequirementsManifest,
                               quant: Quant?,
                               persistentHint: UInt64?,
                               transientHint: UInt64?) -> (persistent: UInt64, transient: UInt64) {
        let chosen: QuantFootprint? = {
            if let quant, let match = requirements.footprints.first(where: { $0.quant == quant }) {
                return match
            }
            let sorted = requirements.footprints.sorted { $0.residentBytes < $1.residentBytes }
            return sorted.last(where: { $0.residentBytes <= budgetBytes }) ?? sorted.first
        }()
        return (persistentHint ?? chosen?.residentBytes ?? 0,
                transientHint ?? chosen?.peakActivationBytes ?? 0)
    }

    public mutating func charge(_ bytes: UInt64) {
        residentBytes = residentBytes &+ bytes
    }

    public mutating func release(_ bytes: UInt64) {
        residentBytes = residentBytes > bytes ? residentBytes - bytes : 0
    }
}

/// Observable snapshot of the engine's memory state. `residentBytes` is the **declared** charge (sum
/// of `QuantFootprint` floors); `realResidentBytes` is the process's **actual** `phys_footprint` when
/// a reading is available (nil if the host syscall failed). `underRealPressure` is the R-MEM-1 signal:
/// the actual footprint is over the governor's high-watermark — the trigger declared bytes can miss.
public struct MemorySnapshot: Sendable, Equatable {
    public let budgetBytes: UInt64
    public let residentBytes: UInt64
    public let availableBytes: UInt64
    public let underPressure: Bool
    /// Resident capabilities and the bytes charged for each.
    public let residents: [Capability: UInt64]
    /// Process `phys_footprint` (actual resident memory) if a host reading was available, else nil.
    public let realResidentBytes: UInt64?
    /// Actual footprint over the governor's high-watermark (R-MEM-1 real-pressure). False when no
    /// reading is available.
    public let underRealPressure: Bool
    /// The single transient activation headroom currently reserved — `max(peakActivationBytes)` across
    /// residents, since serialized inference runs one at a time. `residentBytes + transientReserveBytes`
    /// is the engine's accounted peak; `availableBytes` already subtracts both.
    public let transientReserveBytes: UInt64

    public init(budgetBytes: UInt64, residentBytes: UInt64, availableBytes: UInt64,
                underPressure: Bool, residents: [Capability: UInt64],
                realResidentBytes: UInt64? = nil, underRealPressure: Bool = false,
                transientReserveBytes: UInt64 = 0) {
        self.budgetBytes = budgetBytes
        self.residentBytes = residentBytes
        self.availableBytes = availableBytes
        self.underPressure = underPressure
        self.residents = residents
        self.realResidentBytes = realResidentBytes
        self.underRealPressure = underRealPressure
        self.transientReserveBytes = transientReserveBytes
    }
}
