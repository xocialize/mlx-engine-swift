# MLXEngine (`mlx-engine-swift`)

> ## 🚧 Work in progress — not ready for use
>
> MLXEngine is in **early, active development**. The contract is still moving, the runtime
> coordinator is not yet built, and **nothing here is stable**. **Do not depend on it yet.**
>
> We're developing **in the open** for visibility, not yet for collaboration: **pull requests are
> not being accepted at this stage and will be closed.** This notice will be lifted — and
> contributions opened — once the contract is validated against the first real port and the
> runtime lands. Watch the repo to follow along.

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
- **MLXServeCore** — the runtime coordinator (placeholder; in progress).
- **MLXServeConformance** — the C0–C13 self-check harness (placeholder; in progress).

## Build
Build with Xcode / `xcodebuild` (macOS 26.2+). `Package.swift` is the authoritative manifest;
this repo contains only the package — not the XCLWorkspace.

## Contributing
A contribution is a package that registers one or more capabilities and passes the C0–C13
conformance gate. See `CONTRIBUTING.md`.
