# Getting started

## Add the dependency

MLXEngine is consumed via **Swift Package Manager only**.

```swift
.package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "1.0.0")
```

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
- **MLXServeCore** — the runtime coordinator (in progress).
- **MLXServeConformance** — the C0–C13 self-check harness (in progress).
- **MLXHubMetadata** — metadata-only hub access (file listings + sizes) behind
  `HubMetadataProviding`. Not a downloader; it exists so the engine can size a download before it
  starts.

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

See [Contributing a package](contributing-a-package.md) for the conformance workflow.
