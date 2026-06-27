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
- **Out of scope (next layer, TODO):** mid-run preemption + requeue of an already-executing model
  (`MemoryGovernor` / `MLXServeEngine` doc-comments). v1 evicts idle residents at admission only.

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

**Still out of scope (next layer):** mid-run preemption + requeue of an already-executing model, and
the cooperative-cancellation contract it needs (the engine signals; packages yield between
tokens/steps — today a running inference can't be stopped at all). v1 evicts idle residents at
admission only.

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
