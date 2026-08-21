import Foundation
import MLXToolKit
#if canImport(DiskArbitration)
import DiskArbitration
#endif

/// Prepare-time weights-volume characterization (1.34.0, AB-T-0070).
///
/// Why this exists: the I9 receipt (`LTX_TESTING/ISSUES.md:12`). Lazy safetensors pull their
/// bytes inside LIVE Metal command buffers, so a slow weights volume does not degrade a big
/// working set — it kills it (bf16-on-USB: 0/7 across three sessions, GPU-watchdog aborts; the
/// same tree on PCI-E SSD: 3/3, isolated by a same-binary A/B). Prewarm does not save it: the
/// failing arm had a hot page cache and still died, because the run's own working set evicts the
/// cache mid-generation. The only early signal is the volume itself — so measure it BEFORE the
/// first command buffer, where a refusal is loud, cheap, and explainable.
///
/// Measurement discipline:
/// - `F_NOCACHE` on the probe read, or a hot cache benches memory and lies.
/// - Probe a REAL weight file (from the config's `WeightPrewarming.prewarmPaths`) — a synthetic
///   temp file may land on a different volume than the weights.
/// - Cache per volume with a staleness window: the number changes when hardware does, not per
///   prepare(), and a 256 MB read per prepare would be its own regression.
enum VolumeProbe {
    static let probeBytesTarget = 256 << 20      // read up to 256 MB of the file
    static let chunkBytes = 16 << 20             // in 16 MB chunks
    static let cacheStaleness: TimeInterval = 30 * 60

    private struct CacheEntry { let value: VolumeCharacterization }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]

    /// Characterize the volume holding `paths` (the first existing file wins; directories are
    /// scanned one level for the largest weight-shaped file). Returns nil when nothing probeable
    /// exists — the caller treats that as "unverifiable", never as "passed".
    static func characterize(paths: [URL]) -> VolumeCharacterization? {
        guard let file = probeCandidate(in: paths) else { return nil }
        let volume = volumeMount(of: file)

        cacheLock.lock()
        if let hit = cache[volume.path],
           Date().timeIntervalSince(hit.value.measuredAt) < cacheStaleness {
            cacheLock.unlock()
            return hit.value
        }
        cacheLock.unlock()

        let (proto, removable) = diskDescription(volumePath: volume)
        let free = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let speed = sustainedRead(file: file)
        let result = VolumeCharacterization(
            volumePath: volume.path, protocolName: proto, isRemovable: removable,
            freeBytes: free.flatMap { $0 >= 0 ? UInt64($0) : nil },
            sustainedReadBytesPerSecond: speed, probedFile: file.path, measuredAt: Date())

        cacheLock.lock()
        cache[volume.path] = CacheEntry(value: result)
        cacheLock.unlock()
        return result
    }

    /// Largest plain file among the paths (files pass through; directories scanned one level).
    /// Weight files are what we want, and they are reliably the largest thing present.
    private static func probeCandidate(in paths: [URL]) -> URL? {
        var best: (URL, Int)? = nil
        let fm = FileManager.default
        func consider(_ url: URL) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? Int, size >= 8 << 20   // ≥8 MB: a real measurement
            else { return }
            if best == nil || size > best!.1 { best = (url, size) }
        }
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                for entry in (try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? [] {
                    consider(entry)
                }
            } else {
                consider(path)
            }
        }
        return best?.0
    }

    private static func volumeMount(of file: URL) -> URL {
        (try? file.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(fileURLWithPath: "/")
    }

    /// Best-effort protocol + removability via DiskArbitration. Metadata for phrasing warnings —
    /// refusals rest on the MEASURED read speed, never on this.
    private static func diskDescription(volumePath: URL) -> (String?, Bool?) {
        #if canImport(DiskArbitration)
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumePath as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any]
        else { return (nil, nil) }
        let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let removable = (desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool)
            ?? (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool).map { !$0 }
        return (proto, removable)
        #else
        return (nil, nil)
        #endif
    }

    /// Sequential read of up to `probeBytesTarget` from `file`, page cache bypassed. Returns
    /// bytes/second, or nil when the file cannot be read.
    private static func sustainedRead(file: URL) -> UInt64? {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        let target = min(size, probeBytesTarget)
        guard target >= 8 << 20 else { return nil }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 16384)
        defer { buf.deallocate() }
        var total = 0
        let t0 = DispatchTime.now()
        while total < target {
            let want = min(chunkBytes, target - total)
            let got = pread(fd, buf, want, off_t(total))
            guard got > 0 else { break }
            total += got
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        guard total >= 8 << 20, seconds > 0 else { return nil }
        return UInt64(Double(total) / seconds)
    }
}
