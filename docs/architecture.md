# Architecture

MLXEngine is a runtime **coordinator**, not an inference engine. Packages do inference; the
engine does the coordination around them.

## What the engine owns

- **Admission & queuing** — requests are admitted against current residency and memory headroom.
- **Execution serialization** — the `InferenceActor` global actor serializes inference onto the
  compute resources; `ModelPackage` lifecycle methods are isolated to it.
- **Memory governance** — a `MemoryGovernor` watermark ladder drives load/evict (see **R-MEM-1**);
  placement uses `MemoryPool` (`.metalGPU` / `.coreMLANE` / `.coreMLCPU` / `.coreMLGPU`).
- **Model residency** — lazy load, cooperative eviction. One model backs N surfaces.
- **Asset sourcing** — `HubAssetSource` fetches weights with SHA256 integrity verification.
- **License gate** — two layers (weight + port-code), enforced at registration.

## Memory requirements

### R-MEM-1 — Queue-shaped eviction on heavy swap

Residency is **queue-shaped**: paging in a model (`prepare`/`run` → `resident`) MUST first evict
prior **idle** residents (least-recently-used first) until the incoming working set fits the budget,
*before* constructing/loading the new instance. Swapping in a heavy model under pressure MUST
reclaim, not stack — the engine, not the caller, owns this.

- **Trigger on real cost, not just declared bytes.** Admission headroom MUST reflect *actual*
  resident memory, not solely each package's declared `QuantFootprint.residentBytes`. Declared bytes
  are a **floor**, not a measured cap: a model whose true working set (activations + scratch) exceeds
  its declaration must not silently defeat the headroom check. The engine MUST consult
  `MemoryGovernor.underPressure` on the admission path (today it is computed but never read) and
  SHOULD feed an actual-memory reading (e.g. `task_info` `phys_footprint`) into the governor.
- **Co-residency is opt-in and pressure-bounded.** Multiple backers of a capability (or of different
  capabilities) MAY be co-resident **only while they genuinely fit**. A caller may hold backers
  co-resident on purpose (the multi-package / `PackageID` path), but that is an explicit override of
  the default swap, and the governor MUST still evict under true pressure. There is no hard
  "one heavy model" rule — fit, measured against real memory, is the arbiter.
- **Out of scope (next layer, TODO):** mid-run preemption + requeue of an already-executing model
  (`MemoryGovernor` / `MLXServeEngine` doc-comments). v1 evicts idle residents at admission only.

**Status:** the eviction *mechanism* (`makeHeadroom` → LRU `evictResident`) is implemented and
tested (`evictsLRUWhenFull`, `lruKeepsRecentlyUsed`). The *trigger* is the open gap — it is
declared-byte arithmetic against a static budget, so two heavy generation models (e.g. Lens-bf16 +
Bernini-R) whose declared footprints sum under budget co-reside and stack `phys_footprint` past the
physical ceiling. Closing R-MEM-1 means wiring the pressure/actual-memory signal into admission; the
LRU logic itself needs no change. (`lruKeepsRecentlyUsed` encodes additive co-residency as correct
for the declared-bytes model — it will need a pressure-aware companion test.)

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

*The authoritative, detailed spec lives in the `mlx-engine` skill.*
