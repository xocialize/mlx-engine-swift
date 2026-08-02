# Architecture

MLXEngine is a runtime **coordinator**, not an inference engine. Packages do inference; the
engine does the coordination around them.

## What the engine owns

- **Admission & queuing** — requests are admitted against current residency and memory headroom.
- **Execution serialization** — the `InferenceActor` global actor serializes inference onto the
  compute resources; `ModelPackage` lifecycle methods are isolated to it.
- **Memory governance** — a `MemoryGovernor` watermark ladder drives load/evict (see **R-MEM-1**).
  A package declares which `Backend`s it needs (`.metalGPU` / `.coreMLANE` / `.coreMLCPU` /
  `.coreMLGPU`) and the engine gates admission on device eligibility (C10). It does **not** model
  *placement* — where weights physically land is the substrate's call, not the coordinator's.
- **Model residency** — lazy load, cooperative eviction. One model backs N surfaces.
- **Asset sourcing** — since contract 1.24 the **engine executes** first-run materialization:
  `resident()` downloads a `WeightSourcing` configuration's missing sources into the `ModelStore`
  root before `load()` (`WeightMaterializer` — plain URLSession, no hub-client dependency; files
  land flat under `<root>/models--<org>--<name>/`). `SelfMaterializing` opts a package out
  (non-HF hosts, wrappers that fetch internally); those packages keep downloading through their
  own client, pointed at the same root. The engine's executor verifies per-file **size**; deeper
  integrity (xet chunk hashes / ETags) remains a hub client's domain.
- **Disk governance** — the store's counterpart to memory governance: `WeightSourcing.
  missingWeightSources(storeRoot:)` ships a default probe over that layout,
  `MLXServeEngine.deleteWeights(repo:)` deletes a repo's weights but **refuses while a resident
  package draws on it** (`EngineError.weightsInUse`), and `ModelStore.usage(at:)` sizes a store root
  with link dedup (a snapshot is a tree of links into `blobs/`).
- **License classification** — two layers (weight + port-code), evaluated at registration. Since
  contract 1.28.0 a license outside the policy is **recorded** (`licenseAdvisories`) rather than
  rejected; `licenseEnforcement: .blocking` restores the hard gate. C7/C8 are declaration
  requirements — see `docs/conformance-c0-c13.md`.

## Memory requirements

### R-MEM-1 — Queue-shaped eviction on heavy swap

Residency is **queue-shaped**: paging in a model (`prepare`/`run` → `resident`) MUST first evict
prior **idle** residents (least-recently-used first) until the incoming working set fits the budget,
*before* constructing/loading the new instance. Swapping in a heavy model under pressure MUST
reclaim, not stack — the engine, not the caller, owns this.

- **Account for activation separately from weights (serialized-inference reserve).** A footprint is
  split into **persistent** weights (`QuantFootprint.residentBytes`) and a **transient** activation
  peak (`QuantFootprint.peakActivationBytes`) that is live only during an inference. Because inference
  is serialized on `@InferenceActor`, at most one transient is live at any instant, so admission
  accounts for `Σ persistent(residents) + max(peakActivation)` — reserving a **single** transient, not
  one per model. This admits more safe co-residency than charging weights+activation per model, and is
  the proactive complement to the reactive real-pressure trigger below (ComfyUI's
  `minimum_inference_memory`, made exact for serialized execution). Undeclared transient defaults to 0
  (the real-pressure pass still catches overflow). `MemorySnapshot.transientReserveBytes` exposes the
  reserve; admission rejects a model whose own `persistent + transient` exceeds the whole budget.
- **Wire the accounted working set during runs — and only during runs (HV1, v0.42.0).** The
  engine maps its accounting onto mlx-swift's process-global `WiredMemoryManager`: each resident's
  persistent weights hold a **`.reservation`** ticket (participates in limit computation, never
  elevates the limit alone) and the one in-flight transient around `run()`/`stream()` holds an
  **`.active`** ticket — so while a run is live, MLX's wired limit rises to `Σ persistent + that
  run's transient` (the same split the serialized-inference reserve accounts) and Metal keeps
  weights + activations resident exactly when a page-out would stall a live command buffer; an
  idle engine restores the wired=0 default and residents stay fully pageable. Every computed limit
  clamps to `min(recommendedMaxWorkingSetSize, total − clamp(total/8, 6 GiB…16 GiB))` — the
  allocator **rejects** an apply above the queried working set (`set_wired_limit` throws; the
  engine scopes a log-and-continue MLX error handler around every ticket call so a rejection
  degrades instead of killing the process), and wiring most of RAM is a genuine kernel panic, not
  an OOM kill (NEUROSTREAM-TEARDOWN §3.2: IOGPUMemory.cpp:550 at 83.5% wired,
  `memoryPressure=false`). Admission stays the governor's alone — the engine's
  `WiredMemoryPolicy` never gates `canAdmit`, because a second admission authority could park
  `prepare()` behind capacity the governor already cleared. `WiredLimitConfiguration`
  (`.automatic` default / explicit `.ceiling(bytes:)` / `.disabled`) selects the policy;
  `wiredLimitCeilingBytes` exposes the resolved ceiling. Interaction receipts (pool-cap
  independence, shrink-hysteresis timing, over-ceiling rejection survival, legacy policy-group
  coexistence): `mlxengine-todo/probes/hv1_wired_tickets.out`.
