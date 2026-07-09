import Foundation

/// One weight source vendored in the package's own resource bundle — present the moment the
/// binary exists, never downloaded.
///
/// The bundled counterpart of `WeightSource`: where a network source is *required missing* on a
/// fresh machine (and materialized by `load()`), a bundled source is *required present* — the
/// MAT gate verifies the resolved URL exists so a stripped or misdeclared resource fails the
/// package's own conformance suite, not the user's first inference. Not `Codable`: the URL is
/// build/machine-specific (it points into the built bundle), unlike a portable `org/name` repo id.
public struct BundledWeightSource: Sendable, Equatable {
    /// Stable role tag within the package ("checkpoint", "vocoder", …) — keys gate reports and
    /// UI labels. Shares one role namespace with any network `WeightSource` roles the same
    /// configuration declares (MAT-3 uniqueness spans both sets).
    public let role: String
    /// The resolved in-bundle URL; `nil` when the resource lookup failed (e.g. a stripped
    /// bundle). Declare the lookup result directly — the gate treats `nil` as a failure.
    public let url: URL?

    public init(role: String, url: URL?) {
        self.role = role
        self.url = url
    }
}

/// A `PackageConfiguration` whose weights (or some of them) ship vendored in the binary's
/// resource bundle.
///
/// Complements `WeightSourcing`: a **bundled-only** package (e.g. Real-ESRGAN's ~2 MB
/// SRVGGNetCompact checkpoints) conforms to this *instead of* `WeightSourcing` — it has no
/// fresh-machine network source, so declaring one would either report a dishonest missing set
/// or force a download of weights already in the binary. A **hybrid** package conforms to both;
/// the MAT gate then requires the network subset missing and the bundled subset present on a
/// fresh machine. A bundled-only configuration whose sources all resolve makes
/// `MLXServeEngine.needsDownload` read `false` — the sanctioned signal, replacing the
/// always-present-`prewarmPaths` workaround (`WeightPrewarming` remains valuable for its own
/// purpose: cold-start page-in before `load()`).
public protocol BundledWeightSourcing {
    /// Every vendored source this configuration loads from the bundle (fixed by the
    /// configuration — e.g. the selected variant picks which checkpoint appears).
    var bundledWeightSources: [BundledWeightSource] { get }
}
