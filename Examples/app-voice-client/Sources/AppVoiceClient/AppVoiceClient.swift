import Foundation
import MLXKokoroTTS
import MLXNemotronSTT
import MLXQwenLLM
import MLXServeCore
import MLXToolKit

/// The smallest in-process client an app needs for a talking character: speech out with word
/// timings (`speak`), a freeform line and a schema-shaped JSON verdict (`respond`, `verdict`),
/// and live transcription (`listen`), all through ONE `MLXServeEngine` (AB-A-0308, AB-A-0311).
///
/// Every call is a canonical contract request; nothing here is package-specific except the three
/// registrations in `prepare`. Swap a backer (e.g. an LFM3-Omni package for `.llm`) by changing
/// its registration — the calls do not change.
///
/// Concurrency: the engine serializes inference on `@InferenceActor`, so concurrent calls queue
/// in arrival order (there is no per-request priority on the contract). A live STT session runs
/// per buffer between other runs, so it keeps transcribing while a line is generated or spoken.
public struct AppVoiceClient: Sendable {
    public let engine: MLXServeEngine

    /// - Parameter modelStore: the folder holding (or receiving) weights. In a sandboxed app this
    ///   must be a folder the user picked (security-scoped bookmark, `files.user-selected.read-write`
    ///   + `files.bookmarks.app-scope`) or one inside the app container; `nil` falls back to
    ///   `~/Documents/huggingface`, which the sandbox blocks.
    public init(modelStore: URL?) async {
        engine = MLXServeEngine()
        await engine.useModelStore(ModelStore(root: modelStore))
    }

    /// Register and load all three backers. First run downloads any missing weights into the
    /// model store (Kokoro ~0.35 GB, Nemotron 0.6B ~1.2 GB, Qwen3.5-4B 4-bit ~2.9 GB); check
    /// `engine.needsDownload(_:)` / `materializationPreview(_:)` first to show a first-run sheet.
    ///
    /// - Parameter sttRightContext: Nemotron's look-ahead in 80 ms frames (`attContextSize
    ///   [56, n]`): 0 = 80 ms chunks (fastest partials), 3 = 320 ms, 13 = 1.12 s (most accurate).
    public func prepare(llm: QwenModel = QwenModel(size: .b4, quant: .int4),
                        sttRightContext: Int = 3) async throws {
        try await engine.register(KokoroTTSPackage.registration, configuration: KokoroConfiguration())
        try await engine.register(NemotronSTTPackage.registration,
                                  configuration: NemotronSTTConfiguration(attContextSize: [56, sttRightContext]))
        try await engine.register(QwenLLMPackage.registration, configuration: QwenLLMConfiguration(model: llm))
        try await engine.prepare(.tts)
        try await engine.prepare(.stt)
        try await engine.prepare(.llm)
    }

    // MARK: - tts.speak

    public struct SpokenLine: Sendable {
        /// 16-bit PCM mono WAV (44-byte header).
        public let wav: Data
        public let sampleRate: Int
        public let duration: TimeInterval
        /// Seconds from the first sample. Kokoro's onsets run ~30 ms early (median, AB-R-0886);
        /// the engine does NOT shift them, so apply the +30 ms correction on the caller's side.
        public let words: [TTSWordTiming]
    }

    /// Kokoro voices are named (`af_heart`, `am_adam`, …: `KokoroVoice.allCases`). Speed is not
    /// a contract field and Kokoro runs at 1.0 through the engine.
    public func speak(_ text: String, voice: String = "af_heart") async throws -> SpokenLine {
        let request = TTSRequest(text: text, voice: VoiceSelector(.named(voice)), timingDetail: .words)
        guard let response = try await engine.run(request) as? TTSResponse else {
            throw PackageError.unsupportedCapability(.tts)
        }
        let rate = response.audio.sampleRate ?? 24_000
        let frames = max(0, response.audio.data.count - 44) / 2
        return SpokenLine(wav: response.audio.data, sampleRate: rate,
                          duration: Double(frames) / Double(rate),
                          words: response.timings?.words ?? [])
    }

    // MARK: - llm.respond

    /// The director's freeform line: thinking off (`.direct`), seeded for replay.
    public func respond(_ messages: [ChatMessage], maxTokens: Int = 80,
                        temperature: Double = 0.7, seed: UInt64? = nil) async throws -> LLMResponse {
        let request = LLMRequest(
            messages: messages,
            parameters: LLMParameters(temperature: temperature, maxTokens: maxTokens, seed: seed),
            mode: .direct)
        guard let response = try await engine.run(request) as? LLMResponse else {
            throw PackageError.unsupportedCapability(.llm)
        }
        return response
    }

    /// The director's verdict: one JSON value, grammar-constrained. `.jsonSchema` is enforced as
    /// valid JSON with the schema root's container (contract 1.16.0 V1); field names and types
    /// are steered by the schema text in the prompt, so validate the object on your side.
    public func verdict(_ messages: [ChatMessage], schema: String, maxTokens: Int = 160,
                        temperature: Double = 0.3, seed: UInt64? = nil) async throws -> LLMResponse {
        let request = LLMRequest(
            messages: messages,
            parameters: LLMParameters(temperature: temperature, maxTokens: maxTokens, seed: seed),
            mode: .direct,
            responseFormat: .jsonSchema(schema))
        guard let response = try await engine.run(request) as? LLMResponse else {
            throw PackageError.unsupportedCapability(.llm)
        }
        return response
    }

    // MARK: - stt.*

    /// Open a live session. Push mono Float32 at `handle.expectedSampleRate` (16 kHz for
    /// Nemotron) straight from an `AVAudioEngine` tap — `push` is copy-only and safe on the
    /// audio thread. `updates` yields CUMULATIVE partials (replace, don't append); `finish()`
    /// flushes and yields one `isFinal` chunk. Endpointing (VAD) is the host's: call `finish()`
    /// when your VAD sees end of speech, then open the next session. One session at a time.
    public func listen(language: String? = "en-US") async throws -> STTLiveHandle {
        try await engine.transcribeLive(STTSessionRequest(language: language))
    }
}
