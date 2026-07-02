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
    /// first, then probes the expected layout under `storeRoot` (`<root>/<org>/<name>/…`).
    /// `storeRoot == nil` with no explicit paths ⇒ everything is missing.
    func missingWeightSources(storeRoot: URL?) -> [WeightSource]
}
