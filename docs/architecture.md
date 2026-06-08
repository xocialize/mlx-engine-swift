# Architecture

MLXEngine is a runtime **coordinator**, not an inference engine. Packages do inference; the
engine does the coordination around them.

## What the engine owns

- **Admission & queuing** — requests are admitted against current residency and memory headroom.
- **Execution serialization** — the `InferenceActor` global actor serializes inference onto the
  compute resources; `ModelPackage` lifecycle methods are isolated to it.
- **Memory governance** — a `MemoryGovernor` watermark ladder drives load/evict; placement uses
  `MemoryPool` (`.metalGPU` / `.coreMLANE` / `.coreMLCPU` / `.coreMLGPU`).
- **Model residency** — lazy load, cooperative eviction. One model backs N surfaces.
- **Asset sourcing** — `HubAssetSource` fetches weights with SHA256 integrity verification.
- **License gate** — two layers (weight + port-code), enforced at registration.

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
