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

    /// The pre-MS-1 path, spelled out here rather than read from the (deprecated) accessor so these
    /// tests keep pinning the layout after that accessor is finally removed.
    private func legacyPath(_ repo: String = "org/name") -> URL {
        repo.split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }

    func testLegacyDirectoryIsThePreMS1Path() {
        XCTAssertEqual(legacyPath(), root.appending(path: "org", directoryHint: .isDirectory)
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
        let legacy = legacyPath()
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appending(path: ModelStore.markerName))

        // Read-both: a marker written by a pre-MS-1 engine still counts. This is load-bearing —
        // MS-1 moved the marker, never the weights, so a legacy marker truthfully means "installed"
        // and dropping the fallback would re-download weights that are already on disk.
        XCTAssertTrue(store.hasMarker(for: "org/name"))
        XCTAssertEqual(store.markerURL(for: "org/name")?.deletingLastPathComponent()
                            .standardizedFileURL, legacy.standardizedFileURL)

        // …but write-new, and the canonical location wins once it exists.
        store.writeMarker(repo: "org/name", revision: "main", capabilities: [.llm])
        XCTAssertEqual(store.markerURL(for: "org/name")?.deletingLastPathComponent().lastPathComponent,
                       "models--org--name")
    }

    /// The MS-1 tolerance window is self-closing: writing the canonical marker retires the legacy
    /// one, so the compatibility fallback is consulted at most once per repo.
    func testWritingTheMarkerMigratesAndRetiresTheLegacyOne() throws {
        let store = ModelStore(root: root)
        let legacy = legacyPath()
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appending(path: ModelStore.markerName))

        store.writeMarker(repo: "org/name", revision: "abc123", capabilities: [.llm])

        // Canonical marker present and authoritative…
        let marker = try XCTUnwrap(store.markerURL(for: "org/name"))
        XCTAssertEqual(marker.deletingLastPathComponent().lastPathComponent, "models--org--name")
        // …legacy marker gone, and its empty directories pruned rather than left as orphans.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacy.appending(path: ModelStore.markerName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appending(path: "org", directoryHint: .isDirectory).path))
        // The repo still reads as installed throughout — the point of migrating rather than deleting.
        XCTAssertTrue(store.hasMarker(for: "org/name"))
    }

    // MARK: - Per-model enumeration (MS-4 UI)

    func testInstalledModelsListsCanonicalReposWithSizes() throws {
        let store = ModelStore(root: root)
        for repo in ["org/small", "org/big"] {
            let snapshot = try XCTUnwrap(store.directory(for: repo))
                .appending(path: "snapshots", directoryHint: .isDirectory)
                .appending(path: "abc", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            let bytes = repo == "org/big" ? 40_000 : 400
            try Data(repeating: 0x41, count: bytes)
                .write(to: snapshot.appending(path: "model.safetensors"))
            store.writeMarker(repo: repo, revision: "abc", capabilities: [.llm])
        }

        let models = ModelStore.installedModels(at: root)
        // Largest first, so the panel leads with what is worth reclaiming.
        XCTAssertEqual(models.map(\.repo), ["org/big", "org/small"])
        XCTAssertTrue(models.allSatisfy(\.hasMarker))
        XCTAssertGreaterThan(try XCTUnwrap(models.first).bytes, 40_000 - 1)
    }

    /// A directory exists as soon as a download starts, so a repo with no marker must be listed but
    /// flagged — never counted as installed.
    func testInstalledModelsFlagsAnUnmarkedRepo() throws {
        let store = ModelStore(root: root)
        let dir = try XCTUnwrap(store.directory(for: "org/partial"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let models = ModelStore.installedModels(at: root)
        XCTAssertEqual(models.map(\.repo), ["org/partial"])
        XCTAssertFalse(try XCTUnwrap(models.first).hasMarker)
    }

    /// The marker's `repo` field wins over folder-name decoding — a name containing `--` cannot be
    /// recovered from the folder alone.
    func testInstalledModelsPrefersTheMarkersRepoField() throws {
        let store = ModelStore(root: root)
        let repo = "org/name--with--dashes"
        let dir = try XCTUnwrap(store.directory(for: repo))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.writeMarker(repo: repo, revision: "abc", capabilities: [.llm])

        XCTAssertEqual(ModelStore.installedModels(at: root).map(\.repo), [repo])
    }

    /// Non-store directories in a chosen folder are ignored rather than listed as models.
    func testInstalledModelsIgnoresForeignDirectories() throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: "Documents", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        XCTAssertTrue(ModelStore.installedModels(at: root).isEmpty)
    }

    /// Migration must never touch a sibling that happens to live under the same `<root>/<org>/`.
    func testLegacyPruneLeavesSiblingsAlone() throws {
        let store = ModelStore(root: root)
        let legacy = legacyPath()
        let sibling = root.appending(path: "org", directoryHint: .isDirectory)
                          .appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appending(path: ModelStore.markerName))
        try Data("{}".utf8).write(to: sibling.appending(path: ModelStore.markerName))

        store.writeMarker(repo: "org/name", revision: "abc123", capabilities: [.llm])

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        // `<root>/org` still holds `other`, so it survives — and that sibling's marker is intact.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sibling.appending(path: ModelStore.markerName).path))
        XCTAssertTrue(store.hasMarker(for: "org/other"))
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
