/// Compute backends a model needs. Maps onto the engine's MemoryPool placement.
public enum Backend: String, Sendable, Codable, Hashable, CaseIterable {
    case metalGPU
    case coreMLANE
    case coreMLCPU
    case coreMLGPU
}

/// Quantization levels a model may ship.
public enum Quant: String, Sendable, Codable, Hashable, CaseIterable {
    case fp32
    case fp16
    case bf16
    case int8
    case int6
    case int5
    case int4
    case mxfp4

    /// Precision ordering, lowest first — the axis a per-surface `quantFloor` is compared on
    /// (contract 1.23.0). Deliberately NOT `Comparable`: `fp16` and `bf16` are both 16-bit and
    /// share a rank, so `<` would be a strict-weak-ordering violation on a Comparable conformance.
    /// `mxfp4` ranks with `int4` (4 bits, richer per-block scaling — not a precision tier above it).
    public var precisionRank: Int {
        switch self {
        case .int4, .mxfp4: 0
        case .int5: 1
        case .int6: 2
        case .int8: 3
        case .fp16, .bf16: 4
        case .fp32: 5
        }
    }

    /// Whether this quant meets a declared floor (same rank passes).
    public func meets(floor: Quant) -> Bool { precisionRank >= floor.precisionRank }
}

/// Apple-silicon chip-tier floor a model requires.
public enum ChipTier: String, Sendable, Codable, Comparable, CaseIterable {
    case base
    case pro
    case max
    case ultra

    private var order: Int { ChipTier.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: ChipTier, rhs: ChipTier) -> Bool { lhs.order < rhs.order }
}

/// OS floor. macOS today; iOS is a future consideration and will be added additively.
public struct OSRequirement: Sendable, Codable, Equatable {
    public let minMacOS: SemanticVersion?
    public init(minMacOS: SemanticVersion? = nil) { self.minMacOS = minMacOS }
}

/// Resident memory footprint for one quantization, split into the **persistent** weight residency and
/// the **transient** activation peak.
///
/// - `residentBytes` — the persistent resident weights (a declared floor, not a measured cap). This is
///   what stays resident for the whole time the model is loaded.
/// - `peakActivationBytes` — the *additional* transient scratch (activations + compute buffers) that is
///   live only **during an inference**, on top of the weights, at the heaviest phase. Default `0` when
///   a port hasn't measured it; the reactive R-MEM-1 real-pressure trigger then covers any overflow.
///
/// Why split: inference is serialized on `@InferenceActor`, so at most **one** model's activation peak
/// is live at any instant. The governor can therefore admit co-residents as
/// `Σ residentBytes + max(peakActivationBytes)` — reserving a single transient instead of summing one
/// per model — which fits more models safely than charging weights+activation per model. Declare
/// `peakActivationBytes` as the max-over-phase activation (NOT the sum of phases); measure with the
/// in-app footprint probe. See docs/architecture.md (R-MEM-1).
public struct QuantFootprint: Sendable, Codable, Equatable {
    public let quant: Quant
    public let residentBytes: UInt64
    public let peakActivationBytes: UInt64
    /// The §5.6 bandwidth floor (1.34.0, additive; reserved by the Wan HV2 wiring note and made
    /// real by the I9 receipt): the minimum SUSTAINED sequential read, in bytes/second, the
    /// weights volume must deliver for this variant to be SAFE — not merely fast.
    ///
    /// Declare it only where a sub-floor volume is a CRASH, not a slowdown. The mechanism (I9,
    /// `LTX_TESTING/ISSUES.md:12`): safetensors load lazily, the bytes are pulled inside live
    /// Metal command buffers, and when the working set outgrows what the page cache can absorb on
    /// a slow volume, the fault storm trips the GPU watchdog — bf16-on-USB (~250–475 MB/s) was
    /// 0/7 across three sessions while int8/int4 on the same volume were fine, and prewarm does
    /// NOT save it (the run's own working set evicts the cache mid-generation). Which quants are
    /// fatal is therefore per-variant knowledge only the port has — encode it by declaring the
    /// floor on exactly those variants. `nil` (the default, and every pre-1.34 manifest) means no
    /// floor: the engine may still measure and surface the volume, but never refuses.
    public let minSustainedReadBytesPerSecond: UInt64?
    /// Expected weight bytes READ from disk per run (1.35.0, additive; AB-A-0013 option b) — the
    /// PERFORMANCE declaration, deliberately separate from the crash floor above. A streamed
    /// variant re-reads its swept working set every step (LTX compact24: ~147 GiB per 8-step
    /// clip), so run time has a hard bandwidth term that is NOT a crash: 33 s of I/O at 4.4
    /// GiB/s becomes 334 s at USB speed, with correct output throughout. Declaring the volume
    /// lets the ENGINE project I/O time from its own measured B/s and surface one accurate
    /// informational advisory, instead of every app hardcoding per-tier sweep arithmetic it
    /// should not have to know. `nil` (default, and every pre-1.35 manifest): no projection.
    /// Lane-resolved values (the read volume is usually a TIER property, not a quant property)
    /// ride `FootprintConfigured.expectedWeightReadBytesPerRunHint`, which wins over this.
    public let expectedWeightReadBytesPerRun: UInt64?
    public init(quant: Quant, residentBytes: UInt64, peakActivationBytes: UInt64 = 0,
                minSustainedReadBytesPerSecond: UInt64? = nil,
                expectedWeightReadBytesPerRun: UInt64? = nil) {
        self.quant = quant
        self.residentBytes = residentBytes
        self.peakActivationBytes = peakActivationBytes
        self.minSustainedReadBytesPerSecond = minSustainedReadBytesPerSecond
        self.expectedWeightReadBytesPerRun = expectedWeightReadBytesPerRun
    }
}

/// What a model costs to run — consumed by the Model Manager to match a DeviceProfile (C10).
/// This is cost-to-run, deliberately distinct from the tool *contract* (C2: what it can do).
public struct RequirementsManifest: Sendable, Codable, Equatable {
    public let footprints: [QuantFootprint]
    public let requiredBackends: Set<Backend>
    public let os: OSRequirement
    public let chipFloor: ChipTier?

    public init(footprints: [QuantFootprint],
                requiredBackends: Set<Backend>,
                os: OSRequirement = OSRequirement(),
                chipFloor: ChipTier? = nil) {
        self.footprints = footprints
        self.requiredBackends = requiredBackends
        self.os = os
        self.chipFloor = chipFloor
    }
}
