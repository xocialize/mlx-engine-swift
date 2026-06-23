/// Init-time configuration for a tool. Stable for the session — weights id, quant, backend
/// preference, memory budget. Distinct from the per-request envelope (C9): anything that
/// changes call-to-call (mode, temperature, input artifacts) belongs on the request, never
/// here. The engine passes a `PackageConfiguration` through generically as the tool
/// initializer input. Conformers should be defaultable where sensible.
public protocol PackageConfiguration: Codable, Sendable {}

/// Opt-in capability for quantization-tiered configs: exposes the selected `quant` so the memory
/// governor charges the matching declared `QuantFootprint` (ISSUES W1) instead of guessing the
/// largest-that-fits — which under-reserves a bf16 registration whenever the bf16 footprint exceeds
/// budget (the governor then silently charges the smaller int4 figure) and over-reserves otherwise.
/// Detected by `as?` at registration, mirroring the `ModelStorable` opt-in pattern. Configs that
/// already store `var quant: Quant` conform with an empty extension; non-conformers fall back to the
/// largest-that-fits heuristic (correct for single-footprint manifests).
public protocol QuantConfigured {
    var quant: Quant { get }
}

/// Ordered backend preference (first feasible wins at placement time).
public struct BackendPreference: Sendable, Codable, Equatable {
    public let ordered: [Backend]
    public init(_ ordered: [Backend]) { self.ordered = ordered }
}

/// A ready-made configuration covering the common knobs. Packages may use it directly or
/// compose their own conformer with extra fields.
public struct StandardConfiguration: PackageConfiguration, QuantConfigured {
    public var weightsRepo: String      // e.g. "mlx-community/<name>-<quant>"
    public var revision: String?        // pinned revision (provenance)
    public var quant: Quant
    public var backendPreference: BackendPreference
    public var memoryBudgetBytes: UInt64?

    public init(weightsRepo: String,
                revision: String? = nil,
                quant: Quant = .bf16,
                backendPreference: BackendPreference = BackendPreference([.metalGPU]),
                memoryBudgetBytes: UInt64? = nil) {
        self.weightsRepo = weightsRepo
        self.revision = revision
        self.quant = quant
        self.backendPreference = backendPreference
        self.memoryBudgetBytes = memoryBudgetBytes
    }
}
