# MLXEngine (`mlx-engine-swift`)

> ## Status — usable, evolving
>
> MLXEngine is **published and consumable**: tagged **v0.44.0** (capability contract **1.32.0**),
> and already serving **47 published model packages** (68 tracked, incl. WIP + research — see
> [the model registry](docs/model-registry.md)) that back **all 34 of the contract's capabilities** —
> LLM, TTS, **speech-to-text**, text→image / text→video (+ image/video editing), image→3D, text
> embedding (dense + **late-interaction multi-vector**), audio separation / codec / polish,
> sound effects, speech emotion, image quality / restore / upscale / colorize / inpaint /
> relight, **defect detection**, matting & promptable segmentation, video upscale, frame
> interpolation, optical flow, character animation, talking-head, mesh rigging, and more.
> The contract is **additive**: capabilities and conformance levels grow at minor versions, and a
> breaking change is a major bump with a deprecation window — so **pin a tag** for production use.

A community-released, on-device Apple Silicon **runtime coordinator** for inference.

**MLXEngine does not do inference — packages do.** The engine instantiates each package,
holds the reference, and drives it: queuing, model loading, memory governance, and execution
serialization. Because the engine owns the package lifecycle, a runaway package cannot
destabilize the pipeline. It also presents one common way to engage every model, so
cross-model work is uniform from a programming standpoint.

> MIT licensed — the engine code is open to build on. This is **separate** from the two-layer
> weight/port-code license **declaration** every package makes (C7/C8). Since contract 1.28.0 that
> declaration is an information requirement, not a load-time gate: the engine classifies each license
> against its policy and reports findings on `licenseAdvisories` rather than refusing. Pass
> `licenseEnforcement: .blocking` to restore hard rejection.

> ### ⚠ Upgrading from v0.36.0 or earlier — read before bumping
>
> **The license gate's default flipped in v0.37.0 / contract 1.28.0.** Through **v0.36.0 (contract
> 1.27.0)** `MLXServeEngine.register()` threw `EngineError.licenseRejected` for any license outside
> the policy — unconditionally, with no way to opt out. From **v0.37.0** the default is
> `licenseEnforcement: .advisory`: the same package now **registers**, and the finding is recorded on
> `licenseAdvisories` instead.
>
> **A version bump alone therefore loosens the policy silently.** If your app must not load
> non-permissive weights — a commercial distribution, or CI asserting the fleet stays clean —
> the bump must be paired with an explicit:
>
> ```swift
> MLXServeEngine(licenseEnforcement: .blocking)   // pre-1.28.0 behavior, layer-naming included
> ```
>
> Nothing warns you at compile time: the parameter is defaulted, so old call sites keep building. The
> one runtime signal is the `[License]` log line the engine emits per advisory. Construct the engine in
> **one** place and set the policy there.

## Packages
- **MLXToolKit** — the contract surface every package conforms to (capabilities, canonical
  schemas, artifacts, license types, `PackageConfiguration`, the `ModelPackage` protocol +
  `PackageManifest`, and the `InferenceActor` isolation domain). Depend on this to build a
  conformant package; it does not pull in the runtime.
- **MLXServeCore** — the runtime coordinator. `MLXServeEngine` registers packages, classifies their
  two-layer license declaration (advisory by default) + enforces device-eligibility (C10) admission,
  and lazily constructs / loads /
  routes / evicts each `ModelPackage` by capability, backed by a `MemoryGovernor` (budget +
  LRU eviction of idle residents) and multi-package-per-capability routing (select by PackageID).
  Since 0.21.0 the engine also owns the **MLX GPU buffer-pool policy** — a bounded `cacheLimit`
  derived from the governor budget by default (opt out via `GPUCacheConfiguration.unmanaged`),
  `trimCaches()`, and `gpuPoolSnapshot()` telemetry (`docs/architecture.md` R-MEM-2). Since 0.26.0
  it also does **mid-run governor preemption + requeue** on top of idle-LRU eviction
  (`docs/run-lifecycle.md`). Hub SHA256 verification is still in progress — the materialization
  executor verifies per-file size only.

> **Tool-protocol exposure (MCP) is deliberately not part of the engine.** A bridge belongs in an
> external utility app that consumes MLXEngine: enumerate surfaces via `registeredCapabilities` →
> `packages(for:)` → `manifest(for:)` → `surfaces`, then invoke `run(_:package:)`. Those types are
> public and `Codable`, so the bridge owns its wire format while the engine stays protocol-agnostic.
> C0–C14's C11 exists to make that client possible.
- **MLXServeConformance** — the C0–C14 self-check harness, plus the offline **MAT** (weight
  auto-materialization) and **CAN** (cooperative-cancellation cadence) gates each package runs in
  its own test suite. **MLXServeConformanceNN** carries the MLXNN half of the C14 **INF** gate
  (the `Module` training-flag walk), split out so `MLXServeConformance` itself stays MLX-free.
- **MLXHubMetadata** — metadata-only hub access (file listings + sizes) behind an injectable seam,
  so the engine can size a download before it starts. Not a downloader.
- **MLXEngineTestKit** — the opt-in validation harness category testing apps share (memory split
  readout, admissibility tiers, phase-tagged trace, and the `[CAN]` / `[INF]` live benches).
- **MLXEngineUI** — reusable SwiftUI for engine management (model-storage + web-search settings,
  and `ModelStateView` — the live "downloading weights / first load is heavy / ready" strip bound to
  `MLXServeEngine.preparation`) plus the Marquee design tokens, so consuming apps share one look.
  (Product UI stays in the app.) **Using this UI requires consumer-app entitlements — see below.**
- **MLXRetrievalKit** (+ **MLXRetrievalKitContracts**) — reusable, MLX-free web retrieval / RAG
  grounding (Brave-backed) any package or app can use to ground answers with current sources.

## Consuming MLXEngineUI — required entitlements
The model-storage + download UI (`ModelStorageSettingsView`, `ModelStateView`) reads/writes model
weights in a **user-chosen folder outside the app sandbox**, so a sandboxed consumer app must grant:

- `com.apple.security.files.user-selected.read-write` — the user picks the model-store folder.
- `com.apple.security.files.bookmarks.app-scope` — persist security-scoped access to it across launches.

The user must pick a model-store folder before any non-bundled weights download
(`ModelStorageModel.resolvedModelsDirectory` is `nil` until then, and `ModelStore(root: nil)` falls
back to `~/Documents/huggingface`, which the sandbox blocks). Route the user to the storage UI first;
`MLXServeEngine.needsDownload(_:package:)` tells you when a capability still needs to materialize weights.
(A non-sandboxed app needs no entitlements and may read weights directly.)

## Build
Build with Xcode / `xcodebuild` (macOS 26.2+), or with SwiftPM. `Package.swift` is the
authoritative manifest; this repo contains only the package — not the XCLWorkspace.

```bash
swift build
swift test
```

**On a toolchain whose SwiftPM still defaults to the deprecated `native` build system, pass
`--build-system swiftbuild`.** `MLXServeCore` links MLX, and MLX loads its Metal kernels from a
`default.metallib` compiled from Cmlx's `.metal` sources into a colocated resource bundle — only
`swiftbuild` (and Xcode) produces it. Under `native` there is no metallib, so the first allocator
call aborts the test process. The engine itself degrades safely (see R-MEM-2), and the GPU-touching
tests self-skip, but no GPU work can run in such a process. CI pins `swiftbuild`.

## Contributing
A contribution is a package that registers one or more capabilities and passes the C0–C14
conformance gate. See `CONTRIBUTING.md`.
