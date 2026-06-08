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
    ],
    targets: [
        // Contracts only. The dependency floor every package conforms to. Minimal deps.
        .target(name: "MLXToolKit"),

        // Runtime coordinator (placeholder this phase). Owns the package lifecycle.
        .target(name: "MLXServeCore", dependencies: ["MLXToolKit"]),

        // C0–C13 self-check harness (placeholder this phase).
        .target(name: "MLXServeConformance", dependencies: ["MLXToolKit"]),

        .testTarget(name: "MLXToolKitTests", dependencies: ["MLXToolKit"]),
        .testTarget(name: "MLXServeCoreTests", dependencies: ["MLXServeCore", "MLXToolKit"]),
        .testTarget(name: "MLXServeConformanceTests", dependencies: ["MLXServeConformance", "MLXToolKit"]),
    ]
)
