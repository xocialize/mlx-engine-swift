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

    /// Filename of the per-package marker the storage UI counts (one per installed package).
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
    /// Read-only compatibility: markers written by an older engine still count. **Remove after the
    /// next minor release** (MS-1 legacy tolerance window).
    public func legacyDirectory(for repo: String) -> URL? {
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
        for dir in [directory(for: repo), legacyDirectory(for: repo)].compactMap({ $0 }) {
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
        } catch {
            // Best-effort marker — the weights still loaded; the panel just won't count this one.
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
