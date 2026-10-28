import Foundation

/// Governor policy for **mid-run preemption** (run-lifecycle program V3, ROADMAP 3.4): when a
/// queued contender needs residency that a *running* package holds, may the engine cancel that
/// run to reclaim it, and how does the preempted request recover?
///
/// Preemption is a **last resort**, ordered after every cheaper lever:
/// 1. Idle residents are evicted LRU first (v1 behavior — a package with a run in flight is
///    never an *idle* victim).
/// 2. Only when the contender still can't fit does the governor consider the active run — and
///    a victim whose latest `RunPhaseReport` reads at/past `preserveNearlyDoneFraction` is
///    **waited for**, not cancelled (preempting a video run 90% through denoise throws away
///    minutes of GPU work to save seconds of queueing).
/// 3. A preempted request is **requeued** through the normal admission path — its caller keeps
///    awaiting and eventually receives a genuine response, never a `CancellationError` it did
///    not cause. A *requeued* attempt may only wait, never preempt (this structurally prevents
///    two requests preempting each other in a loop), and after `maxRequeues` preemptions the
///    request degrades to a clear `EngineError.preemptionRetryExhausted` instead of retrying
///    forever.
///
/// Substrate bound (LTX-measured, 2026-07-09): MLX cannot interrupt mid-kernel, so preempt
/// latency is one eval — 1.08 s steady-state on LTX 2.3, 16–21 s inside a compile-heavy first
/// step or the upsampler. The policy initiates; the package's cooperative checkpoints decide
/// how fast it lands.
///
/// Engine-side policy only — no `MLXToolKit` contract surface changes. The package-facing
/// contract (`ModelPackage.run`: honor cancellation at natural yield points) is unchanged;
/// checkpoint *placement* stays package-owned (the V4 conformance gate covers it).
public struct PreemptionPolicy: Sendable, Equatable {
    /// Master switch. `false` restores v1 admission exactly: idle-LRU eviction only, a running
    /// inference is never touched.
    public var enabled: Bool

    /// How many governor preemptions one request tolerates before its `run()` stops requeueing
    /// and throws `EngineError.preemptionRetryExhausted`. The bound is per request, so repeated
    /// preemption always degrades to a clear error, never an infinite requeue loop.
    public var maxRequeues: Int

    /// A running victim whose latest progress report (`step/totalSteps`, the V2 signal) is at or
    /// past this fraction is allowed to finish — the contender's admission waits for it instead
    /// of cancelling it. Runs that report no step counts read as fraction-unknown and stay
    /// preemptable (no signal → nothing measurable to preserve).
    public var preserveNearlyDoneFraction: Double

    public init(enabled: Bool = true,
                maxRequeues: Int = 2,
                preserveNearlyDoneFraction: Double = 0.8) {
        self.enabled = enabled
        self.maxRequeues = max(0, maxRequeues)
        self.preserveNearlyDoneFraction = max(0, min(1, preserveNearlyDoneFraction))
    }
}
