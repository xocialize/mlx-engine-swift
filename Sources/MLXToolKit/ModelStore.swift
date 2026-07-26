import Foundation

/// The engine-owned **model store**: the single on-disk root every package's weights are
/// materialized under, plus the per-package marker the storage UI counts.
///
/// This is deliberately Foundation-only — it carries no Hugging Face dependency. A package keeps
/// using its *native* downloader (mlx-swift-lm, mlx-audio, swift-transformers, …), but pointed at
/// this store's `root`; the engine stamps `modelsRootDirectory` onto the package's configuration
/// before construction (see `ModelStorable`) and writes the marker after a successful `load()`. So
/// a consuming app sets the store **once** on the engine instead of threading the chosen folder
/// into every package and writing markers by hand.
///
/// **Layout (canonicalized 2026-07, MS-1).** The store follows the **Hugging Face cache
/// convention**, because that is where the hub clients every package uses (`swift-huggingface`,
/// mlx-swift-lm, mlx-audio, …) actually materialize weights:
///
/// ```
/// <root>/models--<org>--<name>/     one repo directory (`/` → `--`)
///     mlx-package.json             the engine's install marker (sibling of refs/)
///     refs/main                    → commit hash
///     snapshots/<hash>/…           the files (symlinks into blobs/)
///     blobs/…                      the content-addressed bytes
/// ```
///
/// Before MS-1 the store computed `<root>/<org>/<name>/`, so the marker and the `needsDownload`
/// probe pointed at a directory the weights never landed in (only the storage panel's recursive
/// scan papered over it). Marker *reads* still fall back to the old path for one release
/// (read-both, write-new — see `legacyDirectory(for:)`); there is no data migration, markers are
/// cheap and regenerate on the next `load()`.
///
/// Weight **integrity** is the hub client's responsibility (xet chunk hashes / ETag verification in
/// swift-huggingface); the engine verifies presence, not content.
public struct ModelStore: Sendable, Equatable {
    /// Root of the chosen models folder. `nil` → packages fall back to their default cache and no
    /// marker is written (the storage panel simply won't track those models).
    public let root: URL?

    /// Filename of the install marker the storage UI counts. The engine stamps one per declared
    /// `WeightSource` repo (falling back to the manifest's provenance repo for configurations that
    /// declare no sources), so a multi-source package carries one marker per repo it materialized.
    public static let markerName = "mlx-package.json"

    public init(root: URL? = nil) {
        self.root = root
    }

    /// The HF-cache folder name for a repo id: `mlx-community/Kokoro-82M` → `models--mlx-community--Kokoro-82M`.
    public static func repoFolderName(for repo: String) -> String {
        "models--" + repo.split(separator: "/").joined(separator: "--")
    }

    /// The per-repo directory under the store, `<root>/models--<org>--<name>/`, or `nil` without a
    /// root. This is the directory the hub client materializes into and the marker is written to.
    public func directory(for repo: String) -> URL? {
        guard let root else { return nil }
        return root.appending(path: Self.repoFolderName(for: repo), directoryHint: .isDirectory)
    }

    /// The pre-MS-1 per-repo directory, `<root>/<org>/<name>/`.
    ///
    /// Read-only compatibility for markers written by a pre-1.22.0 engine.
    ///
    /// **Why this can't just be deleted, and when it can (revised 2026-07-26).** The original note
    /// said "remove after the next minor" — a bad criterion: five minors elapsed in four days while
    /// real installs were still days old. What matters is not the version count but whether a
    /// legacy marker can still be *load-bearing*, and it can: MS-1 moved the **marker**, never the
    /// **weights** (`HubClient` always wrote `models--<org>--<name>/`). So a legacy marker is a
    /// truthful "this repo is installed" signal, and dropping the fallback would make
    /// `needsDownload` report `true` for weights that are present — a spurious multi-GB
    /// re-download.
    ///
    /// The window is now **self-closing per repo** instead of open-ended: `writeMarker` migrates a
    /// legacy marker to the canonical path (and deletes the old one) on the next successful load, so
    /// the fallback stops being consulted for that repo forever. Removal is safe once you accept
    /// that a repo *never loaded* since 1.22.0 re-probes — i.e. after one release in which users
    /// have plausibly exercised their installed models, not after an arbitrary minor bump.
    @available(*, deprecated, message: "Pre-1.22.0 marker compatibility only; migrated automatically by writeMarker. Do not build new behavior on this path.")
    public func legacyDirectory(for repo: String) -> URL? { legacyDirectoryPath(for: repo) }

