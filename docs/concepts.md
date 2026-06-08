# Concepts

## Three concepts, never conflated

- **Capability** — the contracted tool surface. A core-owned, additive `enum` (`tts`,
  `textToImage`, `textToVideo`, `llm`, `imageAnalysis`, `videoAnalysis`). Each has one canonical
  input schema and one canonical output artifact. *This is the contract.*
- **Mode** — a per-request tag *within* a capability (`thinking` / `direct` / `companion`, a
  sampler preset). Rides the request envelope; never a separate surface. *This is the request.*
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

See the `mlx-engine` skill for the authoritative detail.
