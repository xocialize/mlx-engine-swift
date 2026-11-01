import XCTest
@testable import MLXServeCore
import MLXToolKit

/// The prepare-time weights-volume probe (1.34.0, AB-T-0070).
final class VolumeProbeTests: XCTestCase {

    /// End-to-end on a real file: a ~32 MB temp file must yield a characterization with a
    /// positive measured read speed and the right volume. (F_NOCACHE means this measures the
    /// disk, so no speed ASSERTION beyond > 0 — CI hardware varies; the number being present
    /// and sane is the contract.)
    func testCharacterizeMeasuresARealFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("weights.safetensors")
        try Data(count: 32 << 20).write(to: file)

        let c = try XCTUnwrap(VolumeProbe.characterize(paths: [dir]))
        // Compare RESOLVED paths: /var is a symlink to /private/var on macOS, and the probe
        // reports the path as the directory walk yielded it.
        XCTAssertEqual(c.probedFile.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       file.resolvingSymlinksInPath().path)
        let speed = try XCTUnwrap(c.sustainedReadBytesPerSecond)
        XCTAssertGreaterThan(speed, 0)
        XCTAssertFalse(c.volumePath.isEmpty)
    }

    /// Second call inside the staleness window must come from the per-volume cache — a 256 MB
    /// F_NOCACHE read per prepare() would be its own regression.
    func testSecondCallIsCached() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 16 << 20).write(to: dir.appendingPathComponent("w.safetensors"))

        let first = try XCTUnwrap(VolumeProbe.characterize(paths: [dir]))
        let second = try XCTUnwrap(VolumeProbe.characterize(paths: [dir]))
        XCTAssertEqual(first.measuredAt, second.measuredAt)   // identical entry, not re-measured
    }

    /// Nothing probeable (empty dir, sub-8MB files) → nil, which callers must treat as
    /// UNVERIFIABLE — never as "passed". Guards the floor's fail-honest posture.
    func testUnprobeableReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 1 << 20).write(to: dir.appendingPathComponent("tiny.bin"))
        XCTAssertNil(VolumeProbe.characterize(paths: [dir]))
    }

    // MARK: - Cold-window selection (AB-A-0242)

    /// A file just written sits in the page cache. F_NOCACHE alone would read it from memory; the
    /// probe must see it is warm, evict its window, and confirm the window went cold.
    func testWarmWindowIsEvictedBeforeTheRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("w.safetensors")
        try Data(repeating: 7, count: 32 << 20).write(to: file)
        _ = try Data(contentsOf: file)   // make sure every page is resident

        let warm = try XCTUnwrap(VolumeProbe.leastResidentWindow(in: file))
        XCTAssertGreaterThan(warm.residentFraction, 0.9, "a just-read file should be resident")

        let cold = try XCTUnwrap(VolumeProbe.coldWindow(in: [file]))
        XCTAssertLessThanOrEqual(cold.residentFraction, VolumeProbe.maxResidentFraction)
        let after = try XCTUnwrap(VolumeProbe.residentFraction(
            file: file, offset: cold.offset, length: cold.length))
        XCTAssertLessThanOrEqual(after, VolumeProbe.maxResidentFraction)
        // Eviction drops cached pages, never data.
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 7, count: 32 << 20))
    }

    /// With a cold region available the probe reads it and evicts nothing: warm the first
    /// 256 MB of a 640 MB file, and the chosen window must start past it (read-ahead may warm
    /// a little beyond the head, so the bound is "past the head", not an exact offset).
    func testColdRegionIsPreferredOverAWarmOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("w.safetensors")
        let size = 640 << 20
        try Data(count: size).write(to: file)
        // Cold all of it, then warm the head.
        VolumeProbe.evict(VolumeProbe.Window(file: file, offset: 0, length: size, residentFraction: 1))
        let handle = try FileHandle(forReadingFrom: file)
        _ = try handle.read(upToCount: VolumeProbe.probeBytesTarget)
        try handle.close()

        let window = try XCTUnwrap(VolumeProbe.leastResidentWindow(in: file))
        XCTAssertGreaterThanOrEqual(window.offset, VolumeProbe.probeBytesTarget)
        XCTAssertLessThanOrEqual(window.residentFraction, VolumeProbe.maxResidentFraction)
    }

    /// Acceptance for AB-A-0242 on real hardware: on a large weight file whose probe region was
    /// just read, the probe must report within 25% of an uncached read of the same device — both
    /// when it can step past the warm region and when it has to evict the window it reads.
    /// Opt-in: MLXENGINE_VOLUME_PROBE_FILE=<a multi-GB weight file on the volume under test>.
    func testWarmVolumeMeasuresLikeACold() throws {
        guard let path = ProcessInfo.processInfo.environment["MLXENGINE_VOLUME_PROBE_FILE"] else {
            throw XCTSkip("set MLXENGINE_VOLUME_PROBE_FILE to run the live warm-vs-cold probe")
        }
        let file = URL(fileURLWithPath: path)
        let target = VolumeProbe.probeBytesTarget
        func warm(_ offset: Int) throws {
            let handle = try FileHandle(forReadingFrom: file)
            try handle.seek(toOffset: UInt64(offset))
            _ = try handle.read(upToCount: target)
            try handle.close()
        }

        // Two references, because the device has a cache of its own that no OS call reaches: on
        // DEV_VOL1 the first read of a region measured ~3.9 GB/s and an OS-uncached re-read of it
        // ~4.9 GB/s. A fresh region is compared with a fresh read, a re-read with a re-read.
        let coldRef = try XCTUnwrap(VolumeProbe.coldWindow(in: [file]))
        let reference = try XCTUnwrap(VolumeProbe.sustainedRead(
            file: file, offset: coldRef.offset, length: coldRef.length))
        let rereadReference = try XCTUnwrap(VolumeProbe.sustainedRead(
            file: file, offset: coldRef.offset, length: coldRef.length))
        XCTAssertLessThanOrEqual(try XCTUnwrap(VolumeProbe.residentFraction(
            file: file, offset: coldRef.offset, length: coldRef.length)), VolumeProbe.maxResidentFraction,
            "F_NOCACHE reads must leave the window cold")

        // The bug: warm the region, then read it with F_NOCACHE alone — memory speed.
        try warm(coldRef.offset)
        let naive = try XCTUnwrap(VolumeProbe.sustainedRead(
            file: file, offset: coldRef.offset, length: coldRef.length))

        // Fix, path 1: the probe steps past the warm region to a cold one.
        let stepped = try XCTUnwrap(VolumeProbe.coldWindow(in: [file]))
        XCTAssertNotEqual(stepped.offset, coldRef.offset)
        let steppedSpeed = try XCTUnwrap(VolumeProbe.sustainedRead(
            file: file, offset: stepped.offset, length: stepped.length))

        // Fix, path 2: the probe evicts a warm window and reads it.
        try warm(coldRef.offset)
        let warmWindow = VolumeProbe.Window(file: file, offset: coldRef.offset,
                                            length: coldRef.length, residentFraction: 1)
        let before = try XCTUnwrap(VolumeProbe.residentFraction(
            file: file, offset: coldRef.offset, length: coldRef.length))
        VolumeProbe.evict(warmWindow)
        let after = try XCTUnwrap(VolumeProbe.residentFraction(
            file: file, offset: coldRef.offset, length: coldRef.length))
        XCTAssertLessThanOrEqual(after, VolumeProbe.maxResidentFraction)
        let evictedSpeed = try XCTUnwrap(VolumeProbe.sustainedRead(
            file: file, offset: coldRef.offset, length: coldRef.length))

        let gbs = { (b: UInt64) in String(format: "%.2f GB/s", Double(b) / 1e9) }
        print("[VolumeProbe acceptance] \(file.lastPathComponent): cold reference \(gbs(reference)) "
              + "(re-read \(gbs(rereadReference))) @\(coldRef.offset) · warm F_NOCACHE only "
              + "\(gbs(naive)) · stepped past warm \(gbs(steppedSpeed)) @\(stepped.offset) · "
              + "evicted (resident " + String(format: "%.2f→%.2f", before, after) + ") "
              + "\(gbs(evictedSpeed))")
        XCTAssertGreaterThan(Double(naive), 1.5 * Double(rereadReference),
                             "the warm read should have come from memory — the bug this guards")
        XCTAssertEqual(Double(steppedSpeed), Double(reference), accuracy: Double(reference) * 0.25)
        XCTAssertEqual(Double(evictedSpeed), Double(rereadReference),
                       accuracy: Double(rereadReference) * 0.25)
    }
}
