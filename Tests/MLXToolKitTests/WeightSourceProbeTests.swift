import XCTest
@testable import MLXToolKit

/// MS-2 — the default `missingWeightSources(storeRoot:)` probe over the canonical (MS-1) HF layout,
/// plus MS-4's store deletion and deduped size accounting.
final class WeightSourceProbeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "WeightProbeTests-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Glob matching

    func testGlobMatching() {
        let m = WeightSourceProbe.matches(path:glob:)
        XCTAssertTrue(m("model.safetensors", "*.safetensors"))
        // A glob with no "/" also matches on the basename — the hub's allow-pattern behavior.
        XCTAssertTrue(m("nested/dir/model.safetensors", "*.safetensors"))
        XCTAssertTrue(m("voices/af_heart.safetensors", "voices/*.safetensors"))
        XCTAssertTrue(m("a/b/c.json", "**/*.json"))
        XCTAssertTrue(m("c.json", "**/*.json"))           // "**/" also matches zero components
        XCTAssertTrue(m("model-0001.bin", "model-????.bin"))

        XCTAssertFalse(m("model.bin", "*.safetensors"))
        // "*" must not cross a path separator when the pattern anchors a directory.
        XCTAssertFalse(m("voices/nested/x.safetensors", "voices/*.safetensors"))
        XCTAssertFalse(m("model-1.bin", "model-????.bin"))
    }

    // MARK: - The default probe

    func testFullSnapshotSatisfiesGlobs() throws {
        try makeSnapshot(repo: "org/full", files: ["config.json", "model.safetensors",
                                                  "voices/af.safetensors"])
        let config = ProbeConfig(sources: [
            WeightSource(role: "main", repo: "org/full",
                         matching: ["*.safetensors", "config.json", "voices/*.safetensors"]),
        ])
        XCTAssertTrue(config.missingWeightSources(storeRoot: root).isEmpty)
    }

    func testPartialSnapshotWithAMissingGlobReadsAsMissing() throws {
        // Half-materialized must read MISSING, not "present but degraded" — the strict rule that
        // stops a package silently loading without its voices/LoRA/tokenizer files.
        try makeSnapshot(repo: "org/partial", files: ["config.json", "model.safetensors"])
        let config = ProbeConfig(sources: [
            WeightSource(role: "main", repo: "org/partial",
                         matching: ["*.safetensors", "voices/*.safetensors"]),
        ])
        XCTAssertEqual(config.missingWeightSources(storeRoot: root).map(\.role), ["main"])
    }

    func testNoGlobsRequiresAWeightOrIndexFile() throws {
        try makeSnapshot(repo: "org/weights", files: ["model.safetensors"])
        try makeSnapshot(repo: "org/index", files: ["config.json"])
        try makeSnapshot(repo: "org/readme", files: ["README.md"])   // no weights, no index

        func missing(_ repo: String) -> [String] {
            ProbeConfig(sources: [WeightSource(role: "main", repo: repo)])
                .missingWeightSources(storeRoot: root).map(\.repo)
        }
        XCTAssertEqual(missing("org/weights"), [])
        XCTAssertEqual(missing("org/index"), [])
        XCTAssertEqual(missing("org/readme"), ["org/readme"])
    }

    func testEmptyAndAbsentSnapshotsReadAsMissing() throws {
        try makeSnapshot(repo: "org/empty", files: [])
        let config = ProbeConfig(sources: [
            WeightSource(role: "empty", repo: "org/empty"),
            WeightSource(role: "absent", repo: "org/absent"),
        ])
        XCTAssertEqual(Set(config.missingWeightSources(storeRoot: root).map(\.role)),
                       ["empty", "absent"])
    }

    func testNilStoreRootMeansEverythingIsMissing() throws {
        // MAT-4 fresh-machine posture: with no store, nothing can be resolved.
        try makeSnapshot(repo: "org/full", files: ["model.safetensors"])
        let config = ProbeConfig(sources: [WeightSource(role: "main", repo: "org/full")])
        XCTAssertEqual(config.missingWeightSources(storeRoot: nil).map(\.role), ["main"])
    }

    func testMultiSourceReportsOnlyTheMissingOnes() throws {
        try makeSnapshot(repo: "org/encoder", files: ["model.safetensors"])
        let config = ProbeConfig(sources: [
            WeightSource(role: "text-encoder", repo: "org/encoder"),
            WeightSource(role: "transformer", repo: "org/transformer"),
        ])
        XCTAssertEqual(config.missingWeightSources(storeRoot: root).map(\.role), ["transformer"])
    }

    func testRevisionPinnedSourceProbesItsOwnRef() throws {
        try makeSnapshot(repo: "org/pinned", files: ["model.safetensors"], ref: "v2", commit: "cafe")
        let pinned = ProbeConfig(sources: [
            WeightSource(role: "main", repo: "org/pinned", revision: "v2"),
        ])
        XCTAssertTrue(pinned.missingWeightSources(storeRoot: root).isEmpty)

        // The default (main) ref was never written, so an unpinned source still reads missing.
        let unpinned = ProbeConfig(sources: [WeightSource(role: "main", repo: "org/pinned")])
        XCTAssertEqual(unpinned.missingWeightSources(storeRoot: root).map(\.role), ["main"])
    }

    // MARK: - MS-4: deletion

    func testRemoveDeletesTheRepoDirectoryAndItsLock() throws {
        let store = ModelStore(root: root)
        try makeSnapshot(repo: "org/name", files: ["model.safetensors"])
        let locks = root.appending(path: ".locks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let lock = locks.appending(path: "models--org--name.lock")
        try Data().write(to: lock)
        // A second repo's lock must survive.
        let otherLock = locks.appending(path: "models--org--other.lock")
        try Data().write(to: otherLock)

        try store.remove(repo: "org/name")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: "org/name")!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherLock.path))
    }

    func testRemoveIsANoOpForAnUnmaterializedRepo() throws {
        XCTAssertNoThrow(try ModelStore(root: root).remove(repo: "org/never-installed"))
        XCTAssertNoThrow(try ModelStore().remove(repo: "org/name"))   // no root at all
    }

    // MARK: - MS-4: deduped size accounting

    func testUsageCountsALinkedBlobOnce() throws {
        let fm = FileManager.default
        let store = ModelStore(root: root)
        let dir = store.directory(for: "org/name")!
        let blobs = dir.appending(path: "blobs", directoryHint: .isDirectory)
        let snapshot = dir.appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: "abc", directoryHint: .isDirectory)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)

        // One 64 KiB blob, reached twice: once by symlink, once by hard link.
        let payload = Data(repeating: 0x7A, count: 64 * 1024)
        let blob = blobs.appending(path: "deadbeef")
        try payload.write(to: blob)
        try fm.createSymbolicLink(at: snapshot.appending(path: "model.safetensors"),
                                  withDestinationURL: blob)
        try fm.linkItem(at: blob, to: snapshot.appending(path: "model-hardlinked.safetensors"))

        store.writeMarker(repo: "org/name", revision: "main", capabilities: [.llm])

        let usage = ModelStore.usage(at: root)
        XCTAssertEqual(usage.installedPackages, 1)
        // The blob is counted ONCE (not 2×/3×); the marker adds its own small allocation.
        let markerBytes = try Data(contentsOf: store.markerURL(for: "org/name")!).count
        XCTAssertGreaterThanOrEqual(usage.bytes, Int64(payload.count))
        XCTAssertLessThan(usage.bytes, Int64(payload.count * 2),
                          "linked blob was double-counted — MS-4 dedup regressed")
        XCTAssertGreaterThan(usage.bytes, Int64(markerBytes))
    }

    // MARK: - Fixtures

    /// A minimal `WeightSourcing` configuration that takes the MS-2 default probe.
    private struct ProbeConfig: WeightSourcing {
        let sources: [WeightSource]
        var weightSources: [WeightSource] { sources }
    }

    @discardableResult
    private func makeSnapshot(repo: String, files: [String],
                              ref: String = "main", commit: String = "abc123") throws -> URL {
        let fm = FileManager.default
        let dir = root.appending(path: ModelStore.repoFolderName(for: repo), directoryHint: .isDirectory)
        let refs = dir.appending(path: "refs", directoryHint: .isDirectory)
        let snapshot = dir.appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: commit, directoryHint: .isDirectory)
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "\(commit)\n".write(to: refs.appending(path: ref), atomically: true, encoding: .utf8)
        for file in files {
            let url = snapshot.appending(path: file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return snapshot
    }
}