- **Trigger on real cost, not just declared bytes.** Admission headroom MUST reflect *actual*
  resident memory, not solely each package's declared `QuantFootprint.residentBytes`. Declared bytes
  are a **floor**, not a measured cap: a model whose true working set (activations + scratch) exceeds
  its declaration must not silently defeat the headroom check. **Wired (v1):** `makeHeadroom` runs a
  second pass that reads the process's `phys_footprint` (`HostMemory.physFootprint`, injectable for
  tests) and, when it exceeds the governor's high-watermark, evicts idle LRU residents until real
  pressure clears or none remain — so a model whose true working set exceeds its declaration can't
  defeat the check. Bounded: it reclaims only the engine's own idle residents (never the incoming
  model), so external memory pressure can't loop; degrades to declared-byte arithmetic when no host
  reading is available. The `phys_footprint` reading + `underRealPressure` flag are surfaced on
  `MemorySnapshot`.
- **Co-residency is opt-in and pressure-bounded.** Multiple backers of a capability (or of different
  capabilities) MAY be co-resident **only while they genuinely fit**. A caller may hold backers
  co-resident on purpose (the multi-package / `PackageID` path), but that is an explicit override of
  the default swap, and the governor MUST still evict under true pressure. There is no hard
  "one heavy model" rule — fit, measured against real memory, is the arbiter.
- **Mid-run preemption is the last resort, behind idle eviction (V3, wired).** When idle-LRU
  eviction can't make room for a queued contender, the governor may cancel a *running* inference
  and reclaim its residency — see **Run lifecycle** below. A package with a run in flight is
  never an "idle" victim (V3 closed the v1 hazard where a long run's stale LRU tick could get
  its weights unloaded mid-inference).

**Status:** both the eviction *mechanism* (`makeHeadroom` → LRU `evictResident`,
`evictsLRUWhenFull` / `lruKeepsRecentlyUsed`) **and** the real-memory *trigger* are now implemented.
The trigger (the previously-open gap) reads actual `phys_footprint` and evicts idle LRU residents on
real pressure, so two heavy generation models (e.g. Lens-bf16 + Bernini-R) whose declared footprints
sum under budget but stack past the physical ceiling are reclaimed rather than allowed to overrun.
Tests: `realPressureEvictsIdleEvenWhenDeclaredBytesFit` (the trigger fires when declared bytes fit but
real memory is over watermark) and `realPressureKeepsRecentlyUsed` (the pressure-aware companion to
`lruKeepsRecentlyUsed` — eviction is LRU-ordered, recent residents survive). Config-aware footprint
declaration (`QuantConfigured` quant match + `FootprintConfigured` per-mode hint) keeps the *declared*
floor honest so the trigger only fires on genuine activation/scratch overflow.

**The "next layer" landed (V3, run-lifecycle program, 2026-07-09):** mid-run preemption + requeue
of an already-executing model is implemented, on top of the cooperative-cancellation contract the
packages honor (yield between tokens/steps — LTX 2.3 proved the package side: 1.08 s steady-state
preempt latency, one-MLX-eval granularity).

## Run lifecycle — two cancellation lanes (V3)

Full doc: [run-lifecycle.md](run-lifecycle.md). The short form:

- **User cancel** — the sanctioned app seam is *cancelling the `Task` wrapping `engine.run()`*;
  the engine forwards it into the run and the `CancellationError` surfaces to the caller
  unchanged (classify `.cancelled`).
- **Governor preemption** — each run executes in an engine-scoped run-handle task the governor
  can cancel; the handle is marked *preempted* before cancelling, which is how the engine tells
  its own doing from the user lane (both reach the package as the same `CancellationError`).
  The preempted request is **requeued** through normal admission — the caller keeps awaiting and
  gets a genuine response — bounded by `PreemptionPolicy.maxRequeues`
  (`EngineError.preemptionRetryExhausted` past it). Policy (`PreemptionPolicy`): idle eviction
  first; a victim whose V2 `RunPhaseReport` progress reads ≥ `preserveNearlyDoneFraction` is
  waited for, not cancelled; requeued attempts only ever wait (no preemption ping-pong);
  `prepare()` never preempts. Admission bookkeeping is serialized by an engine-internal gate so
  a requeued victim can't race its preemptor's mid-`load()` accounting.
