import Foundation

/// A coarse, named phase of a package's `run()` — the run-time counterpart of `PreparePhase`
/// (contract 1.18.0, ENGINE-NEEDS V2). Long-running packages report the phase they are in
/// (LTX: encode → denoise → upsample → decode) so a consumer can show a real seam instead of
/// one indeterminate "Generating…", and so a cancel's latency is explainable (a denoise-step
/// cancel vs a compile-heavy first step vs a decode-chunk cancel).
///
/// Governed like `Mode`/`Specialty`: open and extensible (`String` raw value), with canonical
/// constants for the phases shared across model families. A package documents the phases it
/// reports; consumers MUST tolerate unknown phases (render the raw value or a generic label).
/// This is deliberately COARSE — it is not token streaming (that is a separate contract
/// question, companion ENGINE-NEEDS N2) and not a response shape.
public struct RunPhase: RawRepresentable, Sendable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension RunPhase {
    /// Conditioning/input encoding (text encoder, VAE-encode of an init frame or reference).
    public static let encode: RunPhase = "encode"
    /// The iterative diffusion denoise loop — report per-step counts here; they are cheap
    /// and the highest-value progress signal a video/image package has.
    public static let denoise: RunPhase = "denoise"
    /// Latent/spatial upsampling between stages (e.g. LTX two-stage half→full res).
    public static let upsample: RunPhase = "upsample"
    /// Decoding latents to the output artifact (VAE decode, vocoder) — report per-chunk
    /// counts when decoding is chunked.
    public static let decode: RunPhase = "decode"
    /// Generic/autoregressive generation for packages without finer structure (TTS chunk
    /// synthesis, LLM long runs) — report per-chunk counts when the run is chunked.
    public static let generate: RunPhase = "generate"
    /// Output assembly after the model is done (container encode/mux, resample, trim).
    public static let postprocess: RunPhase = "postprocess"
}

/// One coarse progress observation from inside a run: the phase, plus optional step counts
/// within the phase and an optional stage ordinal when the same phase runs more than once
/// (LTX two-stage denoise: stage 1/2 then 2/2). `step`/`stage` are 1-based when present.
///
/// A struct (not positional sink parameters) so later fields ride in additively without
/// breaking the `RunProgress.Sink` signature.
public struct RunPhaseReport: Sendable, Equatable {
    public var phase: RunPhase
    public var step: Int?
    public var totalSteps: Int?
    public var stage: Int?
    public var totalStages: Int?

    public init(phase: RunPhase, step: Int? = nil, totalSteps: Int? = nil,
                stage: Int? = nil, totalStages: Int? = nil) {
        self.phase = phase
        self.step = step
        self.totalSteps = totalSteps
        self.stage = stage
        self.totalStages = totalStages
    }
}

/// Ambient run-progress reporter — the run-time mirror of `WeightDownloadProgress`. The engine
/// binds a sink around a package's `run()` (task-locals scope it to that run, so concurrent
/// runs never cross-talk); the package reports coarse phases into it. No-op when unbound, so
/// reporting is always safe to call — from sync or async code, on any actor, as long as it is
/// on the run's task (an ordinary closure invoked during the run qualifies; a *detached* task
/// does not inherit the sink).
///
/// A package adopts it by reporting at its phase boundaries (and per step where steps exist):
/// ```swift
/// RunProgress.report(.denoise, step: i + 1, totalSteps: steps, stage: 1, totalStages: 2)
/// ```
public enum RunProgress {
    public typealias Sink = @Sendable (RunPhaseReport) -> Void

    @TaskLocal public static var sink: Sink?

    /// Report a run-phase observation to the ambient sink (no-op if none is bound).
    public static func report(_ report: RunPhaseReport) {
        sink?(report)
    }

    /// Convenience: report a phase with optional step/stage counts.
    public static func report(_ phase: RunPhase, step: Int? = nil, totalSteps: Int? = nil,
                              stage: Int? = nil, totalStages: Int? = nil) {
        sink?(RunPhaseReport(phase: phase, step: step, totalSteps: totalSteps,
                             stage: stage, totalStages: totalStages))
    }
}

/// Observable, engine-owned record of the latest `RunPhaseReport` per capability/package —
/// the run-time sibling of `PreparationMonitor` (same key scheme, same UI binding pattern).
/// `nil` means no run is in flight for that key: the engine records reports while `run()`
/// executes and clears the entry when the run ends (success, failure, or cancellation).
@MainActor
@Observable
public final class RunMonitor {
    public private(set) var reports: [PreparationKey: RunPhaseReport] = [:]

    public nonisolated init() {}

    /// Latest report for a capability (optionally a specific package); `nil` = not running.
    /// Falls back from the package-specific entry to the capability-wide one.
    public func report(for capability: Capability, package: String? = nil) -> RunPhaseReport? {
        if let package, let r = reports[PreparationKey(capability: capability, packageID: package)] {
            return r
        }
        return reports[PreparationKey(capability: capability, packageID: nil)]
    }

    /// Engine-internal: record a report under both the package-specific and capability-wide
    /// keys, so a consumer can observe by capability alone or by exact package.
    public func update(_ capability: Capability, package: String?, to report: RunPhaseReport) {
        reports[PreparationKey(capability: capability, packageID: package)] = report
        reports[PreparationKey(capability: capability, packageID: nil)] = report
    }

    /// Engine-internal: the run ended — drop both entries so consumers read "not running".
    public func clear(_ capability: Capability, package: String?) {
        reports[PreparationKey(capability: capability, packageID: package)] = nil
        reports[PreparationKey(capability: capability, packageID: nil)] = nil
    }
}
