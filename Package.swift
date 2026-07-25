// swift-tools-version: 6.2
import PackageDescription

// MLXEngine — public Swift package (xocialize/mlx-engine-swift), MIT licensed.
// Repo base is THIS package only — never the XCLWorkspace. The workspace references
// it as a local path dependency internally; shipped consumers pin a tagged version.
//
// Platform: macOS primary (26.2+ for Neural Accelerators). iOS is a future consideration —
// MLXToolKit sources are kept platform-neutral so adding .iOS(...) here is purely additive.
let package = Package(
    name: "mlx-engine-swift",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MLXToolKit", targets: ["MLXToolKit"]),
        .library(name: "MLXServeCore", targets: ["MLXServeCore"]),
        .library(name: "MLXServeConformance", targets: ["MLXServeConformance"]),
        // The MLXNN-dependent half of the INF gate (C14). Split from MLXServeConformance so that
        // target stays MLX-free — mlx-audio-polish-swift (the non-MLX capability seam) consumes
        // the suite, and a functional port declaring `.notApplicable` needs no MLXNN either.
        .library(name: "MLXServeConformanceNN", targets: ["MLXServeConformanceNN"]),
        // Metadata-only hub access (file listings + sizes) behind an injectable seam. NOT a
        // downloader — it exists so the engine can preview download size / disk fit (MS-3).
        .library(name: "MLXHubMetadata", targets: ["MLXHubMetadata"]),
        .library(name: "MLXEngineUI", targets: ["MLXEngineUI"]),
        // Test/validation harness — the reusable seams every category testing app needs (memory
        // split readout, transient reserve, admissibility tiers, phase-tagged trace, headless
        // autorun). SwiftUI + engine targets only; not part of the shipping UI. Opt-in.
        .library(name: "MLXEngineTestKit", targets: ["MLXEngineTestKit"]),
        // Web retrieval / grounding (current-knowledge access). MLX-free.
        .library(name: "MLXRetrievalKitContracts", targets: ["MLXRetrievalKitContracts"]),
        .library(name: "MLXRetrievalKit", targets: ["MLXRetrievalKit"]),
    ],
    dependencies: [
        // The repo's ONE runtime dependency, scoped to MLXServeCore: the engine owns the
        // process-global MLX GPU buffer-pool policy (cache limit / trim / telemetry — N5),
        // which requires the MLX allocator API. Still no inference math in the engine.
        // MLXToolKit (the contract packages build against offline) stays dependency-free —
        // SwiftPM's target-based resolution keeps MLXToolKit-only consumers from pulling MLX.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.5"),
    ],
    targets: [
        // Contracts only. The dependency floor every package conforms to. Minimal deps.
        .target(name: "MLXToolKit"),

        // Runtime coordinator (placeholder this phase). Owns the package lifecycle.
        // Links MLX for the GPU buffer-pool policy (N5) — allocator API only, no kernels.
        .target(name: "MLXServeCore", dependencies: [
            "MLXToolKit",
            "MLXHubMetadata",
            .product(name: "MLX", package: "mlx-swift"),
        ]),

        // Metadata-only HF access (URLSession + Foundation; no MLX, no downloads). Keeps
        // MLXToolKit network-free while letting the engine size a materialization before it runs.
        .target(name: "MLXHubMetadata", dependencies: ["MLXToolKit"]),

        // C0–C14 self-check harness (placeholder this phase). Deliberately MLX-free.
        .target(name: "MLXServeConformance", dependencies: ["MLXToolKit"]),

        // INF gate (C14), MLXNN half: the shared `Module` → training-flag walk. A package with an
        // MLXNN model graph adds this product alongside MLXServeConformance; one without (a
        // functional port, or a non-MLX package) needs only MLXServeConformance.
        .target(name: "MLXServeConformanceNN", dependencies: [
            "MLXServeConformance",
            .product(name: "MLXNN", package: "mlx-swift"),
        ]),

        // Shared SwiftUI surface delivered to consuming apps. Carries the Marquee
        // design tokens and reusable settings panels (model storage, etc.).
        .target(name: "MLXEngineUI", dependencies: ["MLXToolKit", "MLXRetrievalKitContracts"]),

        // Reusable testing/validation harness for category testing apps. SwiftUI + engine targets
        // only (no third-party frameworks); kept lean + composable — apps extend it per package.
        .target(name: "MLXEngineTestKit", dependencies: ["MLXServeCore", "MLXToolKit", "MLXServeConformance"]),

        // Web-retrieval contracts (Foundation-only seams + DTOs + profile). No MLX, no network.
        .target(name: "MLXRetrievalKitContracts"),
        // Web-retrieval implementation: BraveSearchProvider + RetrievalService. MLX-free,
        // network-only — packages/apps call it to ground answers in current knowledge.
        .target(name: "MLXRetrievalKit", dependencies: ["MLXRetrievalKitContracts"]),

        .testTarget(name: "MLXToolKitTests", dependencies: ["MLXToolKit"]),
        .testTarget(name: "MLXHubMetadataTests", dependencies: ["MLXHubMetadata", "MLXToolKit"]),
        .testTarget(name: "MLXServeCoreTests", dependencies: [
            "MLXServeCore", "MLXToolKit", "MLXHubMetadata",
            // For pre-setting / reading the process-global cache limit around engine init.
            .product(name: "MLX", package: "mlx-swift"),
        ]),
        .testTarget(name: "MLXServeConformanceTests", dependencies: ["MLXServeConformance", "MLXToolKit"]),
        // Exercises the INF walk against real MLXNN module graphs (no weights, no kernels — the
        // flags are set by `train(_:)`, which touches no arrays).
        .testTarget(name: "MLXServeConformanceNNTests", dependencies: [
            "MLXServeConformanceNN", "MLXServeConformance",
            .product(name: "MLXNN", package: "mlx-swift"),
        ]),
        .testTarget(name: "MLXRetrievalKitTests", dependencies: ["MLXRetrievalKit", "MLXRetrievalKitContracts"]),
    ]
)
