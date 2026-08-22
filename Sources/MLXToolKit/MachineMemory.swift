import Foundation

/// A machine-wide memory reading (1.36.0, AB-A-0014) — what the WHOLE host has, beside
/// `physFootprint()`'s what-THIS-PROCESS-uses. The gap it closes: admission could answer "does
/// this fit my budget?" but never "does this fit this machine, right now?" — and for a 54-minute
/// render whose peak arrives tens of minutes in, that difference is an aborted job.
///
/// ⚠️ "Available" is a JUDGMENT CALL, which is exactly why it is defined here once rather than
/// re-derived per consumer (the ask's point): `free + inactive` — inactive pages are reclaimable
/// under pressure, so free-alone under-counts what a large job can actually get; but not every
/// inactive page reclaims instantly, and compressor depth (surfaced separately) indicates how
/// hard the machine is already working to look this free. Hosts wanting the conservative read use
/// `freeBytes` directly.
public struct MachineMemory: Sendable, Equatable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    /// Reclaimable-under-pressure pages (not all instantly).
    public let inactiveBytes: UInt64
    /// Kernel-pinned; never reclaimable.
    public let wiredBytes: UInt64
    /// Bytes held compressed. A deep compressor means the machine is ALREADY under pressure,
    /// however large `freeBytes` looks after the compression.
    public let compressedBytes: UInt64
    public let measuredAt: Date

    /// The judged machine-wide headroom: `free + inactive`. See the type doc for the judgment.
    public var availableBytes: UInt64 { freeBytes &+ inactiveBytes }

    public init(totalBytes: UInt64, freeBytes: UInt64, inactiveBytes: UInt64,
                wiredBytes: UInt64, compressedBytes: UInt64, measuredAt: Date = Date()) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.measuredAt = measuredAt
    }
}

/// The launch-gate answer (1.36.0, AB-A-0014): the engine's PROJECTED peak for a package against
/// the machine's availability, computed fresh on every call — machine state is a moving target,
/// and this IS the "should I start a 54-minute job" query.
///
/// The arithmetic is the honest part: at launch the process footprint is near zero and the peak
/// arrives much later, so a naive "is there room right now" check passes trivially. The engine
/// compares the ADDITIONAL bytes it projects needing (projected peak minus what it already holds)
/// against machine availability — the projection is engine-side knowledge (declared footprints +
/// resolved lane hints), which is why only the engine can compose this number.
///
/// ADVISORY by definition (AB-D-0038): the engine supplies the number, the HOST decides whether it
/// renders as a warning or a closed door. `fits == false` on a long job is a strong candidate for
/// the closed door — a launch that is doomed at minute 40 is closer to a crash class than to a
/// slowdown.
public struct MachineFitAdvisory: Sendable, Equatable {
    public let package: String
    /// The engine's projected whole-working-set peak: current residency + this package's
    /// resolved (persistent + transient) split.
    public let projectedPeakBytes: UInt64
    /// This process's current `phys_footprint` at the time of the call.
    public let currentProcessBytes: UInt64
    /// `max(0, projectedPeakBytes − currentProcessBytes)` — what still has to come from the
    /// machine between now and the peak.
    public let additionalBytes: UInt64
    public let machine: MachineMemory
    /// `additionalBytes <= machine.availableBytes`.
    public let fits: Bool
    /// Engine-composed, host-renderable sentence with the numbers.
    public let message: String

    public init(package: String, projectedPeakBytes: UInt64, currentProcessBytes: UInt64,
                additionalBytes: UInt64, machine: MachineMemory, fits: Bool, message: String) {
        self.package = package
        self.projectedPeakBytes = projectedPeakBytes
        self.currentProcessBytes = currentProcessBytes
        self.additionalBytes = additionalBytes
        self.machine = machine
        self.fits = fits
        self.message = message
    }
}

/// OS memory-pressure level, as reported by the kernel's pressure source (1.36.0).
public enum MemoryPressureLevel: String, Sendable, Equatable {
    case nominal, warning, critical
}

/// One pressure notification with the machine reading taken at delivery (1.36.0, AB-A-0014).
/// This is the signal a host's render OVERLAY subscribes to mid-run — the one piece a host
/// cannot build for itself, since polling its own `phys_footprint` says nothing about the
/// machine, and the drift that kills a long job (another app's spike, Spotlight, a sync) is
/// precisely not the host's own memory.
public struct MemoryPressureEvent: Sendable, Equatable {
    public let level: MemoryPressureLevel
    public let machine: MachineMemory?
    public let at: Date
    public init(level: MemoryPressureLevel, machine: MachineMemory?, at: Date = Date()) {
        self.level = level
        self.machine = machine
        self.at = at
    }
}
