//
//  ActivationScaling.swift
//  MLXToolKit
//
//  Activation as a FUNCTION of a run-time workload (contract 1.41.0, AB-A-0069 / AB-D-0075).
//  `QuantFootprint.peakActivationBytes` is what admission reserves; this is the declaration of
//  how that number MOVES with the input, and up to which input it was measured.
//

import Foundation

/// The unit an `ActivationScaling` declaration is expressed in.
///
/// OPEN, like `RunPhase`: a `String`-backed value with canonical constants, so a package whose
/// activation scales along an axis nobody has named yet mints its own without a contract bump —
/// and no exhaustive enum grows a case consumers have to switch over (the 1.37.0
/// `MaterializeError.truncated` lesson). Capability-neutral on purpose: the 1.38.0 rule is that a
/// shared type does not grow capability-specific members, and "seconds of audio" is a unit, not
/// a capability. Reuse a canonical constant when the semantics fit; a new name is for a genuinely
/// new unit, not a synonym.
public struct WorkloadAxis: RawRepresentable, Sendable, Codable, Equatable, Hashable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Seconds of audio — input for STT (a file's or a session's length), output for TTS.
    public static let audioSeconds: WorkloadAxis = "audioSeconds"
    /// Context tokens (prompt + generation) for a model whose KV cache grows unbounded.
    public static let tokens: WorkloadAxis = "tokens"
    /// Visual tokens a VLM spends on an image or clip (mage-vl's `visualTokenBudget`).
    public static let visualTokens: WorkloadAxis = "visualTokens"
    /// Output pixels (width × height) of an image or single-frame surface.
    public static let outputPixels: WorkloadAxis = "outputPixels"
    /// Output pixel-frames (width × height × frames) of a video surface — the geometry envelope.
    public static let pixelFrames: WorkloadAxis = "pixelFrames"
    /// Generated or decoded frames where the frame, not its pixels, is the unit (a codec's audio
    /// frames, an interpolator's output frames).
    public static let frames: WorkloadAxis = "frames"
}

/// How a package's transient activation moves with a run-time workload (contract 1.41.0).
///
/// ## Why it exists
///
/// `QuantFootprint.peakActivationBytes` is a scalar, and for a whole class of packages activation
/// is a FUNCTION of a run-time input: a full-attention ASR decoder that never trims KV grows with
/// session length; a VLM's prefill grows with its visual-token budget; a video generator's
/// attention grows with pixel-frames. One number cannot straddle a 4× input range, so every
/// author measured a representative case, declared that, and the engine's launch gate
/// (`machineFitAdvisory`, 1.36.0) inherited the error exactly — five independent instances
/// before the shape was named (AB-A-0069).
///
/// ## What it declares
///
/// A first-order model, `projectedBytes(at: units) = baseBytes + bytesPerUnit × units`, and the
/// largest workload it was MEASURED at, `measuredCeiling`. Declared BESIDE the scalar, never
/// instead of it: `peakActivationBytes` (or a lane's `peakActivationBytesHint`) stays what
/// admission reserves, and this says which workloads that reserve was sized for. Per quant, like
/// the scalar it qualifies — KV bytes per token depend on the cache dtype even where "activations
/// do not quantize" — with `FootprintConfigured.activationScalingHint` for the lane-resolved case
/// (a tier's geometry envelope, a configuration's token budget), which wins over this exactly as
/// the other hints win over their quant-keyed counterparts.
///
/// ## The three rules
///
/// 1. **The line sits on or above every measured point from 0 to the ceiling.** Linear curves:
///    the least-squares fit (Audio8's pre-windowed `1824 MB + 14.2 MB/frame` is the model
///    example). Convex curves (prefill attention in tokens, video attention in pixel-frames): the
///    chord from `(0, baseBytes)` through the ceiling point — it over-projects between, which is
///    the safe direction. A tangent at the low end is the unsafe one.
/// 2. **`measuredCeiling` is the largest workload you measured, never the largest imaginable.**
///    The engine refuses a request beyond it BEFORE admission
///    (`EngineError.workloadExceedsDeclaredCeiling`): past the ceiling the model is an
///    extrapolation, and being admitted against a number that no longer applies is the failure
///    this declaration exists to prevent. A package that wants a wider envelope measures it.
/// 3. **Every admitted run is reserved for.** Since 1.42.0 (AB-A-0075) admission sizes the
///    transient PER RUN — `max(peakActivationBytes, projectedBytes(at: workload))` when the
///    configuration maps the request (`WorkloadDeclaring`) — so the scalar is the author's
///    REPRESENTATIVE case (what registration and the idle reserve charge; what decides which
///    machines the package fits) and the line is what a longer job reserves, for exactly that
///    job. The 1.41.0 form of the rule — `peakActivationBytes ≥ projectedBytes(at:
///    measuredCeiling)` — still holds when nothing can map a request to the line: the FIT gate
///    (`MLXServeConformance.FootprintConformance`, FIT-2) requires it of a configuration that
///    does not adopt `WorkloadDeclaring`, and passes a mapping one with the per-run note. A lane
///    that raises its cap still re-declares BOTH through `FootprintConfigured`
///    (`peakActivationBytesHint` + `activationScalingHint`) so the lane's representative case
///    is its own.
///
/// Measure on `phys_footprint`, not the allocator's view: the VibeVoice port found MLX's own
/// accounting under-reading the same run by 45 % (0.116 vs 0.182 GB/min), and `phys` is what the
/// governor and the advisory read. The declaration is deliberately NOT the maximum a package can
/// be driven to: a 60-minute meeting's envelope would make the governor refuse the package on
/// machines that run a short clip comfortably. Declare the representative case as the reserve,
/// the measured slope as the model, and let the engine answer "will THIS job fit?" per workload.
public struct ActivationScaling: Sendable, Codable, Equatable {
    public let axis: WorkloadAxis
    /// Activation at zero workload — the fitted intercept. Non-negative by type; a fit whose
    /// intercept falls below zero is convex and declares the chord through the ceiling instead.
    public let baseBytes: UInt64
    /// Bytes of activation per unit of `axis`.
    public let bytesPerUnit: Double
    /// The largest workload, in units of `axis`, the declaration was measured at. Also the
    /// ceiling the engine enforces before admission.
    public let measuredCeiling: Double

