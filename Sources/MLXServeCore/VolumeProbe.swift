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
/// - Read pages that are NOT in the page cache, or the probe benches memory and lies.
///   `F_NOCACHE` alone is not enough: it keeps the read from adding pages, but pages already
///   cached are still served from memory — and a weights file the last run (or a prewarm)
///   streamed is mostly cached. On LTX 2.5's bf16 transformer on an external PCI-E SSD a cold
///   region read 4.15 GB/s and a region read seconds earlier 12.52 GB/s (AB-A-0242), which
///   would pass a USB volume over the 1 GB/s floor. So the probe asks `mincore` which pages are
///   resident, reads the coldest window across the weight files, evicts that window first when
///   none is cold, and reports no speed when it cannot get a cold window at all.
/// - Probe a REAL weight file (from the config's `WeightPrewarming.prewarmPaths`) — a synthetic
///   temp file may land on a different volume than the weights.
/// - Cache per volume with a staleness window: the number changes when hardware does, not per
///   prepare(), and a 256 MB read per prepare would be its own regression.
enum VolumeProbe {
    static let probeBytesTarget = 256 << 20      // read up to 256 MB of the file
    static let chunkBytes = 16 << 20             // in 16 MB chunks
    static let cacheStaleness: TimeInterval = 30 * 60
    /// A window counts as cold when at most this fraction of its pages is resident. A few warm
    /// pages barely move a 256 MB read; a mostly warm window is what made the probe lie.
    static let maxResidentFraction = 0.05

