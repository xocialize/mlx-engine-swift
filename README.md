# MLXEngine (`mlx-engine-swift`)

> ## Status — usable, evolving
>
> MLXEngine is **published and consumable**: tagged **v0.4.0** (capability contract **1.3.0**),
> and already serving a roster of ~two-dozen conformant model packages — LLM, TTS, text→image /
> text→video (+ editing), audio separation, speech emotion, audio codec/polish, image quality /
> restore / upscale, video upscale, frame interpolation, content classification, and optical flow.
> The contract is **additive**: capabilities and conformance levels grow at minor versions, and a
> breaking change is a major bump with a deprecation window — so **pin a tag** for production use.

A community-released, on-device Apple Silicon **runtime coordinator** for inference.

**MLXEngine does not do inference — packages do.** The engine instantiates each package,
holds the reference, and drives it: queuing, model loading, memory governance, and execution
serialization. Because the engine owns the package lifecycle, a runaway package cannot
destabilize the pipeline. It also presents one common way to engage every model, so
cross-model work is uniform from a programming standpoint.

> MIT licensed — the engine code is open to build on. This is **separate** from the two-layer
> weight/port-code license gate that governs which model weights the engine will load and serve.

## Packages
- **MLXToolKit** — the contract surface every package conforms to (capabilities, canonical
  schemas, artifacts, license types, `PackageConfiguration`, the `ModelPackage` protocol +
  `PackageManifest`, and the `InferenceActor` isolation domain). Depend on this to build a
  conformant package; it does not pull in the runtime.
- **MLXServeCore** — the runtime coordinator. `MLXServeEngine` registers packages, runs the
  two-layer license gate + device-eligibility (C10) admission, and lazily constructs / loads /
  routes / evicts each `ModelPackage` by capability, backed by a `MemoryGovernor` (budget +
  LRU eviction of idle residents) and multi-package-per-capability routing (select by PackageID).
  Some advanced facilities (mid-run eviction-under-pressure + requeue, `MCPBridge`, Hub SHA256
  verification) are still in progress.
- **MLXServeConformance** — the C0–C13 self-check harness (in progress).
- **MLXEngineUI** — reusable SwiftUI for engine management (model-storage + web-search settings)
  plus the Marquee design tokens, so consuming apps share one look. (Product UI stays in the app.)
- **MLXRetrievalKit** (+ **MLXRetrievalKitContracts**) — reusable, MLX-free web retrieval / RAG
  grounding (Brave-backed) any package or app can use to ground answers with current sources.

## Build
Build with Xcode / `xcodebuild` (macOS 26.2+). `Package.swift` is the authoritative manifest;
this repo contains only the package — not the XCLWorkspace.

## Contributing
A contribution is a package that registers one or more capabilities and passes the C0–C13
conformance gate. See `CONTRIBUTING.md`.
