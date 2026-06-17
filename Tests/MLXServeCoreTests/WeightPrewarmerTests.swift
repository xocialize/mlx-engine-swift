import XCTest
@testable import MLXServeCore
import MLXToolKit

final class WeightPrewarmerTests: XCTestCase {
    /// A file + a directory of weight files page in without throwing, and a non-weight file in the
    /// directory is ignored (extension filter). Best-effort: missing paths are simply skipped.
    func testPrewarmFilesAndDirectoriesBestEffort() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "prewarm-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // A standalone "weight" file (passed directly), a weight file inside a scanned dir, and a
        // non-weight file in that dir that must be ignored.
        let loose = root.appending(path: "loose.safetensors")
        let subdir = root.appending(path: "ckpt")
        try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        let inner = subdir.appending(path: "model.safetensors")
        let sidecar = subdir.appending(path: "config.json")
        let blob = Data(repeating: 0xAB, count: 4 * 1024 * 1024)
        try blob.write(to: loose)
        try blob.write(to: inner)
        try Data("{}".utf8).write(to: sidecar)

        // Includes a non-existent path, which must be skipped silently.
        let missing = root.appending(path: "does-not-exist.safetensors")
        await WeightPrewarmer.prewarm([loose, subdir, missing], label: "test")

        // Reaching here without a throw/crash is the contract (best-effort, void). The files remain
        // readable afterward (we only paged them into cache, didn't consume/move them).
        XCTAssertEqual(try Data(contentsOf: inner).count, blob.count)
    }

    /// Empty input is a no-op (no detached work, returns immediately).
    func testPrewarmEmptyIsNoOp() async {
        await WeightPrewarmer.prewarm([], label: "empty")
    }
}
