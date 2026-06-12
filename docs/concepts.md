# Concepts

## Three concepts, never conflated

- **Capability** — the contracted tool surface. A core-owned, additive `enum` (`tts`,
  `textToImage`, `textToVideo`, `llm`, `imageAnalysis`, `videoAnalysis`, `soundEffect`,
  `imageEdit`, …). Each has one canonical input schema and one canonical output artifact.
  *This is the contract.* New capabilities land at a minor version (contract **1.2.0** added
  `soundEffect` — text → SFX audio — and `imageEdit` — instruction-driven, multi-image-first
  editing). The enum is additive, so consumers should `@unknown default` exhaustive switches.
- **Mode** — a per-request tag *within* a capability (`thinking` / `direct` / `companion`, a
  sampler preset). Rides the request envelope; never a separate surface. *This is the request.*
  Modes can change behavior, not just sampling: the `llm` capability's `promptEnhance` mode turns a
  brief image prompt into a rich t2i-ready description — same surface, different behavior — and its
  text output feeds **any** `textToImage` backer, so prompt enhancement is a mode, never a tool.
- **Specialty** — model-level metadata the Model Manager ranks on ("strong at code"). Governed
  vocabulary, multi-valued with strength; never a surface. *This is the advertisement.*

## The package model

A contribution is one **`ModelPackage`** — the engine-owned model unit — that declares a
**`PackageManifest`** and backs **N capability surfaces** from one loaded model (Lance → four).

Three lifecycle levels stay distinct:

1. **Manifest** — registrable metadata (license, requirements, specialty, surfaces). Runs the
   license gate; pages no weights.
2. **Instance** — constructed by the engine from a `PackageConfiguration`, after the gate passes
   and weights are SHA256-verified on disk.
3. **Resident** — working set paged into compute memory (`load()` / `unload()`), governed by the
   `MemoryGovernor`.

Lifecycle methods are isolated to the `InferenceActor` (a global actor), so a package runs only
inside the engine's serialization domain — no private queues, no uncoordinated compute.

## Multiple packages per capability

A capability can have **more than one backer**. The engine holds a `PackageID`-keyed registry per
capability: register several packages for `textToImage` (e.g. a full-tier model and a lighter
distilled one), pick a default with `setDefault`, and override per call with the request's
`package:` selector. A registration for an id already present overwrites it; eviction is by
capability. Distinct capabilities are independent slots, so an `llm` enhancer and a `textToImage`
model are **co-resident** — which is how a `promptEnhance` → render pipeline runs through one engine
without unloading either. Memory admission for every resident is the `MemoryGovernor`'s call.

See the `mlx-engine` skill for the authoritative detail.
