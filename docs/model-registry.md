# MLXEngine Model Registry

The **living** registry of every model package the engine can serve — both **availability awareness**
(what exists, where, published) and **state** (validated? efficiency-adopted? engine version). It
supersedes the generated `mlxengine-model-catalog` snapshot, which went stale because nothing kept it
current.

> **This file is maintained as a step of integration, not regenerated.** When you bring a package up,
> publish a tag, validate it in-app, or run its efficiency-adoption sweep, **update its row here in the
> same change** (see the `mlx-swift-integration` skill, Stage 2 → "Register in the model registry").
> A row that drifts from reality is a bug. The capability contract source of truth stays
> `Sources/MLXToolKit/Capability.swift`; this is the *provider* index against it.

**Columns**
- **Package / Model** — the `MLX<Name>` wrapper (or core) + the underlying model.
- **Role** — `wrapper+core` (single folded repo) · `wrapper`/`core` (split) · `shared` · `engine`.
- **Home** — bucket path under `~/Development` (`PROD` = published+tagged+URL-consumed · `WIP` = active · research = WAN_DEV/LTX_DEV clusters).
- **Avail** — ✅ published (URL/tag) · 🧪 WIP/local · 🔬 research.
- **Val** — in-app live-validation: ✅ validated · 🟡 partial/CLI-only · ⬜ not yet.
- **Eff** — 1.14 efficiency adoption (split footprint + mmap + per-stage evict + BudgetAware):
  ✅ adopted · 🔵 in progress · 🟡 brief written · ⬜ not started · ➖ n/a (trivial/single-component low-peak).
- **Eng** — engine contract the package targets / is pinned to (blank = backfill).

_Seeded 2026-06-30. Val/Eff/Eng are best-effort at seed time — **backfill per package as it's revisited.**_

---

## 🔊 Audio

| Capability | Package | Model | Role | Home | Avail | Val | Eff | Eng |
|---|---|---|---|---|---|---|---|---|
| tts | mlx-kokoro-tts-swift | Kokoro-82M | wrapper+core | audio/PROD | ✅ | ✅ | ➖ | | <!-- Eff n/a: single tiny model (82M, flat bf16 ~500 MB), negligible transient; engine bump not worth the churn. -->
| tts | mlx-qwen3-tts-swift | Qwen3-TTS | wrapper+core | audio/PROD | ✅ | ✅ | ✅ | 0.15.0 | <!-- split: 1.7B-8bit weights 2.65 GB + measured talker transient ~4.0 GB; FootprintConfigured (variant×size×quant); P2 N/A (talker+codePredictor interleave per frame). -->
| tts | mlx-voxcpm2-tts-swift | VoxCPM2 | wrapper+core | audio/PROD | ✅ | ✅ | ✅ | 0.15.0 | <!-- split: weights floor 9.3 GB + measured transient 4.0 GB (flat 11 GB under-declared the ~11.9 GB peak); QuantConfigured; P2 N/A (TSLM/RALM/LocDiT interleave per patch). -->
| audioSeparation | mlx-demucs-swift | HTDemucs v4 | wrapper+core | audio/PROD | ✅ | ✅ | ⬜ | |
| audioSeparation | mlx-mel-roformer-swift | Mel-Band-RoFormer | wrapper+core | audio/PROD | ✅ | 🟡 | ⬜ | |
| speechEmotion | mlx-emotion2vec-swift | emotion2vec+ | wrapper+core | audio/PROD | ✅ | ✅ | ➖ | |
| audioCodec | mlx-mimi-codec-swift | Kyutai Mimi | wrapper+core | audio/PROD | ✅ | ✅ | ➖ | |
| audioPolish | mlx-audio-polish-swift | AudioPolishKit (DSP) | wrapper+core | audio/PROD | ✅ | ✅ | ➖ | |
| soundEffect | mlx-moss-soundeffect-swift | MOSS SoundEffect | wrapper+core | audio/PROD | ✅ | ✅ | ⬜ | |

## 🖼️ Image

