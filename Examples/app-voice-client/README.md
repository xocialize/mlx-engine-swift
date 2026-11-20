# app-voice-client

The smallest in-process client a macOS app (sandboxed or not) needs for a talking character, all
through one `MLXServeEngine`:

| App call | Engine call | Backer (today) | Contract |
|---|---|---|---|
| `speak(text, voice)` → WAV + sampleRate + duration + word timings | `engine.run(TTSRequest(…, timingDetail: .words))` | `mlx-kokoro-tts-swift` ≥ 0.6.0 (Kokoro-82M) | 1.65.0 |
| `respond(messages)` → a freeform line | `engine.run(LLMRequest(…, mode: .direct))` | `mlx-qwen-llm-swift` ≥ 0.7.0 (Qwen3.5-4B 4-bit) | 1.33.0 (seed) |
| `verdict(messages, schema)` → one JSON object | `engine.run(LLMRequest(…, responseFormat: .jsonSchema(schema)))` | same | 1.16.0 |
| `listen()` → live partials + final | `engine.transcribeLive(STTSessionRequest(…))` → `STTLiveHandle` | `mlx-nemotron-stt-swift` ≥ 0.4.0 (Nemotron 3.5 ASR streaming 0.6B) | 1.39.0 |

The engine at v0.82.1 implements contract 1.66.0, which covers all four rows. Written for VRMXG's shell (AB-A-0308, AB-A-0311).

## Linking

Copy `Package.swift`'s dependency block. Link `MLXServeCore`, `MLXToolKit`, `MLXKokoroTTS`,
`MLXNemotronSTT` and `MLXQwenLLM`. If your root declares mlx-swift, it must name the fleet's fork
`https://github.com/xocialize/mlx-swift` (from 0.33.1, AB-D-0264); otherwise your root wins and you
get the build that aborts on M5. Build with Xcode or `swift build --build-system swiftbuild`,
because the `native` build system ships no `default.metallib`.

## Sandbox

- **Weights:** put the model store in a folder the user picked (`com.apple.security.files.user-selected.read-write`
  + `com.apple.security.files.bookmarks.app-scope`, start a security-scoped access before
  `AppVoiceClient(modelStore:)`), or inside the app container. `ModelStore(root: nil)` falls back to
  `~/Documents/huggingface`, which the sandbox blocks.
- **First-run download:** `prepare()` downloads missing weights (about 4.5 GB in all). It needs
  `com.apple.security.network.client`. Ask `engine.needsDownload(_:)` and
  `engine.materializationPreview(_:)` first if you want to show a first-run sheet.
- **Microphone:** add `com.apple.security.device.audio-input` and `NSMicrophoneUsageDescription`.
  Push from the `AVAudioEngine` tap, converted to mono Float32 at `handle.expectedSampleRate`
  (16 kHz). `push` only copies, so it is safe on the audio thread. MLX never runs there.
- **No XPC and no loopback server.** Everything runs in the app's process. The inference actor
  serializes runs, so calls queue in arrival order. A live session keeps transcribing between
  other runs.

## Endpointing

The live plane has no VAD. Run your own (VoiceChatKit's `EnergyVAD`, AB-A-0312) and call
`finish()` at end of speech: one `isFinal` chunk arrives and `updates` ends. Then open the next
session. Only one session can be open at a time.

## Expected latency (M5 Max, Release, warm, all three resident)

| Call | Median | p90 |
|---|---|---|
| `speak`: 10-word line + `.words` (3.5 s of audio) | 61 ms | 61 ms |
| `respond`: first token (≈200-token prompt; a 1-token reply) | 66 ms | 66 ms |
| `respond`: director line (stops by itself at ≈26 tokens) | 212 ms | 232 ms |
| `respond`: full 60-token reply | 426 ms | 427 ms |
| `verdict`: `.jsonSchema`, ≈44 tokens, 10/10 parse with every key | 456 ms | 610 ms |
| `listen`: word latency, look-ahead `[56,3]` (default) / `[56,0]` | 354 / 298 ms | 530 / 462 ms |
| `listen`: `finish()` → final | 51 ms | — |

Resident memory with all three: 4.0 GB after `prepare`, 5.1 GB steady after use, 7.5 GB peak (`phys_footprint`).
A live session left running during a line, a verdict and a TTS line changes STT word latency by
< 10 ms and adds < 50 ms to the other calls. Raw logs and method: [MEASUREMENTS.md](MEASUREMENTS.md).

**Line length:** one `speak` call is at most 510 phoneme tokens, about 450–500 characters. 436 characters (23.7 s of audio) took 436 ms, and 573 characters throws `invalidInput`. Split longer lines at sentence ends and offset the word timings.

**Known gap (AB-A-0321, mlx-audio):** every `prepare(.tts)` also fetches Kokoro's ~9 MB G2P model
(`beshkenadze/kitten-tts-g2p`) into the HF cache, outside the model store and `needsDownload`. Until it
is fixed, the first `prepare` after each launch needs the network-client entitlement and a network.

## Measuring

```bash
swift build -c release --build-system swiftbuild --product voice-shell-bench
.build/release/voice-shell-bench --store /path/to/models --llm 4b --stt-right 3 --runs 10
```
