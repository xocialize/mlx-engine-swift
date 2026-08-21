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
}
