import Foundation

/// One network source of weights a configuration materializes from on a fresh machine.
///
/// Declared (not discovered): a `WeightSourcing` configuration states every source it would need
/// with nothing on disk, which makes first-run materialization **checkable** offline
/// (`MaterializationConformance`), **measurable** per package (`MLXEngineTestKit.
/// MaterializationRun`), and **previewable** (a download UI can show repos/sizes before any
/// package code runs). Multi-source packages are normal — e.g. a video package may pull a
/// component collection, a text-encoder repo, and a quantized-transformer repo.
public struct WeightSource: Sendable, Equatable, Codable {
    /// Stable role tag within the package ("components", "text-encoder", "transformer-int8", …) —
    /// keys per-source progress, measurement, and UI labels.
    public let role: String
    /// Hugging Face repo id ("org/name").
    public let repo: String
    /// Pinned revision; `nil` = main.
    public let revision: String?
    /// File globs to fetch within the repo; `nil`/empty = the whole snapshot. Lets a quantized
    /// configuration skip sibling files it doesn't need (e.g. a 35 GB bf16 transformer).
    public let matching: [String]?

    public init(role: String, repo: String, revision: String? = nil, matching: [String]? = nil) {
        self.role = role
        self.repo = repo
        self.revision = revision
        self.matching = matching
    }
}

/// A `PackageConfiguration` that declares its weight sources.
///
/// Complements `ModelStorable` (where weights go) with WHAT would be fetched: the package's
/// `load()` remains the executor (native downloader, `WeightDownloadProgress` forwarding), but
/// the declaration lets the engine, conformance suite, and measurement harness reason about
/// first-run behavior generically — this is the seam behind the per-package materialization gate.
public protocol WeightSourcing {
    /// Every source this configuration needs on a fresh machine (fixed by the configuration —
    /// e.g. the quant selects which transformer repo appears).
    var weightSources: [WeightSource] { get }

    /// The subset still missing on THIS machine: honors the configuration's explicit local paths
    /// first, then probes the canonical store layout under `storeRoot`
    /// (`<root>/models--<org>--<name>/snapshots/<commit>/…`).
    /// `storeRoot == nil` with no explicit paths ⇒ everything is missing.
    ///
    /// **A default implementation is provided** (MS-2) and is the right answer for any package
    /// whose weights land in the store through a normal hub client. Override only for an exotic
    /// layout — e.g. a configuration with an explicit `modelDirectory` escape hatch, which must be
    /// consulted *before* falling back to `defaultMissingWeightSources(storeRoot:)`.
    func missingWeightSources(storeRoot: URL?) -> [WeightSource]
}

public extension WeightSourcing {

    /// Default probe (MS-2): a source is present when its snapshot is materialized under the store
    /// and satisfies the source's declaration.
    ///
    /// Per source, via `ModelStore.snapshotDirectory(for:revision:)`:
    /// - no store root, or no snapshot directory → **missing** (fresh-machine posture, MAT-4);
    /// - `matching` globs declared → **every** glob must match at least one file in the snapshot
    ///   (a half-materialized snapshot reads as missing rather than silently degrading);
    /// - no globs → the snapshot must carry at least one weight file (`*.safetensors`, `*.gguf`,
    ///   `*.npz`, `*.bin`) or a model index/config (`model.safetensors.index.json`, `config.json`,
    ///   `model_index.json`) — a bare directory is not a materialized model.
    ///
    /// Presence, not integrity: content verification is the hub client's job (xet chunk hashes /
    /// ETags in swift-huggingface).
    func missingWeightSources(storeRoot: URL?) -> [WeightSource] {
        defaultMissingWeightSources(storeRoot: storeRoot)
    }