    /// Non-deprecated inner spelling so the store's own compatibility reads don't warn.
    func legacyDirectoryPath(for repo: String) -> URL? {
        guard let root else { return nil }
        return repo.split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }

    /// The materialized snapshot directory for a repo — `<repo dir>/snapshots/<commit>/`, resolved
    /// through `refs/<revision>` (default `main`) — or `nil` when nothing is materialized.
    ///
    /// This is the directory a presence probe should look inside (`WeightSourcing.
    /// missingWeightSources`): the repo directory exists as soon as a download *starts*, but the
    /// snapshot only carries files once one has landed.
    public func snapshotDirectory(for repo: String, revision: String? = nil) -> URL? {
        guard let dir = directory(for: repo) else { return nil }
        let ref = revision ?? "main"
        // A revision may itself be a commit hash — accept a snapshot directly under that name.
        let direct = dir.appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: ref, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let refFile = dir.appending(path: "refs", directoryHint: .isDirectory)
            .appending(path: ref, directoryHint: .notDirectory)
        guard let raw = try? String(contentsOf: refFile, encoding: .utf8) else { return nil }
        let commit = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { return nil }
        let snapshot = dir.appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: commit, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: snapshot.path) ? snapshot : nil
    }

    /// The install marker for a repo if one exists — the canonical location first, then the
    /// pre-MS-1 one (read-both, write-new). `nil` when neither is present or there is no root.
    public func markerURL(for repo: String) -> URL? {
        for dir in [directory(for: repo), legacyDirectoryPath(for: repo)].compactMap({ $0 }) {
            let marker = dir.appending(path: Self.markerName, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: marker.path) { return marker }
        }
        return nil
    }

    /// Whether this repo carries an install marker (canonical or legacy location).
    public func hasMarker(for repo: String) -> Bool { markerURL(for: repo) != nil }

    /// Write the marker the storage UI counts for an installed package. Best-effort: a no-op when
    /// there is no `root`, and failures are swallowed (the panel tolerates a missing marker). The
    /// caller must hold security-scoped access to `root` (the app does, via its bookmark).
    ///
    /// Also **migrates** a pre-MS-1 marker: once the canonical one is written, the legacy copy is
    /// removed so `markerURL`'s compatibility fallback stops being consulted for this repo. That is
    /// what makes the MS-1 tolerance window self-closing rather than open-ended — see
    /// `legacyDirectory(for:)`.
    public func writeMarker(repo: String, revision: String, capabilities: [Capability]) {
        guard let dir = directory(for: repo) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "repo": repo,
                "revision": revision,
                "capabilities": capabilities.map(\.rawValue).sorted(),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dir.appending(path: Self.markerName))
            retireLegacyMarker(for: repo)
        } catch {
            // Best-effort marker — the weights still loaded; the panel just won't count this one.
        }
    }

    /// Delete a pre-MS-1 marker once the canonical one exists, and the directory that held it if
    /// nothing else is in there. Best-effort and deliberately narrow: it removes **only** the
    /// marker file, never weights — the legacy layout only ever held the marker.
    private func retireLegacyMarker(for repo: String) {
        guard let legacy = legacyDirectoryPath(for: repo),
              legacy != directory(for: repo) else { return }
        let marker = legacy.appending(path: Self.markerName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        // Prune the now-empty `<root>/<org>/<name>` (and a childless `<root>/<org>`) so the store
        // doesn't keep orphan directories the storage panel would walk forever.
        for dir in [legacy, legacy.deletingLastPathComponent()] {
            guard dir != root,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                  entries.isEmpty else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// What a store root currently costs on disk, and how many packages are installed in it.
    public struct Usage: Sendable, Equatable {
        /// On-disk allocated bytes, **each distinct file counted once** (see `usage(at:)`).
        public let bytes: Int64
        /// Number of `mlx-package.json` markers found — one per materialized source repo (a
        /// multi-source package stamps one marker per declared `WeightSource` repo).
        public let installedPackages: Int

        public init(bytes: Int64, installedPackages: Int) {
            self.bytes = bytes
            self.installedPackages = installedPackages
        }
    }

    /// One materialized repo in a store root, for the storage UI's per-model list (MS-4).
    public struct InstalledModel: Sendable, Equatable, Identifiable {
        /// The repo id, e.g. `mlx-community/Kokoro-82M`.
        public let repo: String
        /// On-disk allocated bytes for this repo's directory, link-deduped like `Usage.bytes`.
        public let bytes: Int64
        /// Whether an install marker is present (an in-flight download has a directory but no
        /// marker yet, so the UI can label it rather than pretend it is installed).
        public let hasMarker: Bool

        public var id: String { repo }

        public init(repo: String, bytes: Int64, hasMarker: Bool) {
            self.repo = repo
            self.bytes = bytes
            self.hasMarker = hasMarker
        }
    }

    /// The repos materialized in a store root, newest-largest first, for a per-model UI (MS-4).
    ///
    /// Reads the canonical layout only — one entry per top-level `models--<org>--<name>/`. The repo
    /// id comes from the marker's `repo` field when present (authoritative, since a name may itself
    /// contain `--`) and is otherwise decoded from the folder name. Static and `nonisolated` for the
    /// same reason as `usage(at:)`: the panel calls it for a folder off the main actor. The caller
    /// must hold security-scoped access to `root`.
    public static func installedModels(at root: URL) -> [InstalledModel] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
            ?? []
        return entries.compactMap { dir -> InstalledModel? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  dir.lastPathComponent.hasPrefix("models--") else { return nil }
            let marker = dir.appending(path: markerName, directoryHint: .notDirectory)
            let declared = (try? Data(contentsOf: marker))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["repo"] as? String }
            let repo = declared ?? dir.lastPathComponent
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")
            return InstalledModel(repo: repo,
                                  bytes: usage(at: dir).bytes,
                                  hasMarker: FileManager.default.fileExists(atPath: marker.path))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Walk a store root once, summing on-disk size and counting install markers (MS-4).
    ///
    /// **Deduped by file identity.** The store follows the HF cache convention, where a snapshot is
    /// a tree of links into `blobs/`; counting a blob *and* its link (or two hard links to one
    /// blob) would report double the real disk use, so each distinct `fileResourceIdentifierKey`
    /// is summed once. Markers are counted per path — one per installed package, never linked.
    ///
    /// Static (root-taking) so the storage UI can call it for a folder the user is merely
    /// previewing. The caller must hold security-scoped access to `root`.
    public static func usage(at root: URL) -> Usage {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .fileResourceIdentifierKey,
        ]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        else { return Usage(bytes: 0, installedPackages: 0) }

        var total: Int64 = 0
        var markers = 0
        var counted = Set<AnyHashable>()
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory != true else { continue }
            if url.lastPathComponent == markerName { markers += 1 }

            // A symlink carries no size of its own — resolve it to the blob it points at, then let
            // the identity check decide whether that blob has already been summed.
            let target = values.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
            guard let resolved = try? target.resourceValues(forKeys: keys) else { continue }
            if let identity = resolved.fileResourceIdentifier as? AnyHashable,
               !counted.insert(identity).inserted { continue }
            if let allocated = resolved.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let size = resolved.fileSize {
                total += Int64(size)
            }
        }
        return Usage(bytes: total, installedPackages: markers)
    }

    /// Delete a repo's materialized weights (MS-4): the whole `models--<org>--<name>/` directory
    /// plus the hub client's sibling `.locks/models--<org>--<name>*` entries.
    ///
    /// A no-op when the repo isn't materialized (or there is no root); throws whatever
    /// `FileManager` throws on a real failure, so a caller can surface it. **Unguarded** — the
    /// residency guard lives on the engine (`MLXServeEngine.deleteWeights(repo:)`), which is the
    /// only component that knows what is loaded. The caller must hold security-scoped access to
    /// `root`.
    public func remove(repo: String) throws {
        guard let root, let dir = directory(for: repo) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        // Locks are named after the repo folder, sometimes with a revision suffix.
        let locks = root.appending(path: ".locks", directoryHint: .isDirectory)
        let folder = Self.repoFolderName(for: repo)
        for entry in (try? fm.contentsOfDirectory(atPath: locks.path)) ?? []
        where entry == folder || entry.hasPrefix(folder) {
            try fm.removeItem(at: locks.appending(path: entry))
        }
    }
}

/// A `PackageConfiguration` that can be redirected to the engine's `ModelStore` root.
///
/// The engine stamps `modelsRootDirectory` from its store onto the configuration **before**
/// constructing the package, so a package's `load()` only has to point its native downloader at
/// `modelsRootDirectory` (when non-`nil`). Configurations that don't conform are left untouched and
/// fall back to the default cache.
public protocol ModelStorable {
    /// Where weights should be materialized. The engine sets this from its `ModelStore.root`; when
    /// `nil`, the package uses its downloader's default cache.
    var modelsRootDirectory: URL? { get set }
}