| Capability | Package | Model | Role | Home | Avail | Val | Eff | Eng |
|---|---|---|---|---|---|---|---|---|
| textToImage | ernie-image-swift | ERNIE-Image-Turbo | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| textToImage | lens-mlx-swift | Lens 3.8B | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| textToImage / imageEdit | boogu-image-swift | Boogu-Image-0.1 | wrapper+core | image/WIP | 🧪 | 🟡 | ⬜ | |
| imageEdit | qwen-image-edit-swift | Qwen-Image-Edit-2511 | wrapper+core | image/PROD | ✅ | ✅ | ✅ | 0.15.0 |
| imageColorize | mlx-ddcolor-swift | DDColor | wrapper+core | image/PROD | ✅ | ✅ | ✅ | 0.15.0 |
| imageRestore | mlx-nafnet-swift | NAFNet (v0.3.2) | wrapper+core | image/PROD | ✅ | ✅ | ✅ | 0.15.0 |
| imageUpscale | mlx-realesrgan-swift | Real-ESRGAN 4× | wrapper+core | image/PROD | ✅ | ✅ | ✅ | 0.15.0 |
| imageInpaint | mlx-lama-swift | LaMa + MI-GAN | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| matting | mlx-birefnet-swift | BiRefNet | wrapper+core | image/PROD | ✅ | ✅ | ✅ P1a (P1b deferred) | 0.14.0 |
| promptSegment / trackObject | mlx-edgetam-swift | EdgeTAM (SAM 2) | wrapper+core | image/PROD | ✅ (v0.3.2) | ✅ | ⬜ | |
| imageQualityScore | mlx-siglip2-iqa-swift | SigLIP2 NR-IQA | wrapper+core | image/WIP | ✅ | ✅ | ➖ | |
| opticalFlow | mlx-sea-raft-swift | SEA-RAFT | wrapper+core | image/WIP | ✅ | ✅ | ➖ | |
| imageTo3D | mlx-trellis2-swift | TRELLIS.2 / Pixal3D | wrapper+core | mlxengine-3d/WIP | ✅ (0.3.0) | 🟡 | ⬜ | 1.12 |

> BiRefNet `Eff: ✅ P1a` (2026-06-30, engine 0.14.0) — the motivating same-quant multi-mode case (fast@1024 vs best@2048). Split declared on the **fast** envelope: `QuantFootprint(.fp16, resident 0.9 GB, peakActivation 4.4 GB)` (+ `QuantConfigured`), replacing the flat 6.5 GB → engine charge ~0.9 GB resident + a shared transient. best stays a runtime-guarded variant (`insufficientMemoryForBest`; measured split resident ~0.5 / peakActivation ~17.9 GB, documented not admitted). **P1b deferred** — promoting mode → PackageID (best first-class admitted) is a coordinated change; the PROD consumer (`EngineMatteProvider`) relies on per-request `req.mode` + the fallback.

> Qwen-Image-Edit-2511 `Eff: ✅` (2026-06-30, engine 0.15.0) — the heaviest image package, three wrappers (`MLXQwenImageEdit` base · `MLXQwenImageEditTurbo` bf16/int4 · `MLXTeleStyle`) over one shared core (`QwenImageEditGenerator`). **P2 (headline) = per-stage encoder eviction:** the ~16.6 GB Qwen2.5-VL encoder, used once per request then idle through denoise+decode, is no longer held resident — the core generator owns an async `encoderProvider`, loads it, encodes, `eval`s the embeddings, then drops the ref + `Memory.clearCache()` before the DiT denoise peak (Swift 6: the now-async `generate`/`loadEncoder` take `isolated (any Actor)? = #isolation` to stay on each wrapper's `@InferenceActor`; back-compat `keepEncoderResident` init for parity tests). All three wrappers inherit it; the DiT (with its resident LoRA swapper) + small fp32 VAE stay resident. **Split (measured M5 Max, 1024²/8-step CFG4, `QIE_MEMBENCH` in MLXQwenImageEditTests):** bf16 resident floor (DiT 40.9 GB + fp32 VAE 0.5 GB) **41.4 GB**, worst peak **59.2 GB** → activation (peak−floor, the transient encoder load) **17.9 GB → 21 GB** declared (+20%). base/TeleStyle `QuantFootprint(.bf16, resident 42 GB, peakActivation 21 GB)` replaces the flat 60 GB; Turbo adds `(.int4, resident 12 GB, peakActivation 17 GB)`. All three configs now conform to `QuantConfigured` (Turbo's `quant` is computed bf16/int4). P3 (mmap): verified — the measured floor equals on-disk DiT+VAE bytes exactly, so the per-key `asType` rebuild does NOT eager-copy. P4 (BudgetAware): deferred (quant is config-chosen). **FLAG:** the int4 split is DERIVED from the documented component measurements (pre-split resident 22 GB included the co-resident encoder); the bf16 split is freshly measured — re-measure int4 via `QIE_MEMBENCH` with `quantizedDiTPath`+`quantizedEncoderPath` once the image category app is stood up for app-autorun.