    /// The default probe, callable by name from an override that first honors its own explicit
    /// local paths (the common shape — `modelDirectory` escape hatch, then the store).
    func defaultMissingWeightSources(storeRoot: URL?) -> [WeightSource] {
        guard storeRoot != nil else { return weightSources }
        let store = ModelStore(root: storeRoot)
        return weightSources.filter { source in
            guard let snapshot = store.snapshotDirectory(for: source.repo, revision: source.revision)
            else { return true }
            return !WeightSourceProbe.snapshot(snapshot, satisfies: source.matching)
        }
    }
}

/// The file-level half of the MS-2 default probe, factored out so it is testable on its own and
/// reusable by a package that overrides `missingWeightSources` for a non-store layout.
public enum WeightSourceProbe {

    /// Files that, on their own, make a directory a plausibly-materialized model snapshot.
    private static let weightExtensions: Set<String> = ["safetensors", "gguf", "npz", "bin"]
    private static let indexFiles: Set<String> = [
        "model.safetensors.index.json", "config.json", "model_index.json",
    ]

    /// Does `snapshot` satisfy a source's `matching` declaration? See
    /// `WeightSourcing.missingWeightSources(storeRoot:)` for the rule.
    public static func snapshot(_ snapshot: URL, satisfies matching: [String]?) -> Bool {
        let files = relativeFiles(in: snapshot)
        guard !files.isEmpty else { return false }

        if let globs = matching, !globs.isEmpty {
            return globs.allSatisfy { glob in
                files.contains { matches(path: $0, glob: glob) }
            }
        }

        return files.contains { path in
            let name = (path as NSString).lastPathComponent
            return weightExtensions.contains((name as NSString).pathExtension.lowercased())
                || indexFiles.contains(name)
        }
    }

    /// Every regular file under `root`, as a path relative to it. Symlinks are *not* resolved —
    /// an HF snapshot is a tree of symlinks into `blobs/`, and the link's own presence is the
    /// signal we want (a broken link still reads as present; content is the hub client's problem).
    static func relativeFiles(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles])
        else { return [] }
        let prefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let url as URL in walker {
            // A symlink to a blob reports isRegularFile == false, so accept anything that isn't a
            // directory rather than requiring a regular file.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            let path = url.standardizedFileURL.path
            out.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }
        return out
    }

    /// `fnmatch`-style glob matching over a snapshot-relative path — no new dependency.
    ///
    /// `*` matches within one path component, `**` spans components, `?` matches one non-`/`
    /// character. A glob with no `/` also matches on the basename alone, so the common
    /// `"*.safetensors"` declaration finds `some/nested/model.safetensors` the way the hub's own
    /// allow-patterns do.
    public static func matches(path: String, glob: String) -> Bool {
        if matches(path: path[...], pattern: glob[...]) { return true }
        if !glob.contains("/") {
            let base = (path as NSString).lastPathComponent
            return matches(path: base[...], pattern: glob[...])
        }
        return false
    }

    /// Backtracking matcher over the two substrings. Linear in practice for our patterns (a couple
    /// of wildcards over short paths).
    private static func matches(path: Substring, pattern: Substring) -> Bool {
        if pattern.isEmpty { return path.isEmpty }

        if pattern.hasPrefix("**") {
            var rest = pattern.dropFirst(2)
            if rest.hasPrefix("/") { rest = rest.dropFirst() }   // "**/x" also matches "x"
            if matches(path: path, pattern: rest) { return true }
            guard !path.isEmpty else { return false }
            return matches(path: path.dropFirst(), pattern: pattern)
        }

        let head = pattern.first!
        switch head {
        case "*":
            let rest = pattern.dropFirst()
            if matches(path: path, pattern: rest) { return true }
            guard let first = path.first, first != "/" else { return false }
            return matches(path: path.dropFirst(), pattern: pattern)
        case "?":
            guard let first = path.first, first != "/" else { return false }
            return matches(path: path.dropFirst(), pattern: pattern.dropFirst())
        default:
            guard path.first == head else { return false }
            return matches(path: path.dropFirst(), pattern: pattern.dropFirst())
        }
    }
}
