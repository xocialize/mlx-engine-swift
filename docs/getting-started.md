# Getting started

## Add the dependency

MLXEngine is consumed via **Swift Package Manager only**.

```swift
.package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.36.0")
```

The contract is pre-1.0 and additive; **pin a tag** for production use (there is no `1.0.0` to
resolve against yet).

**mlx-swift (v0.82.2+).** The engine takes mlx-swift from `https://github.com/xocialize/mlx-swift`
`from: "0.33.2"`: upstream 0.33.0 (the first release with the `_updateInternal` leak fix) with the
vendored MLX's head-dim-split attention routes disabled, because upstream 0.33.0 aborts on M5 for
head-256 masked prefills of 1024+ tokens (AB-R-1009), plus upstream's fix for GPU pads past 2^31
elements (ml-explore/mlx#4744, AB-A-0332). If you declare mlx-swift yourself, declare that
fork URL at your root, not ml-explore's, or your root wins and you get the unpatched build. See
[architecture: where mlx-swift comes from](architecture.md#where-mlx-swift-comes-from-the-leak-fix-floor-v0741-ab-a-0249).

Conform a package against the **contract** product; you do not need the runtime to build a
conformant package:

```swift
.target(name: "MyTTSPackage", dependencies: [
    .product(name: "MLXToolKit", package: "mlx-engine-swift")
])
```

## Products

- **MLXToolKit** — contracts only (capabilities, canonical schemas, artifacts, license types,
  `PackageConfiguration`, `ModelPackage` + `PackageManifest`, `InferenceActor`). Depend on this
  to build a package.
- **MLXServeCore** — the runtime coordinator: registration, the two-layer license gate,
  admission + `MemoryGovernor`, residency, the GPU buffer-pool policy, run lifecycle. Links MLX
  (allocator API only).
- **MLXMemoryPolicy** — the governor's admission and eviction rules (`MemoryPolicy`,
  `MemoryGovernor`, `PreemptionPolicy`) as pure functions. MLX-free; re-exported by MLXServeCore.
- **MLXServeConformance** — the C0–C14 self-check harness, plus the offline MAT and CAN gates.
  MLX-free. **MLXServeConformanceNN** adds the MLXNN half of the C14 INF gate; take it only if
  your package has a `Module` graph.
- **MLXHubMetadata** — metadata-only hub access (file listings + sizes) behind
  `HubMetadataProviding`. Not a downloader; it exists so the engine can size a download before it
  starts.
- **MLXEngineUI** — reusable SwiftUI for engine management (model storage, `ModelStateView`) plus
  the Marquee design tokens. Needs the sandbox entitlements listed in the README.
- **MLXEngineTestKit** — the opt-in validation harness for category testing apps.
- **MLXRetrievalKit** (+ **MLXRetrievalKitContracts**) — MLX-free Brave-backed web retrieval.

## First run: how much will this download?

Since contract 1.24 the engine executes first-run downloads itself: `prepare()` materializes a
`WeightSourcing` configuration's missing sources into the engine's `ModelStore` root before the
package loads (packages with their own downloader opt out via `SelfMaterializing`). Two seams let
an app show a first-run affordance before any package code runs:

```swift
await engine.useModelStore(ModelStore(root: chosenFolder))

if await engine.needsDownload(.llm),
   let preview = await engine.materializationPreview(.llm) {
    // preview.sources — per missing source: role, repo, expectedBytes
    // preview.totalBytes / preview.freeBytes / preview.fits  (each nil = "unknown", never a refusal)
}

let package = try await engine.prepare(.llm)   // downloads + loads
```

`prepare()` runs a **disk precheck** on the way in: when the size is knowable and the pending
download exceeds free space on the store volume, it throws `EngineError.insufficientDisk(required:
free:)` instead of failing gigabytes into the write. An unreachable hub means unknown size, which
never blocks a load; hosts that manage disk themselves can pass `diskPrecheckEnabled: false` to
`MLXServeEngine.init`. Live progress during the download arrives on `engine.preparation`
(`.downloading(fraction:bytesPerSecond:)`).

## Build

Requires macOS 26.2+ and a recent Swift toolchain.

```bash
swift build
swift test
```

On a toolchain whose SwiftPM still defaults to the deprecated `native` build system, add
`--build-system swiftbuild` to both. `native` does not compile MLX's `.metal` sources into a
colocated `default.metallib`, so the first MLX allocator call in the test process aborts it. CI
pins `swiftbuild` for the same reason; see the README build section.

For a complete app-side client (TTS with word timings, an LLM line plus a JSON verdict, live STT, all
in one process, with sandbox notes and measured latency), see
[`Examples/app-voice-client`](../Examples/app-voice-client/README.md).

See [Contributing a package](contributing-a-package.md) for the conformance workflow.
