import Foundation
import MLXToolKit

/// What the host can run — the device side of the C10 match (`requirements ⊆ device.capabilities`).
/// Memory is the *total* unified memory; the live budget/headroom is the `MemoryGovernor`'s job.
public struct DeviceProfile: Sendable, Equatable {
    public var chipTier: ChipTier
    public var macOS: SemanticVersion
    public var backends: Set<Backend>
    public var totalMemoryBytes: UInt64

    public init(chipTier: ChipTier, macOS: SemanticVersion,
                backends: Set<Backend>, totalMemoryBytes: UInt64) {
        self.chipTier = chipTier
        self.macOS = macOS
        self.backends = backends
        self.totalMemoryBytes = totalMemoryBytes
    }

    /// Best-effort profile of the current host. macOS version and physical memory are exact; the
    /// backend set and chip tier are coarse (Apple-Silicon assumes the full execution-unit set and a
    /// permissive tier) — refine via sysctl brand-string parsing when a real gate needs it.
    public static func current() -> DeviceProfile {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = SemanticVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion)
        return DeviceProfile(
            chipTier: .max,
            macOS: macOS,
            backends: [.metalGPU, .coreMLANE, .coreMLCPU, .coreMLGPU],
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// Static (memory-independent) eligibility for a package's requirements (C10): required backends
    /// present, chip at/above floor, OS at/above minimum. Memory fit is evaluated separately by the
    /// `MemoryGovernor` at admission time.
    public func eligibility(for requirements: RequirementsManifest) -> DeviceEligibility {
        for backend in requirements.requiredBackends where !backends.contains(backend) {
            return .missingBackend(backend)
        }
        if let floor = requirements.chipFloor, chipTier < floor {
            return .chipBelowFloor(required: floor, have: chipTier)
        }
        if let minOS = requirements.os.minMacOS, macOS < minOS {
            return .osBelowMinimum(required: minOS, have: macOS)
        }
        return .eligible
    }
}

/// Result of the device-side C10 check; names the failing dimension.
public enum DeviceEligibility: Sendable, Equatable {
    case eligible
    case missingBackend(Backend)
    case chipBelowFloor(required: ChipTier, have: ChipTier)
    case osBelowMinimum(required: SemanticVersion, have: SemanticVersion)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}
