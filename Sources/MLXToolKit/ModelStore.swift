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
/// The storage panel scans `root` recursively, so a package's exact sub-layout under `root`
/// (`<org>/<repo>` vs `models/<org>/<repo>`) doesn't matter for the disk-used total or the marker
/// count — only that the weights and the marker both live somewhere under `root`.
public struct ModelStore: Sendable, Equatable {
    /// Root of the chosen models folder. `nil` → packages fall back to their default cache and no
    /// marker is written (the storage panel simply won't track those models).
    public let root: URL?

    /// Filename of the per-package marker the storage UI counts (one per installed package).
    public static let markerName = "mlx-package.json"

    public init(root: URL? = nil) {
        self.root = root
    }

    /// The logical per-repo directory under the store, `root/<org>/<name>`, or `nil` without a root.
    public func directory(for repo: String) -> URL? {
        guard let root else { return nil }
        return repo.split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }

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
