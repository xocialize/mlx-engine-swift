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
| tts | mlx-kokoro-tts-swift | Kokoro-82M | wrapper+core | audio/PROD | ✅ | ✅ | ⬜ | |
| tts | mlx-qwen3-tts-swift | Qwen3-TTS | wrapper+core | audio/PROD | ✅ | ✅ | ⬜ | |
| tts | mlx-voxcpm2-tts-swift | VoxCPM2 | wrapper+core | audio/PROD | ✅ | ✅ | ⬜ | |
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
| imageEdit | qwen-image-edit-swift | Qwen-Image-Edit-2511 | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| imageColorize | mlx-ddcolor-swift | DDColor | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| imageRestore | mlx-nafnet-swift | NAFNet (v0.3.2) | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| imageUpscale | mlx-realesrgan-swift | Real-ESRGAN 4× | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| imageInpaint | mlx-lama-swift | LaMa + MI-GAN | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| matting | mlx-birefnet-swift | BiRefNet | wrapper+core | image/PROD | ✅ | ✅ | ✅ P1a (P1b deferred) | 0.14.0 |
| promptSegment / trackObject | mlx-edgetam-swift | EdgeTAM (SAM 2) | wrapper+core | image/PROD | ✅ (v0.3.2) | ✅ | ⬜ | |
| imageQualityScore | mlx-siglip2-iqa-swift | SigLIP2 NR-IQA | wrapper+core | image/WIP | ✅ | ✅ | ➖ | |
| opticalFlow | mlx-sea-raft-swift | SEA-RAFT | wrapper+core | image/WIP | ✅ | ✅ | ➖ | |
| imageTo3D | mlx-trellis2-swift | TRELLIS.2 / Pixal3D | wrapper+core | mlxengine-3d/WIP | ✅ (0.3.0) | 🟡 | ⬜ | 1.12 |

> BiRefNet `Eff: ✅ P1a` (2026-06-30, engine 0.14.0) — the motivating same-quant multi-mode case (fast@1024 vs best@2048). Split declared on the **fast** envelope: `QuantFootprint(.fp16, resident 0.9 GB, peakActivation 4.4 GB)` (+ `QuantConfigured`), replacing the flat 6.5 GB → engine charge ~0.9 GB resident + a shared transient. best stays a runtime-guarded variant (`insufficientMemoryForBest`; measured split resident ~0.5 / peakActivation ~17.9 GB, documented not admitted). **P1b deferred** — promoting mode → PackageID (best first-class admitted) is a coordinated change; the PROD consumer (`EngineMatteProvider`) relies on per-request `req.mode` + the fallback.

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
| llm | mlx-qwen-llm-swift | Qwen3.5 | wrapper | think/PROD | ✅ | ✅ | ⬜ | |
| llm (prompt enhance) | ernie-pe-swift | ERNIE-PE (Ministral-3B) | wrapper+core | image/PROD | ✅ | ✅ | ⬜ | |
| imageAnalysis | qwen25vl-mlx-swift | Qwen2.5-VL-3B | wrapper+core | think/PROD | ✅ | ✅ | ⬜ | |
| imageAnalysis | qwen3vl-mlx-swift | Qwen3-VL | core (wrapper pending) | think/WIP | 🧪 | ⬜ | ⬜ | |

## 🧱 Shared foundation (not capability providers)

| Package | Provides | Role | Home | Avail |
|---|---|---|---|---|
| mlx-engine-swift | the engine (MLXToolKit/MLXServeCore/UI/retrieval) | engine | MLXEngine/ | ✅ (0.14.0, contract 1.14.0) |
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