    private struct CacheEntry { let value: VolumeCharacterization }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]

    /// Characterize the volume holding `paths` (files pass through; directories are scanned one
    /// level). The volume is the largest weight-shaped file's; the read is the coldest window
    /// among the weight files on it. Returns nil when nothing probeable exists — the caller
    /// treats that as "unverifiable", never as "passed".
    static func characterize(paths: [URL]) -> VolumeCharacterization? {
        let candidates = probeCandidates(in: paths)
        guard let file = candidates.first else { return nil }
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
        // Only files on the probed volume: a window on another volume measures the wrong disk.
        let sameVolume = candidates.filter { volumeMount(of: $0).path == volume.path }
        let window = coldWindow(in: sameVolume)
        let speed = window.flatMap { sustainedRead(file: $0.file, offset: $0.offset, length: $0.length) }
        let result = VolumeCharacterization(
            volumePath: volume.path, protocolName: proto, isRemovable: removable,
            freeBytes: free.flatMap { $0 >= 0 ? UInt64($0) : nil },
            sustainedReadBytesPerSecond: speed, probedFile: (window?.file ?? file).path,
            measuredAt: Date())

        cacheLock.lock()
        cache[volume.path] = CacheEntry(value: result)
        cacheLock.unlock()
        return result
    }

    /// Plain files among the paths, largest first (files pass through; directories scanned one
    /// level). Weight files are what we want, and they are reliably the largest things present.
    private static func probeCandidates(in paths: [URL]) -> [URL] {
        var found: [(URL, Int)] = []
        let fm = FileManager.default
        func consider(_ url: URL) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? Int, size >= 8 << 20   // ≥8 MB: a real measurement
            else { return }
            found.append((url, size))
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
        return found.sorted { $0.1 > $1.1 }.map(\.0)
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

    struct Window: Equatable {
        let file: URL
        let offset: Int
        let length: Int
        /// Fraction of the window's pages resident in the page cache when it was chosen.
        let residentFraction: Double
    }

    /// The window to read: the first cold one (largest file first), else the least-resident one
    /// overall, evicted from the page cache first. nil when nothing could be made cold — a speed
    /// read from memory is worse than no speed, because the floor would pass on it.
    static func coldWindow(in files: [URL]) -> Window? {
        var warmest: Window? = nil
        for file in files {
            guard let window = leastResidentWindow(in: file) else { continue }
            if window.residentFraction <= maxResidentFraction { return window }
            if warmest == nil || window.residentFraction < warmest!.residentFraction { warmest = window }
        }
        guard let window = warmest else { return nil }
        evict(window)
        guard let after = residentFraction(file: window.file, offset: window.offset, length: window.length),
              after <= maxResidentFraction
        else { return nil }
        return Window(file: window.file, offset: window.offset, length: window.length,
                      residentFraction: after)
    }

    /// The `probeBytesTarget` window (on `chunkBytes` boundaries) with the fewest pages in the
    /// page cache. `mincore` over a read-only mapping reports residency without faulting
    /// anything in.
    static func leastResidentWindow(in file: URL) -> Window? {
        guard let resident = residentPages(file: file) else { return nil }
        let page = Int(getpagesize())
        let size = resident.size
        let length = min(size, probeBytesTarget)
        guard length >= 8 << 20 else { return nil }
        let pagesPerChunk = chunkBytes / page
        let windowPages = (length + page - 1) / page
        // Prefix sums over resident pages, so each candidate window costs O(1).
        var prefix = [Int](repeating: 0, count: resident.pages.count + 1)
        for (i, inCore) in resident.pages.enumerated() { prefix[i + 1] = prefix[i] + (inCore ? 1 : 0) }
        var best: (offset: Int, count: Int)? = nil
        var startPage = 0
        while startPage * page + length <= size {
            let end = min(startPage + windowPages, resident.pages.count)
            let count = prefix[end] - prefix[startPage]
            if best == nil || count < best!.count { best = (startPage * page, count) }
            if count == 0 { break }
            startPage += pagesPerChunk
        }
        guard let best else { return nil }
        return Window(file: file, offset: best.offset, length: length,
                      residentFraction: Double(best.count) / Double(windowPages))
    }

    /// Fraction of `[offset, offset+length)` of `file` resident in the page cache.
    static func residentFraction(file: URL, offset: Int, length: Int) -> Double? {
        guard let resident = residentPages(file: file) else { return nil }
        let page = Int(getpagesize())
        let first = offset / page
        let last = min((offset + length + page - 1) / page, resident.pages.count)
        guard last > first else { return nil }
        let count = resident.pages[first..<last].reduce(0) { $0 + ($1 ? 1 : 0) }
        return Double(count) / Double(last - first)
    }

    /// Per-page residency of the whole file. Mapping a 35 GB file read-only costs address space,
    /// not memory, and the vector is one byte per page (~2 MB for 35 GB at 16 KB pages).
    private static func residentPages(file: URL) -> (size: Int, pages: [Bool])? {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let size = Int(st.st_size)
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { return nil }
        defer { munmap(map, size) }
        let page = Int(getpagesize())
        var vec = [CChar](repeating: 0, count: (size + page - 1) / page)
        guard mincore(map, size, &vec) == 0 else { return nil }
        return (size, vec.map { $0 & CChar(MINCORE_INCORE) != 0 })
    }

    /// Drop the window's pages from the page cache: `msync(MS_INVALIDATE)` on a mapping of it,
    /// the evict vmtouch uses on macOS. MS_SYNC first writes back anything dirty, so a file
    /// still being written loses nothing. Weights are read-only; this only costs the next read.
    static func evict(_ window: Window) {
        let fd = open(window.file.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard let map = mmap(nil, window.length, PROT_READ, MAP_SHARED, fd, off_t(window.offset)),
              map != MAP_FAILED
        else { return }
        defer { munmap(map, window.length) }
        _ = msync(map, window.length, MS_SYNC | MS_INVALIDATE)
    }

    /// Sequential read of `length` bytes of `file` from `offset`, with `F_NOCACHE` so the probe
    /// does not warm the window it chose cold. Returns bytes/second, or nil when the file cannot
    /// be read.
    static func sustainedRead(file: URL, offset: Int, length: Int) -> UInt64? {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let target = length
        guard target >= 8 << 20 else { return nil }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: 16384)
        defer { buf.deallocate() }
        var total = 0
        let t0 = DispatchTime.now()
        while total < target {
            let want = min(chunkBytes, target - total)
            let got = pread(fd, buf, want, off_t(offset + total))
            guard got > 0 else { break }
            total += got
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        guard total >= 8 << 20, seconds > 0 else { return nil }
        return UInt64(Double(total) / seconds)
    }
}
