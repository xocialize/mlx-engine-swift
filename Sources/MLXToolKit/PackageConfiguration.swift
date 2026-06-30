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

/// Opt-in for configs whose footprint can't be inferred from `quant` alone — when two configurations
/// at the **same** quant have very different working sets, so `QuantFootprint` (which keys on quant)
/// can't tell them apart. The canonical case is BiRefNet matting: `fast`@1024 ≈ 4.9 GB vs `best`@2048
/// ≈ 18.3 GB, **both fp16** — a 3.6× gap the quant match collapses to one figure, which would charge
/// the affordable tier the expensive tier's bytes and make it inadmissible on small machines.
///
/// `residentBytesHint` lets the config declare the **selected** configuration's resident bytes
/// directly. The value is the **max-over-phase** working set for that variant
/// (`max(encode, dit+activation, decode-transient)` — NOT the sum of phases; per-phase eviction means
/// only one phase is resident at peak), measured with the in-app footprint probe. It takes precedence
/// over the `QuantConfigured` quant match at registration; `nil` falls through to the quant /
/// largest-that-fits resolution, so adopting the protocol is safe even for variants with no special
/// hint. Detected by `as?` at registration, mirroring the `QuantConfigured` / `ModelStorable` opt-ins.
public protocol FootprintConfigured {
    var residentBytesHint: UInt64? { get }
    /// The selected variant's **transient activation peak** (scratch live only during inference, on top
    /// of the persistent weights), when it differs by mode at the same quant — e.g. BiRefNet `best`@2048
    /// has a far larger activation peak than `fast`@1024 though both are fp16. `nil` (the default) falls
    /// back to the matched `QuantFootprint.peakActivationBytes`. Pairs with `residentBytesHint`: the hint
    /// is the persistent weights, this is the transient peak.
    var peakActivationBytesHint: UInt64? { get }
}

public extension FootprintConfigured {
    var peakActivationBytesHint: UInt64? { nil }
}

/// Opt-in for configs whose `load()` adapts to the memory it's actually given — e.g. choosing a lighter
/// weight/compute dtype (fp8 vs bf16 vs fp32) when headroom is tight, the way ComfyUI's `unet_dtype`
/// picks precision by free memory. The engine stamps `availableBudgetBytes` from the governor **at load
/// time** (after admission/eviction), so the value reflects the real headroom the model is loading into.
/// Detected by `as?` like `ModelStorable` / `QuantConfigured`; non-conformers are unaffected. `nil` means
/// the engine had no figure to provide (load with the configured default).
public protocol BudgetAware {
    var availableBudgetBytes: UInt64? { get set }
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
