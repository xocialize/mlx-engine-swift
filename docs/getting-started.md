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

## Build

Requires macOS 26.2+ and a recent Swift toolchain.

```bash
swift build
swift test
```

See [Contributing a package](contributing-a-package.md) for the conformance workflow.