- **Every exit clean** — V1 pool hygiene and the V2 run-monitor clear run on every outcome of
  every attempt. Tests: `RunPreemptionTests`.

### R-MEM-2 — GPU buffer-pool policy (engine ≥ 0.21.0, ENGINE-NEEDS N5)

The governor budgets **weights admission**; it does not constrain MLX's process-global Metal
buffer-recycling pool, which is effectively unbounded by default and never returns memory to the
OS. Interactive consumers (chat: llm + embed + tts per turn, each run with new tensor shapes)
ratchet the pool by GBs per interaction — the MLXCompanion 43 GB "leak" staircase (2026-07-05).
The engine owns the GPU and the budget, so the pool policy lives beside the governor:

- **Default-managed:** `MLXServeEngine.init` applies `GPUCacheConfiguration` — `.automatic`
  (default) resolves to `min(2 GB, 5% of the governor budget)` and writes `MLX.Memory.cacheLimit`
  once, at construction. `.bytes(_)` fixes the cap (`0` disables recycling); `.unmanaged` opts out
  entirely. **Precedence is last-write-wins on the process-global setting**: the engine writes at
  init and never re-asserts, so a host writing later overrides it, and a host that bounded the
  pool *before* constructing the engine gets superseded (pass `.unmanaged` to keep a pre-set value).
- **Best-effort by design:** the first allocator call initializes MLX's Metal device, which can
  fail in processes that can't load the bundled metallib — every package's offline admissibility
  tests construct engines. The concrete cause is the **build system**: MLX's kernels are compiled
  from Cmlx's `.metal` sources into a `default.metallib` in a resource bundle colocated with the
  binary, and only SwiftPM's `swiftbuild` build system (and Xcode) does that compile. Under the
  deprecated `native` one there is no metallib at all, and mlx-swift's *default* error handler
  **aborts the process** rather than throwing. So all engine MLX touches are scoped through
  `MLX.withError`; on failure the engine degrades to unmanaged (recorded in
  `appliedGPUCacheLimitBytes`) instead of aborting. A process where the write fails cannot run GPU
  work anyway, so the degradation is exact, not lossy.
  - Two consequences for test code. **One:** any test that calls MLX directly must scope it the
    same way — an unscoped call takes down the whole xctest process, every later suite included.
    **Two:** `Memory.cacheLimit`'s getter cannot be used to probe availability. mlx-swift's setter
    stores a Swift-side shadow (`Memory._cacheLimit`) *before* calling `mlx_set_cache_limit`, and
    the getter returns that shadow, so a read hands back a value the allocator never applied.
    Probe with a write (`GPUCachePolicyTests.requireMLXAllocator`).
- **Trim hooks:** `trimCaches()` drops the pool on demand (the "after a burst" hook — what
  `MLXEngineTestKit.ValidationRun` does between measurement phases); optional knobs
  `trimAfterEvict` / `trimEveryRuns` (both default off) automate it around the lifecycle.
- **Telemetry:** `gpuPoolSnapshot()` → `GPUPoolSnapshot` (active / cache / peak / effective
  limit) so consumers observe the pool without importing MLX. Reading: `phys_footprint ≈ baseline
  + active + cache`; `cache` saturating at the limit is healthy; `active` climbing across turns is
  a real retention leak no cache limit will fix.

This is the repo's one runtime dependency (`mlx-swift`, scoped to `MLXServeCore` — allocator API
only, still no inference math in the engine). `MLXToolKit` stays dependency-free, so packages'
offline contract builds are unaffected.

## The package abstraction

- `PackageManifest` — the registrable blueprint (license, provenance, requirements, specialty,
  surfaces). Runs the gate; pages no weights.
- `ModelPackage` — the engine-owned model unit: `nonisolated` `manifest` / `init`,
  `@InferenceActor` `load` / `run` / `unload`. Erased dispatch over `any CapabilityRequest`.
- `PackageRegistration` — manifest + a license-gated factory the engine calls to construct.

## Boundary with `mlx-porting`

| Concern | Owner |
|---|---|
| PyTorch→MLX parity, quantization, mlx-community publishing | `mlx-porting` |
| Capability registration, schema, license gate, Model Manager | **mlx-engine** |

Conformance assumes a parity-locked artifact — it does not re-verify numerics.

*The authoritative, detailed spec lives in the `mlx-swift-integration` skill.*
