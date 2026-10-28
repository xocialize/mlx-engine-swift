import Foundation
// The governor and the rest of the admission policy live in MLX-free MLXMemoryPolicy (1.58.0).
// Re-exported, so `import MLXServeCore` keeps seeing MemoryGovernor, MemoryPolicy,
// PreemptionPolicy, ExternalFootprint and MemorySnapshot exactly as before they moved.
@_exported import MLXMemoryPolicy
import MLXToolKit

extension MemoryGovernor {
    /// Size a governor for the device. An explicit `fraction` budgets that share of total
    /// unified memory (the pre-1.31 behavior at 0.7). By default (`nil`), when `device`
    /// describes THIS machine, the budget is the OS's own answer — Metal's
    /// `recommendedMaxWorkingSetSize` — queried, never hardcoded: it scales with capacity
    /// and OS release (macOS 26: ~74% @16 GB → ~84% @128 GB; a flat 0.7 under-budgets a
    /// 128 GB machine by ~18 GB). Falls back to 0.7 × total when Metal is unavailable
    /// (CI/test runners) or when the profile is synthetic (total ≠ this host's physical
    /// memory — fabricated-profile tests must not inherit the real machine's number).
    /// NEUROSTREAM-ACTIONS QW3 / teardown §3.2.
    public static func forDevice(_ device: DeviceProfile, fraction: Double? = nil) -> MemoryGovernor {
        if let fraction {
            return MemoryGovernor(
                budgetBytes: UInt64(Double(device.totalMemoryBytes) * max(0, min(1, fraction))))
        }
        if device.totalMemoryBytes == ProcessInfo.processInfo.physicalMemory,
           let recommended = HostMemory.recommendedGPUWorkingSetBytes(),
           recommended > 0, recommended < device.totalMemoryBytes {
            return MemoryGovernor(budgetBytes: recommended)
        }
        return MemoryGovernor(budgetBytes: UInt64(Double(device.totalMemoryBytes) * 0.7))
    }
}