    public init(axis: WorkloadAxis, baseBytes: UInt64, bytesPerUnit: Double,
                measuredCeiling: Double) {
        self.axis = axis
        self.baseBytes = baseBytes
        self.bytesPerUnit = bytesPerUnit
        self.measuredCeiling = measuredCeiling
    }

    /// `baseBytes + bytesPerUnit × units`, rounded to the nearest whole byte and clamped at zero
    /// (nearest, not up: an author who sets the scalar to exactly `base + slope × ceiling` in
    /// floating point must not fail FIT-2 by one byte). Defined beyond the ceiling too — the
    /// advisory shows the extrapolation so a host can say HOW FAR out of envelope a job is — but
    /// nothing admits on it.
    public func projectedBytes(at units: Double) -> UInt64 {
        let raw = Double(baseBytes) + bytesPerUnit * units
        guard raw.isFinite, raw > 0 else { return 0 }
        return raw >= Double(UInt64.max) ? UInt64.max : UInt64(raw.rounded())
    }

    /// Whether `units` is inside the measured envelope (rule 2).
    public func covers(_ units: Double) -> Bool { units <= measuredCeiling }

    /// The model evaluated at the ceiling — what a run AT the ceiling reserves (rule 3), and
    /// what the scalar alone must cover when no configuration can map a request to the line.
    public var bytesAtCeiling: UInt64 { projectedBytes(at: measuredCeiling) }

    /// Does `reserveBytes` cover the model at the ceiling? The 1.41.0 form of rule 3 — decisive
    /// for a scalar that has to stand alone; informational for a lane whose runs are sized per
    /// workload (1.42.0).
    public func isCovered(by reserveBytes: UInt64) -> Bool { bytesAtCeiling <= reserveBytes }

    /// Well-formedness (FIT-1): a positive, finite ceiling and a finite, non-negative slope. A
    /// declaration that fails this is not silently treated as absent — a zero ceiling refuses
    /// every run, loudly, which is the direction a declaration bug should fail in.
    public var isWellFormed: Bool {
        measuredCeiling.isFinite && measuredCeiling > 0
            && bytesPerUnit.isFinite && bytesPerUnit >= 0
    }
}

/// Opt-in on a package's CONFIGURATION (contract 1.41.0): map a request to its workload, in the
/// units of the declared `ActivationScaling.axis`, so the engine can enforce the declared ceiling
/// BEFORE admission.
///
/// On the configuration and not the instance, deliberately. `StreamEmitting` and
/// `LiveTranscribing` are detected on the resident instance, but the ceiling check has to run
/// before residency — before weights are touched — or a doomed request loads a 40 GB working set
/// only to be refused. Pre-admission knowledge in this engine lives on the configuration
/// (`QuantConfigured`, `FootprintConfigured`, `ModelStorable`, `BudgetAware`; `as?`-detected at
/// registration), and the configuration is also where config-level workloads live: mage-vl
/// answers `Double(visualTokenBudget)` for every request, because the budget IS the workload;
/// VibeVoice answers the audio duration of an `STTRequest`.
///
/// `nil` means "unknowable for this request" — a live `STTSessionRequest` at open time, a request
/// type the package does not map — and is never refused. For an open-ended session the ceiling is
/// advisory: the host asks `machineFitAdvisory(_:package:workload:)` with the expected length
/// before opening it. The engine does not cut a session mid-speech; that loses audio nobody can
/// replay.
public protocol WorkloadDeclaring {
    func workloadUnits(for request: any CapabilityRequest) -> Double?
}
