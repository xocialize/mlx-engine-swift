# Measurements: voice-shell-bench

Measured 2026-11-19 on a Mac Studio (Mac17,14), M5 Max, 128 GB, macOS 27. Release build (`swift build -c release --build-system swiftbuild`).
The bench is `Sources/voice-shell-bench/main.swift` over `AppVoiceClient`: one `MLXServeEngine`
holding three co-resident packages. The graph resolved to mlx-engine-swift 0.82.1 (contract 1.66.0),
mlx-kokoro-tts-swift 0.6.0 (kokoro-mlx-swift 0.2.1), mlx-nemotron-stt-swift 0.4.0
(nemotron-asr-mlx-swift 0.2.0), mlx-qwen-llm-swift 0.7.0 (mlx-swift-lm 3.33.0), and mlx-swift 0.33.1
from the xocialize fork. Weights were local (`--store /Volumes/DEV_VOL1/Models`), and the GPU was idle
(< 10 % for 30 s) before each run. All numbers are warm: after 2–3 warm-up calls per path.

How to read the rows:
- **TTS:** wall time of `engine.run(TTSRequest(timingDetail: .words))` for a 10-word line, WAV encoding included.
- **LLM-TTFT:** a 1-token reply, i.e. prefill (~201 prompt tokens) plus one decode step and engine overhead.
  The Qwen package streams nothing and reports no `LLMUsage` (AB-A-0217), so this proxy is the
  honest first-token figure. Token counts come from the model's own tokenizer.
- **LLM-LINE:** the director's line call (`mode: .direct`, maxTokens 60), which stops by itself at about 26 tokens.
  **LLM-LINE60** asks for a longer answer, so the 60-token cap ends it.
- **LLM-VERDICT:** `responseFormat: .jsonSchema(schema)` with a 5-key verdict schema, parsed with `JSONSerialization`.
- **STT:** `engine.transcribeLive`, fed in real time (100 ms buffers every 100 ms) from a 7.7 s Kokoro clip.
  Word latency = the wall time the k-th word first appears in a partial, minus the time the k-th word's
  audio finished being pushed (from Kokoro's word end times). `finalAfterFinish` = `finish()` → the `isFinal` chunk.
- **CONTENDED:** one live session running while a line, a verdict and a TTS line run.
- **MEM:** `phys_footprint`: after `prepare` of all three, at the end, and peak (20 ms sampler).

## Final run (acs [56,3], `--runs 10`)

```
[MEM] prepared tts+stt+llm (Qwen3.5 · 4B (int4), stt acs=[56,3]) in 0.7s phys=4.04GB
[TTS] voice=af_heart words=10 audio=3.52s sr=24000 n=20 median=61ms p90=61ms min=60ms max=62ms rtfx=58.2
      words: Stay@0.28 close@0.53 the@1.10 bridge@1.20 ahead@1.46 is@1.70 not@1.85 safe@2.11 after@2.42 dark@2.70
[TTS] voice=am_adam words=10 audio=3.60s sr=24000 n=20 median=63ms p90=64ms min=62ms max=65ms rtfx=57.5
      words: Stay@0.25 close@0.50 the@0.96 bridge@1.05 ahead@1.32 is@1.56 not@1.70 safe@1.96 after@2.30 dark@2.60
[LLM-TTFT] model=Qwen3.5 · 4B (int4) promptTokens≈201 n=10 wall(maxTokens=1) median=66ms p90=66ms usagePrefill median=0ms (0 = package reports no usage)
[LLM-LINE] n=10 maxTokens=60 meanTokens=25.7 median=212ms p90=232ms decode≈157tok/s (tokens−1 over wall−TTFT)
      line0: The bridge washed out last winter, Sam. It's only half-repaired, and it won't hold a soaked weight.
      line1: The bridge to the north broke last winter, Sam. Most folks avoided the path since the cliffs are too shaky in the rain.
      line2: The key hangs right by the stove, Sam. But don't climb those west cliffs, the rain makes them shake.
[LLM-LINE60] n=10 maxTokens=60 meanTokens=60.0 median=426ms p90=427ms
[LLM-VERDICT] n=10 parsed=10/10 allKeys=10/10 meanTokens=44.3 median=456ms p90=610ms
      sample: {"remember":"The bridge washed out last winter","action":{"kind":"lookAt","target":"the bridge outside"},"gesture":"shake","emotion":"stern","end":true}
[STT] acs=[56,3] clip=7.7s words=28 sessions=3 wordLatency median=354ms p90=530ms max=641ms finalAfterFinish median=51ms
      final: I came in from the North Path.  The bridge is half gone, and the river is loud.  Have you seen my brother?  He came here a week ago
[CONTENDED] under live STT: line=232ms verdict=498ms tts=70ms
[CONTENDED] stt wordLatency median=348ms p90=534ms max=636ms overruns=0
[MEM] end phys=5.10GB samplerPeak=7.52GB lifetimePeak=7.71GB
```

## STT look-ahead [56,0] (same build, separate process)

```
[STT] acs=[56,0] clip=7.7s words=28 sessions=3 wordLatency median=298ms p90=462ms max=493ms finalAfterFinish median=39ms
[CONTENDED] under live STT: line=288ms verdict=587ms tts=103ms
[CONTENDED] stt wordLatency median=298ms p90=464ms max=495ms overruns=0
```

## Noted while measuring

On every `prepare(.tts)`, Kokoro's `MisakiTextProcessor` downloads `beshkenadze/kitten-tts-g2p`
(~9 MB) into `HubCache.default/mlx-audio/`. The repo ships no `config.json`, so
`ModelUtils.resolveOrDownloadModel` never takes the cached copy. That download is outside engine
materialization; reported to mlx-audio as AB-A-0321. The timings above are warm and exclude it.
