# MLXEngine

A community-released, on-device Apple-Silicon **runtime coordinator** for inference.

**MLXEngine does not do inference — packages do.** The engine instantiates each package, holds
the reference, and drives it: admission/queuing, model residency, memory governance, and
execution serialization. Because the engine owns the package lifecycle, a runaway package
cannot destabilize the pipeline.

- [Getting started](getting-started.md)
- [Concepts](concepts.md) — capability / mode / specialty, and the package model
- [Architecture](architecture.md)
- [Contributing a package](contributing-a-package.md)
- [Conformance (C0–C13)](conformance-c0-c13.md)

> MIT-licensed engine code. Separate from the two-layer weight/port-code **license gate** that
> governs which model weights the engine will load and serve.

*Placeholder docs site — the authoritative, detailed specs live in the `mlx-engine` skill.*
