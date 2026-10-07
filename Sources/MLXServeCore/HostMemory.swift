import Foundation
import MLXToolKit
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
        guard let (info, _) = taskVMInfo() else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
    }

    /// The kernel's own high-water mark of this process's `phys_footprint`:
    /// `task_vm_info.ledger_phys_footprint_peak` (rev3). Exact where a polled peak is not — the
    /// ledger moves with every page the process gains, so a spike shorter than any poll interval
    /// still lands in it (AB-A-0134: a 150 ms sampler read Nacre's fp32 tile peak 1.9 GB low).
    ///
    /// It is the process's LIFETIME peak and never resets, so it measures one window only when the
    /// window raised it; `FootprintPeak.window` makes that call. `nil` when the syscall fails or the
    /// kernel's reply does not reach the rev3 fields.
    public static func physFootprintLifetimePeak() -> UInt64? {
        #if canImport(Darwin)
        guard let (info, count) = taskVMInfo(),
              let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
              Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<Int64>.size,
              info.ledger_phys_footprint_peak > 0
        else { return nil }
        return UInt64(info.ledger_phys_footprint_peak)
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    /// One `TASK_VM_INFO` read, with the count of `integer_t`s the kernel actually filled.
    private static func taskVMInfo() -> (task_vm_info_data_t, mach_msg_type_number_t)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (info, count)
    }
    #endif

    /// Machine-WIDE memory statistics via `host_statistics64` (`HOST_VM_INFO64`) — the reading
    /// beside `physFootprint()` that AB-A-0014 asked for: the process number can say what WE use,
    /// and nothing about what the machine has left. Returns `nil` when the syscall fails.
    public static func machineMemory() -> MachineMemory? {
        #if canImport(Darwin)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        guard pageSize > 0 else { return nil }
        let page = UInt64(pageSize)
        return MachineMemory(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(stats.free_count) &* page,
            inactiveBytes: UInt64(stats.inactive_count) &* page,
            wiredBytes: UInt64(stats.wire_count) &* page,
            compressedBytes: UInt64(stats.compressor_page_count) &* page)
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

/// A window's `phys_footprint` peak, and whether it is exact (AB-A-0134).
///
/// A polled peak is a LOWER bound: a transient shorter than the poll interval falls between two
/// reads, and the error grows with the spike. The kernel's ledger peak
/// (`HostMemory.physFootprintLifetimePeak`) is exact, but process-lifetime. So read it before and
/// after the window. If it rose, the new high-water was set inside the window, which makes it the
/// window's peak whatever the process did earlier. If it did not rise, the window stayed under an
/// earlier high-water and the ledger cannot say by how much, so the polled value is all there is.
public struct FootprintPeak: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// The kernel ledger rose during the window: `bytes` is the window's exact peak.
        case kernelLedger
        /// The ledger did not move (this process peaked higher before the window) or could not be
        /// read: `bytes` is the polled maximum, a lower bound. Measure in a fresh process to get an
        /// exact number.
        case sampled
    }

    public let bytes: UInt64
    public let source: Source

    public init(bytes: UInt64, source: Source) {
        self.bytes = bytes
        self.source = source
    }

    /// The window's peak from a polled maximum and the kernel's lifetime peak read before and after.
    public static func window(sampled: UInt64, lifetimePeakBefore: UInt64?,
                              lifetimePeakAfter: UInt64?) -> FootprintPeak {
        if let before = lifetimePeakBefore, let after = lifetimePeakAfter, after > before {
            return FootprintPeak(bytes: max(sampled, after), source: .kernelLedger)
        }
        return FootprintPeak(bytes: sampled, source: .sampled)
    }
}
