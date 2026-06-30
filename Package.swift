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
        .library(name: "MLXEngineUI", targets: ["MLXEngineUI"]),
        // Test/validation harness — the reusable seams every category testing app needs (memory
        // split readout, transient reserve, admissibility tiers, phase-tagged trace, headless
        // autorun). SwiftUI + engine targets only; not part of the shipping UI. Opt-in.
        .library(name: "MLXEngineTestKit", targets: ["MLXEngineTestKit"]),
        // Web retrieval / grounding (current-knowledge access). MLX-free.
        .library(name: "MLXRetrievalKitContracts", targets: ["MLXRetrievalKitContracts"]),
        .library(name: "MLXRetrievalKit", targets: ["MLXRetrievalKit"]),
    ],
    targets: [
        // Contracts only. The dependency floor every package conforms to. Minimal deps.
        .target(name: "MLXToolKit"),

        // Runtime coordinator (placeholder this phase). Owns the package lifecycle.
        .target(name: "MLXServeCore", dependencies: ["MLXToolKit"]),

        // C0–C13 self-check harness (placeholder this phase).
        .target(name: "MLXServeConformance", dependencies: ["MLXToolKit"]),

        // Shared SwiftUI surface delivered to consuming apps. Carries the Marquee
        // design tokens and reusable settings panels (model storage, etc.).
        .target(name: "MLXEngineUI", dependencies: ["MLXToolKit", "MLXRetrievalKitContracts"]),

        // Reusable testing/validation harness for category testing apps. SwiftUI + engine targets
        // only (no third-party frameworks); kept lean + composable — apps extend it per package.
        .target(name: "MLXEngineTestKit", dependencies: ["MLXServeCore", "MLXToolKit"]),

        // Web-retrieval contracts (Foundation-only seams + DTOs + profile). No MLX, no network.
        .target(name: "MLXRetrievalKitContracts"),
        // Web-retrieval implementation: BraveSearchProvider + RetrievalService. MLX-free,
        // network-only — packages/apps call it to ground answers in current knowledge.
        .target(name: "MLXRetrievalKit", dependencies: ["MLXRetrievalKitContracts"]),

        .testTarget(name: "MLXToolKitTests", dependencies: ["MLXToolKit"]),
        .testTarget(name: "MLXServeCoreTests", dependencies: ["MLXServeCore", "MLXToolKit"]),
        .testTarget(name: "MLXServeConformanceTests", dependencies: ["MLXServeConformance", "MLXToolKit"]),
        .testTarget(name: "MLXRetrievalKitTests", dependencies: ["MLXRetrievalKit", "MLXRetrievalKitContracts"]),
    ]
)
