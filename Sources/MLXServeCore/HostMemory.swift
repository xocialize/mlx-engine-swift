import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Metal)
import Metal
#endif

/// Best-effort host memory readings for R-MEM-1's real-pressure trigger (see docs/architecture.md).
///
/// `physFootprint` is the *process's* actual resident footprint — `task_info`'s `TASK_VM_INFO`
/// `phys_footprint`, the same number Activity Monitor's "Memory" column reports. It captures the
/// activations + compute scratch that a package's declared `QuantFootprint.residentBytes` (a floor,
/// not a cap) omits, so the engine can evict on *real* pressure rather than declared-byte arithmetic
/// alone. Returns `nil` when the syscall fails, in which case callers degrade gracefully to the
/// declared-byte path.
public enum HostMemory {
    /// The current process's `phys_footprint` in bytes, or `nil` if the reading is unavailable.
    public static func physFootprint() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
    }

    /// Metal's `recommendedMaxWorkingSetSize` for the default device, or `nil` when no Metal
    /// device is available (some CI/test-runner processes). The OS's own answer to "how much
    /// unified memory may the GPU comfortably use" — macOS 26 scales it with capacity
    /// (~74% @16 GB → ~84% @128 GB) and it moves across OS releases, which is why it is
    /// queried, never hardcoded (NEUROSTREAM-TEARDOWN §3.2). A *soft* planning number, not an
    /// allocation cap: Metal can allocate beyond it, degrading before failing.
    public static func recommendedGPUWorkingSetBytes() -> UInt64? {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return device.recommendedMaxWorkingSetSize
        #else
        return nil
        #endif
    }
}
