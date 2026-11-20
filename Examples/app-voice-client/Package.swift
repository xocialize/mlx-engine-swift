// swift-tools-version: 6.2
import PackageDescription

// app-voice-client — the smallest in-process client a (sandboxed) macOS app needs for speech
// out with word timings, a chat reply / JSON verdict, and live transcription, all through ONE
// MLXServeEngine (AB-A-0308, AB-A-0311). `AppVoiceClient` is the library an app copies or links;
// `voice-shell-bench` is the Release measurement harness the receipts came from.
//
// Standalone package: it is NOT part of the engine's root manifest and does not build with it.
let package = Package(
    name: "app-voice-client",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppVoiceClient", targets: ["AppVoiceClient"]),
        .executable(name: "voice-shell-bench", targets: ["voice-shell-bench"]),
    ],
    dependencies: [
        // The coordinator (contract 1.66.0 at v0.81.0+; v0.82.1 floors mlx-swift on the fleet fork).
        .package(url: "https://github.com/xocialize/mlx-engine-swift", from: "0.82.1"),
        // tts — Kokoro-82M, word + phoneme timings (contract 1.65.0).
        .package(url: "https://github.com/xocialize/mlx-kokoro-tts-swift", from: "0.6.0"),
        // stt — Nemotron 3.5 ASR streaming 0.6B, the canonical live plane (contract 1.39.0).
        .package(url: "https://github.com/xocialize/mlx-nemotron-stt-swift", from: "0.4.0"),
        // llm — Qwen3.5 (thinking off in .direct; grammar-constrained responseFormat, 1.16.0).
        .package(url: "https://github.com/xocialize/mlx-qwen-llm-swift", from: "0.7.0"),
        // ROOT declaration of mlx-swift: the fleet fork (AB-D-0264). A consumer that declares
        // mlx-swift itself must name this URL, or the root wins with the unpatched M5 build.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.33.1"),
        // Bench only: count generated tokens (mlx-qwen-llm-swift 0.7.0 returns no LLMUsage, AB-A-0217).
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "AppVoiceClient",
            dependencies: [
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXKokoroTTS", package: "mlx-kokoro-tts-swift"),
                .product(name: "MLXNemotronSTT", package: "mlx-nemotron-stt-swift"),
                .product(name: "MLXQwenLLM", package: "mlx-qwen-llm-swift"),
            ]
        ),
        .executableTarget(
            name: "voice-shell-bench",
            dependencies: [
                "AppVoiceClient",
                .product(name: "MLXEngineTestKit", package: "mlx-engine-swift"),
                .product(name: "MLXNemotronSTT", package: "mlx-nemotron-stt-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
