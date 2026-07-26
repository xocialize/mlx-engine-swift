# MLXEngine

A community-released, on-device Apple-Silicon **runtime coordinator** for inference.

**MLXEngine does not do inference — packages do.** The engine instantiates each package, holds
the reference, and drives it: admission/queuing, model residency, memory governance, and
execution serialization. Because the engine owns the package lifecycle, a runaway package
cannot destabilize the pipeline.

- [Getting started](getting-started.md)
- [Concepts](concepts.md) — capability / mode / specialty, and the package model
- [Architecture](architecture.md)
- [Run lifecycle](run-lifecycle.md) — cancellation semantics (the sanctioned user-cancel seam),
  governor preemption + requeue, and what a package must honor
- [Contributing a package](contributing-a-package.md)
- [Model registry](model-registry.md) — the living index of every package the engine can serve,
  with availability / validation / efficiency state per row
- [Conformance (C0–C14)](conformance-c0-c13.md) — ⚠ does not yet cover the executable **MAT gate**
  (first-run weight materialization, MAT-1..5; bundled-weights vocabulary since v0.24.0); see the
  handoff note at the bottom of that page for ground-truth pointers

> MIT-licensed engine code. Separate from the two-layer weight/port-code **license gate** that
> governs which model weights the engine will load and serve.

*Placeholder docs site — the authoritative, detailed specs live in the `mlx-swift-integration` skill.*