> Optimizer image trio `Eff: ✅` (2026-06-30, engine 0.15.0) — NAFNet (`imageRestore`) · Real-ESRGAN (`imageUpscale`) · DDColor (`imageColorize`), the ForgeOptimizer chain alongside BiRefNet matting. All three are single-component (P2/P3 n/a) and activation-dominated, so the win is the **split + the shared transient reserve**: each now declares a small resident weights floor + its activation peak (measured via each package's own smoke target through `MLXServeEngine` at the documented envelope), and all conform to `QuantConfigured`. Floors/activation: NAFNet signage **64 MB / 2.0 GB** (fp16) + width64 **512 MB / 2.9 GB** (fp32) @1024² · Real-ESRGAN **32 MB / 2.2 GB** (fp32, tile-bounded — 1024² peaked below 512²) · DDColor **512 MB / 1.8 GB** (fp16, best). Finding: the old flat NAFNet-fp16 0.6 GB and Real-ESRGAN 1.0 GB **under-declared** the real activation peak; the split right-sizes the charge AND frees it into the single shared reserve, so the trio + BiRefNet co-reside on ~1.1 GB of weights (64+32+512+~900 MB) sharing ONE ~4.4 GB transient (BiRefNet fast is the max) instead of each baking activation into residency. BudgetAware deferred on all three (validated runtime dtypes, no in-variant quality/memory lever).

## 🎬 Video

| Capability | Package | Model | Role | Home | Avail | Val | Eff | Eng |
|---|---|---|---|---|---|---|---|---|
| textToVideo | **ltx-2-mlx-swift** | Lightricks LTX-2.3 | wrapper+core | video/LTX_DEV (research) | 🔬 | ✅ | ✅ | 0.14.0 |
| textToVideo | helios-mlx-swift | Helios (Wan) | wrapper+core | video/WAN_DEV (research) | 🔬 | 🟡 | ⬜ | |
| textToVideo | ti2v-5b-mlx-swift | Wan TI2V-5B | wrapper+core | video/WAN_DEV (research) | 🔬 | 🟡 | ⬜ | |
| textToVideo | phantom-wan-mlx-swift | Phantom-Wan | wrapper+core | video/WAN_DEV (research) | 🔬 | ⬜ | ⬜ | |
| videoEdit | bernini-r-mlx-swift | Bernini-R | wrapper+core | video/WAN_DEV (research) | 🔬 | 🟡 | ⬜ | |
| videoEdit | vace-mlx-swift | VACE (Wan) | wrapper+core | video/WAN_DEV (research) | 🔬 | 🟡 | ⬜ | |
| videoEdit | chronoedit-mlx-swift | ChronoEdit | wrapper+core | video/WAN_DEV (research) | 🧪 | ⬜ | ⬜ | |
| characterAnimation | scail-2-mlx-swift | SCAIL-2 | wrapper+core | video/WAN_DEV (research) | 🔬 | 🟡 | ⬜ | |
| talkingHead | musetalk-mlx-swift | MuseTalk 1.5 | wrapper+core | video/PROD | ✅ | ✅ | ⬜ | |
| videoUpscale | mlx-seedvr2-swift | SeedVR2-3B | wrapper | video/WIP | ✅ | ✅ | ⬜ | |
| frameInterpolate | mlx-rife-swift | RIFE 4.25 | wrapper | video/WIP | ✅ | ✅ | ➖ | |
| contentClassify | mlx-vjepa2-swift | V-JEPA2 ViT-L | wrapper | video/PROD | ✅ | ✅ | ➖ | |

> Wan family `Eff: ⬜` deferred behind a dedicated deep-dive (more complex). **LTX is the sweep's first target + process-validation.**

## 🧠 Language & Vision-Language

| Capability | Package | Model | Role | Home | Avail | Val | Eff | Eng |
|---|---|---|---|---|---|---|---|---|
| llm | mlx-qwen-llm-swift | Qwen3.5 | wrapper | think/PROD | ✅ | ✅ | ✅ | 0.15.0 |
| llm (prompt enhance) | ernie-pe-swift | ERNIE-PE (Ministral-3B) | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| imageAnalysis | qwen25vl-mlx-swift | Qwen2.5-VL-3B | wrapper+core | think/PROD | ✅ | ✅ | ✅ | 0.15.0 |
| imageAnalysis | qwen3vl-mlx-swift | Qwen3-VL | core (wrapper pending) | think/WIP | 🧪 | ⬜ | ⬜ | |

> mlx-qwen-llm-swift `Eff: ✅` (2026-06-30, engine 0.15.0) — first **autoregressive** sweep target: the transient is the **context-scaled** activation, not a fixed peak. P1 split: flat `residentBytes = onDisk + 600 MB` (KV-cache-blind) → `FootprintConfigured` split `residentBytesHint = onDiskBytes` (weights floor) + `peakActivationBytesHint = peakActivationBytes` declared at a **documented 2048-token context envelope**. **Measurement surprise (the interesting bit):** Qwen3.5 is a HYBRID linear/full-attention model — only 1-in-4 layers is softmax attention with a context-growing `KVCacheSimple`; the rest are GatedDeltaNet (linear) with a fixed `MambaCache`. So the analytic KV-cache (`QwenModel.kvCacheBytes`, verified **bit-exact** at 12 288 B/token for 0.8B) is TINY (96 MB @8192). But the measured transient is **prefill-scratch-dominated** (the GatedDeltaNet chunked-scan over the prompt), ~20× the KV-cache and ~linear in sequence length: 0.8B-8bit measured 427 MB @~340 tok · 2.1 GB @~2k · 4.2 GB @~4k · 7.0 GB @~8k. Declared peak is the **measured** prefill-scratch at the 2048 envelope (~2.2 GB for 0.8B), width-scaled by `hidden_size` for 4B/9B (only 0.8B measured). Classic "flat footprints UNDER-declare." P2 (per-stage evict) N/A (single model). P3 (mmap) verified — floor ≈ on-disk weight bytes (loads via mlx-swift-lm safetensors). P4 (BudgetAware) the LLM-specific lever = cap context to fit KV-cache into budget; **documented + deferred** (KV-cache is small; silently shrinking context is a correctness surprise). Engine pin `from: 0.3.0 → 0.15.0`, no API drift.

> qwen25vl-mlx-swift `Eff: ✅` (2026-06-30, engine 0.15.0) — the **VLM** sweep target, which combines two levers: a vision tower + an autoregressive LM. **P2 (vision-tower evict):** the ViT encodes the image once then is idle through the LM decode loop, so the core pipeline now holds `vision` as a rebuildable `private(set) var` — `load()` captures a `visionBuilder` closure over the (mmap-backed) ViT weights; `generate()` runs `ensureVision()` → encode → `eval(imageFeatures)` → `evictVision()` (`vision = nil` + `Memory.clearCache()`) before the LM prefill+decode, rebuilding lazily on the next call. Stays synchronous (the builder closure isn't async), so no `#isolation` hop was needed. Modest (the 3B LM ≫ the ViT) but real. **P1 split (MEASURED via gated `MemoryReportTests`, M5 Max, envelope: image 800×557 ≈0.45 MP → ~580 vision tokens × maxTokens 256, post-evict):** bf16 resident floor **7.51 GB**, worst peak **9.98 GB** → transient **2.47 GB**; int4 floor **3.07 GB**, peak **4.04 GB** → transient **0.97 GB**. Declared `QuantFootprint(.bf16, resident 7.7 GB, peakActivation 3.0 GB)` and `(.int4, resident 3.2 GB, peakActivation 1.2 GB)` (+`QuantConfigured`; single size so no `FootprintConfigured`), replacing the **flat** 9.6 / 4.5 GB — the old flat number was the *peak*, baking the activation into residency. Per the Qwen-LLM lesson the transient is **measured per quant** (it does NOT width-scale across quants: int4's 0.97 GB ≠ a scale of bf16's 2.47 GB, since the quantized LM's prefill scratch is smaller); it's the image-token-inflated LM prefill/KV-cache scratch and scales with the (image-res × maxTokens) envelope. P3 (mmap): loads via `MLX.loadArrays` (lazy safetensors) — note only. P4 (BudgetAware) deferred (quant is config-chosen). Engine pin `from: 0.3.0 → 0.15.0`, no API drift (the `imageAnalysis` surface + `ModelPackage` are unchanged). Smoke (`OracleSmokeTests`, chart-read "29") still green after the evict refactor.

## 🧱 Shared foundation (not capability providers)

| Package | Provides | Role | Home | Avail |
|---|---|---|---|---|
| mlx-engine-swift | the engine (MLXToolKit/MLXServeCore/UI/retrieval) + **MLXEngineTestKit** (opt-in category testing harness) | engine | MLXEngine/ | ✅ (0.15.0, contract 1.14.0) |
| mlx-swift-lm | LLM/VLM building blocks | shared | video/LTX_DEV | ✅ |
| flux2-vae-mlx-swift | FLUX.2 VAE decoder | shared | image/PROD | ✅ |
| wan-core-mlx-swift | shared Wan-family video core | shared | video/WAN_DEV | 🔬 |

---

## Efficiency sweep status (the 1.14 program)

The **Eff** column above IS the sweep tracker (one source of truth — don't duplicate it elsewhere).
Order: **LTX first** → most-consumed (image caps, Qwen LLM/TTS) → optimizer family (BiRefNet/upscale/
NAFNet/SigLIP2) → Wan last (dedicated deep-dive). Per-package work orders are the
`EFFICIENCY-ADOPTION.md` briefs in each package repo (template: `ltx-2-mlx-swift/EFFICIENCY-ADOPTION.md`).
Plan + rationale: `EngineeringDocs/MLXEngineDocs/ENGINE-ROADMAP.md` → "Library efficiency program".

## Cross-references
- Capability schemas: `Sources/MLXToolKit/Capability.swift` + `capability-contract.md`.
- App-side consumption of these models: the `mlxengine-implementation` skill.
- Bringing a new model in (and adding its row here): the `mlx-swift-integration` skill.
