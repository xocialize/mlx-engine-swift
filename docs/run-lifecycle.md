# Run lifecycle: cancellation, preemption, requeue

How a `run()` ends, on purpose. The engine distinguishes **two cancellation lanes** that a
package cannot (and must not) tell apart — both reach `ModelPackage.run` as the same
`CancellationError`; the engine disambiguates and gives each caller the semantics the contract
promises.

## The user lane — how an app cancels a run

**The sanctioned app-side cancel is: cancel the `Task` that wraps `engine.run(...)`.**

```swift
let generation = Task {
    try await engine.run(T2VRequest(prompt: prompt))
}
// … user taps Cancel:
generation.cancel()
// engine.run rethrows CancellationError — classify it .cancelled, not failed.
```

That is the whole seam. The engine forwards the cancellation into the run (structured
propagation via a cancellation handler on the engine-scoped run task), the package's
cooperative checkpoints throw at the next yield point, and the `CancellationError` surfaces to
the caller **unchanged**. There is no separate `cancel()` API on the engine, deliberately —
structured concurrency already scopes a cancel to exactly one request, composes with the
caller's own task tree, and works for every capability uniformly.

What the app should expect:

- **Latency is one MLX eval.** MLX cannot interrupt mid-kernel; a cancel lands at the package's
  next `Task.checkCancellation()` boundary. Measured on LTX 2.3: **1.08 s** steady-state
  (per denoise step), **16–21 s** worst case inside a compile-heavy first step or the upsampler.
  The V2 run-phase monitor (`engine.runProgress`) makes that latency legible — show *which*
  phase is absorbing the cancel.
- **Classify `CancellationError` as `.cancelled`** (`FinishReason.cancelled`), never as a
  failure.
- **Hygiene is automatic** (V1): a cancelled run still counts toward the engine's pool-trim
  policy, and a large-transient package (`trimAfterCancelBytes`) triggers an immediate pool trim
  — no app-side drain logic.

## The governor lane — mid-run preemption + requeue (V3)

When a queued contender needs residency that a **running** package holds, the governor may — as
a **last resort** — cancel that run to reclaim it. The preempted request is not failed: the
engine **requeues** it through the normal admission path, so its caller keeps awaiting and
eventually receives a genuine response. The caller never sees a `CancellationError` it did not
cause.

Order of levers at admission (`PreemptionPolicy`, engine-side only — no contract surface):

1. **Idle-LRU eviction first** (v1 behavior). A package with a run in flight is never an "idle"
   victim — V3 also closed the v1 hazard where a long run's stale LRU tick could get its weights
   unloaded mid-inference.
2. **Nearly-done victims are waited for, not cancelled.** The policy weighs the victim's V2
   progress signal (`RunPhaseReport.step/totalSteps`); at/past `preserveNearlyDoneFraction`
   (default 0.8) the contender queues behind the run instead of throwing away minutes of GPU
   work. Runs reporting no step counts read as fraction-unknown and stay preemptable.
3. **Preempt as last resort.** The engine marks the run-handle *preempted* before cancelling —
   that marker is how the resulting `CancellationError` is recognized as the engine's own doing
   (vs. the user lane) when it surfaces.
4. **Requeue, bounded.** A requeued attempt re-enters normal admission but may only *wait* for
   running victims, never preempt them — structurally preventing two requests from preempting
   each other in a loop. After `maxRequeues` preemptions (default 2) the request degrades to a
   clear `EngineError.preemptionRetryExhausted`, never an infinite retry.
5. **If the caller cancels while a preemption is in flight, the user lane wins**: the
   `CancellationError` surfaces and nothing requeues.

`prepare()` never preempts — warming a model is not worth abandoning in-flight work. Disabling
the policy (`PreemptionPolicy(enabled: false)`) restores v1 admission exactly.

Admission bookkeeping (headroom → construct → load → charge → run-handle registration) is
serialized by an engine-internal gate, so a requeued victim cannot race its preemptor's
mid-`load()` accounting. Runs themselves still overlap their awaits; only one inference executes
at a time on `InferenceActor` — preemption is about a *queued contender needing residency*, not
about concurrent runs.

## What a package must do

Nothing new beyond the existing `ModelPackage.run` contract: **honor cancellation at natural
yield points** (per token / denoise step / VAE chunk / encoder layer), unwind cleanly, and
rethrow the `CancellationError`. Checkpoint *placement* stays package-owned and model-specific.
LTX 2.3 is the reference adopter (per-step, per-chunk, per-layer checkpoints; clean
cancel→re-run recovery). The executable conformance gate for this is the **CAN gate** (V4,
engine ≥ 0.27.0): `MLXServeConformance.CancellationConformance` offline in the package's own
suite (CAN-1 pre-cancelled `run()` surfaces `CancellationError` — make
`try Task.checkCancellation()` the FIRST act of `run()`, before `notLoaded` validation; CAN-2
the outcome is cancelled-not-failed, the error never laundered; CAN-3 long-run manifests declare
their checkpoint cadence), plus the live timed probe `MLXEngineTestKit.CancellationBench`
(`[CAN]`; Xcode-app harness only). See `docs/conformance-c0-c13.md`.

## Every exit is clean

On **every** outcome of every attempt — response, user cancel, preemption, genuine error:

- V1 pool hygiene runs (`trimEveryRuns` counting, cancel-trim for large transients, LRU touch —
  the cancelled package stays hot because the measured pattern is an immediate re-run).
- The V2 run monitor entry clears (`engine.runProgress` reads nil = not running).
- Genuine errors propagate to the caller unchanged.
