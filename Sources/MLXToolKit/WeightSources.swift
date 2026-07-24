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
/// Complements `ModelStorable` (where weights go) with WHAT would be fetched. Since contract
/// 1.24 the ENGINE executes first-run materialization from this declaration (before `load()`,
/// with `WeightDownloadProgress` bound so the download phase is observable) — `load()` just
/// loads. A package that must keep executing its own downloads opts out via
/// `SelfMaterializing`; a package that still self-materializes defensively stays correct,
/// because its own missing-check runs after the engine's executor and finds nothing left.
/// The declaration also lets the conformance suite and measurement harness reason about
/// first-run behavior generically — the seam behind the per-package materialization gate.
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

    /// Default probe (MS-2): a source is present when its materialized files under the store
    /// satisfy the source's declaration.
    ///
    /// Two layouts are accepted per source, either one satisfies:
    /// - the hub-client snapshot, via `ModelStore.snapshotDirectory(for:revision:)`
    ///   (`snapshots/<commit>/…` behind `refs/`);
    /// - the engine-executed flat layout (contract 1.24), files directly under
    ///   `ModelStore.directory(for:)` — where `MLXServeEngine`'s own materializer lands them.
    ///
    /// The satisfaction rule is the same for both:
    /// - no store root, or no materialized directory → **missing** (fresh-machine posture, MAT-4);
    /// - `matching` globs declared → **every** glob must match at least one file
    ///   (a half-materialized source reads as missing rather than silently degrading);
    /// - no globs → the directory must carry at least one weight file (`*.safetensors`, `*.gguf`,
    ///   `*.npz`, `*.bin`) or a model index/config (`model.safetensors.index.json`, `config.json`,
    ///   `model_index.json`) — a bare directory is not a materialized model.
    ///
    /// Presence, not integrity: content verification is the downloader's job (size check in the
    /// engine's materializer; xet chunk hashes / ETags in swift-huggingface).
    func missingWeightSources(storeRoot: URL?) -> [WeightSource] {
        defaultMissingWeightSources(storeRoot: storeRoot)
    }

    /// The default probe, callable by name from an override that first honors its own explicit
    /// local paths (the common shape — `modelDirectory` escape hatch, then the store).
    func defaultMissingWeightSources(storeRoot: URL?) -> [WeightSource] {
        guard storeRoot != nil else { return weightSources }
        let store = ModelStore(root: storeRoot)
        return weightSources.filter { source in
            if let snapshot = store.snapshotDirectory(for: source.repo, revision: source.revision),
               WeightSourceProbe.snapshot(snapshot, satisfies: source.matching) { return false }
            if let flat = store.directory(for: source.repo),
               WeightSourceProbe.flatDirectory(flat, satisfies: source.matching) { return false }
            return true
        }
    }
}

/// A `WeightSourcing` configuration whose PACKAGE executes first-run materialization itself —
/// the opt-out from the engine-executed default (contract 1.24).
///
/// Conform when the engine's generic executor cannot do the job: weights served from a non-HF
/// host, or a Path-A wrapper whose wrapped runtime downloads internally as part of its own
/// startup. The engine then skips its pre-`load()` materialization pass and the package's
/// `load()` remains responsible for fetching everything `missingWeightSources(storeRoot:)`
/// reports (forwarding `WeightDownloadProgress` so the download phase stays observable).
/// Detected by `as?` like `ModelStorable` — a marker, no requirements. Bundled-only packages
/// don't need it: their missing-set is empty by construction.
public protocol SelfMaterializing {}

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
        satisfies(files: relativeFiles(in: snapshot), matching: matching)
    }

    /// Does a repo directory in the engine-executed FLAT layout (contract 1.24 — files directly
    /// under `ModelStore.directory(for:)`, no `snapshots/` indirection) satisfy a source's
    /// declaration? Hub-cache bookkeeping subtrees (`snapshots/`, `refs/`, `blobs/`) and the
    /// engine's install marker are excluded, so a half-materialized hub-client layout can never
    /// read as a satisfied flat one — each layout is judged by its own files.
    public static func flatDirectory(_ directory: URL, satisfies matching: [String]?) -> Bool {
        let hubCache = ["snapshots/", "refs/", "blobs/"]
        let files = relativeFiles(in: directory).filter { path in
            path != ModelStore.markerName && !hubCache.contains { path.hasPrefix($0) }
        }
        return satisfies(files: files, matching: matching)
    }

    private static func satisfies(files: [String], matching: [String]?) -> Bool {
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
