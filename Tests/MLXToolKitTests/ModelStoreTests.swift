import XCTest
@testable import MLXToolKit

/// MS-1 — the store layout is the **HF cache convention**, because that is where every package's
/// hub client actually materializes weights. Before MS-1 the store computed `<root>/<org>/<name>/`
/// and the marker/probe pointed at a directory the weights never landed in.
final class ModelStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "ModelStoreTests-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Layout

    func testDirectoryUsesHubCacheConvention() {
        let store = ModelStore(root: root)
        XCTAssertEqual(store.directory(for: "mlx-community/Kokoro-82M-bf16")?.lastPathComponent,
                       "models--mlx-community--Kokoro-82M-bf16")
        // A bare repo id (no org) still gets the prefix.
        XCTAssertEqual(store.directory(for: "Kokoro")?.lastPathComponent, "models--Kokoro")
    }

    func testDirectoryIsNilWithoutRoot() {
        XCTAssertNil(ModelStore().directory(for: "org/name"))
        XCTAssertNil(ModelStore().snapshotDirectory(for: "org/name"))
        XCTAssertNil(ModelStore().markerURL(for: "org/name"))
    }

    func testLegacyDirectoryIsThePreMS1Path() {
        let store = ModelStore(root: root)
        let legacy = store.legacyDirectory(for: "org/name")
        XCTAssertEqual(legacy, root.appending(path: "org", directoryHint: .isDirectory)
                                   .appending(path: "name", directoryHint: .isDirectory))
    }

    // MARK: - Snapshot resolution

    func testSnapshotDirectoryResolvesRefToCommit() throws {
        let store = ModelStore(root: root)
        let commit = "abc123def"
        let snapshot = try makeHFLayout(repo: "org/name", commit: commit, files: ["config.json"])

        XCTAssertEqual(store.snapshotDirectory(for: "org/name")?.standardizedFileURL,
                       snapshot.standardizedFileURL)
        // Explicit revision names the ref file.
        XCTAssertEqual(store.snapshotDirectory(for: "org/name", revision: "main")?.standardizedFileURL,
                       snapshot.standardizedFileURL)
        // A revision that IS a commit hash resolves directly, with no ref indirection.
        XCTAssertEqual(store.snapshotDirectory(for: "org/name", revision: commit)?.standardizedFileURL,
                       snapshot.standardizedFileURL)
    }

    func testSnapshotDirectoryIsNilWhenNothingMaterialized() throws {
        let store = ModelStore(root: root)
        XCTAssertNil(store.snapshotDirectory(for: "org/name"))

        // Repo dir exists (download started) but no ref yet → still nil.
        try FileManager.default.createDirectory(at: store.directory(for: "org/name")!,
                                                withIntermediateDirectories: true)
        XCTAssertNil(store.snapshotDirectory(for: "org/name"))

        // Ref points at a snapshot that isn't there → nil, not a phantom URL.
        let refs = store.directory(for: "org/name")!.appending(path: "refs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try "deadbeef\n".write(to: refs.appending(path: "main"), atomically: true, encoding: .utf8)
        XCTAssertNil(store.snapshotDirectory(for: "org/name"))
    }

    // MARK: - Marker

    func testMarkerRoundTripsInTheCanonicalDirectory() throws {
        let store = ModelStore(root: root)
        XCTAssertFalse(store.hasMarker(for: "org/name"))

        store.writeMarker(repo: "org/name", revision: "main", capabilities: [.llm, .tts])

        let marker = try XCTUnwrap(store.markerURL(for: "org/name"))
        XCTAssertEqual(marker.deletingLastPathComponent().lastPathComponent, "models--org--name")
        XCTAssertEqual(marker.lastPathComponent, ModelStore.markerName)

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker))
                                        as? [String: Any])
        XCTAssertEqual(payload["repo"] as? String, "org/name")
        XCTAssertEqual(payload["revision"] as? String, "main")
        XCTAssertEqual(payload["capabilities"] as? [String], ["llm", "tts"])
    }

    func testMarkerReadFallsBackToTheLegacyLocation() throws {
        let store = ModelStore(root: root)
        let legacy = try XCTUnwrap(store.legacyDirectory(for: "org/name"))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appending(path: ModelStore.markerName))

        // Read-both: a marker written by a pre-MS-1 engine still counts…
        XCTAssertTrue(store.hasMarker(for: "org/name"))
        XCTAssertEqual(store.markerURL(for: "org/name")?.deletingLastPathComponent()
                            .standardizedFileURL, legacy.standardizedFileURL)

        // …but write-new, and the canonical location wins once it exists.
        store.writeMarker(repo: "org/name", revision: "main", capabilities: [.llm])
        XCTAssertEqual(store.markerURL(for: "org/name")?.deletingLastPathComponent().lastPathComponent,
                       "models--org--name")
    }

    // MARK: - Fixture

    /// Build `<root>/models--org--name/{refs/main, snapshots/<commit>/<files>}`; returns the snapshot.
    @discardableResult
    private func makeHFLayout(repo: String, commit: String, files: [String]) throws -> URL {
        let fm = FileManager.default
        let dir = root.appending(path: ModelStore.repoFolderName(for: repo), directoryHint: .isDirectory)
        let refs = dir.appending(path: "refs", directoryHint: .isDirectory)
        let snapshot = dir.appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: commit, directoryHint: .isDirectory)
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        // The hub writes the commit with a trailing newline — the resolver must trim it.
        try "\(commit)\n".write(to: refs.appending(path: "main"), atomically: true, encoding: .utf8)
        for file in files {
            try Data("x".utf8).write(to: snapshot.appending(path: file))
        }
        return snapshot
    }
}
