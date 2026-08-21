import Foundation

/// What the engine learned about the volume a package's weights live on (1.34.0, AB-T-0070).
/// Produced by the engine's prepare-time probe; consumable by apps for a storage advisory UI.
///
/// The load-bearing field is `sustainedReadBytesPerSecond` — measured with `F_NOCACHE` so a hot
/// page cache cannot lie (a cached read benches at memory speed and says nothing about the disk;
/// the same trap class as the metallib probe-with-a-write lesson). Protocol and removability are
/// best-effort metadata: useful for phrasing a warning ("weights are on a removable USB volume"),
/// never the basis of a refusal — the MEASURED number is.
public struct VolumeCharacterization: Sendable, Equatable {
    /// Mount point of the volume that was probed (e.g. `/Volumes/Satechi`).
    public let volumePath: String
    /// Transport protocol when determinable (e.g. "USB", "PCI-Express", "Apple Fabric"); `nil`
    /// when DiskArbitration could not say.
    public let protocolName: String?
    /// Whether the volume is removable/external, when determinable.
    public let isRemovable: Bool?
    /// Free capacity for important usage, when determinable.
    public let freeBytes: UInt64?
    /// Measured sustained sequential read over a real weight file, page cache bypassed
    /// (`F_NOCACHE`). `nil` when no suitable file was available to probe.
    public let sustainedReadBytesPerSecond: UInt64?
    /// The file the measurement read, for the receipt trail.
    public let probedFile: String?
    /// When the measurement was taken (results are cached per volume for a staleness window).
    public let measuredAt: Date

    public init(volumePath: String, protocolName: String?, isRemovable: Bool?,
                freeBytes: UInt64?, sustainedReadBytesPerSecond: UInt64?,
                probedFile: String?, measuredAt: Date) {
        self.volumePath = volumePath
        self.protocolName = protocolName
        self.isRemovable = isRemovable
        self.freeBytes = freeBytes
        self.sustainedReadBytesPerSecond = sustainedReadBytesPerSecond
        self.probedFile = probedFile
        self.measuredAt = measuredAt
    }
}

/// How the engine responds when a measured volume sits below a variant's declared floor.
public enum StorageFloorPolicy: String, Sendable {
    /// Refuse `prepare()` with `PackageError.weightsVolumeBelowFloor` (the default). The floor
    /// marks configurations where a slow volume is a mid-run crash, not a slowdown — failing
    /// closed here is the point (AB-T-0070 / the I9 receipt).
    case enforce
    /// Measure and surface, but never refuse — the explicit override for operators who know
    /// their volume (e.g. a one-off measurement run on deliberately slow storage).
    case warnOnly
}
