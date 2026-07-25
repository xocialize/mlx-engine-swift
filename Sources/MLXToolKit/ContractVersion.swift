// MLXToolKit — the MLXEngine contract surface.
//
// MLXEngine is a runtime *coordinator*, not an inference engine. Packages do inference;
// the engine instantiates, holds, drives, and evicts them (inversion of control). These
// types are the contract a package conforms to so the engine can own its lifecycle and
// expose it uniformly. Build via Xcode / xcodebuild (macOS 26.2+).

/// A simple semantic version.
public struct SemanticVersion: Sendable, Codable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The conformance-contract version this build of MLXToolKit defines.
///
/// Every conformant package declares the contract version it targets (C0). The contract is
/// additive at minor versions; breaking changes bump the major and carry a deprecation window.
public enum ContractVersion {
    // 1.1.0 (2026-06-10, additive): TTSRequest.referenceTranscript (ICL cloning transcript,
    // promoted from metaData when the second package needed it) + Quant.int5/.int6
    // (mlx-community ships 5/6-bit conversions broadly).
    // 1.2.0 (2026-06-12, additive): two capabilities landed together —
    //   • `imageEdit` (+ IEditRequest/IEditResponse/IEditContract) — instruction-driven editing,
    //     multi-image-first (introduced by Qwen-Image-Edit-2511; planned since the Lance scoping).
    //   • `soundEffect` (+ SoundEffectRequest/Response/Contract) — text → SFX audio (MOSS-SoundEffect).
    // 1.3.0 (2026-06-13, additive): video editing + reference-conditioned generation —
    //   • `videoEdit` (+ VEditRequest/VEditResponse/VEditContract) — source video (+ optional
    //     reference images) + prompt → edited video (introduced by Bernini-R's v2v/rv2v).
    //   • `T2VRequest.referenceImages` — subject-consistent reference-to-video generation (r2v),
    //     promoted to a canonical field (mirrors `initImage` for i2v).
    // 1.4.0 (2026-06-14, additive): audio-driven lip-sync —
    //   • `talkingHead` (+ TalkingHeadRequest/Response/Contract) — source face video + driving
    //     audio → re-lip-synced video (introduced by MuseTalk).
    // 1.5.0 (2026-06-18, additive): foreground matte extraction —
    //   • `matting` (+ MattingRequest/Response/Contract) — image → single-channel `Matte`
    //     (binary segmentation or soft alpha, per `preferredKind`); introduced by BiRefNet.
    //   • `CanonicalOutput.matte` + the `Matte` artifact — a first-class, reusable matte signal
    //     (consumed as a weight map by region-aware restore/upscale + flow-guided propagation).
    // 1.6.0 (2026-06-22, additive): character animation / motion transfer —
    //   • `characterAnimation` (+ CharacterAnimationRequest/Response/Contract) — reference character
    //     `Image` + driving `Video` → video of that character performing the driving performance
    //     (introduced by SCAIL-2; the lane shared by Wan2.2-Animate). Canonical output `Video`.
    //   • `Mode.animation`/`.replacement` — animate-the-reference vs swap-into-the-driving-clip,
    //     a per-request tag (same input artifacts, different output semantics; SCAIL's `replaceFlag`).
    //   • `Specialty.poseless`/`.poseDriven` — distinguishes SCAIL (no skeleton dependency) from
    //     Wan2.2-Animate (explicit pose/face conditioning) for Model-Manager ranking.
    //     The request is LANE-READY: `drivingMask`/`prompt` are optional now so Wan2.2-Animate
    //     plugs into the same capability with no further contract bump.
    // 1.7.0 (2026-06-23, additive): automatic colorization —
    //   • `imageColorize` (+ ColorizeRequest/Response/Contract) — grayscale/desaturated `Image` →
    //     colorized `Image` at the same dimensions (introduced by DDColor). Canonical output `Image`.
    //   • `ColorizeContract.fast`/`.best`/`.artistic` — quality/style tier Modes (DDColor convnext-t
    //     vs convnext-l vs the artistic checkpoint); same input artifact, so a Mode tag (C4), not a surface.
    // 1.8.0 (2026-06-24, additive): object removal / inpainting —
    //   • `imageInpaint` (+ InpaintRequest/Response/Contract) — Image + mask (white=remove) → filled
    //     Image at the same dimensions (introduced by LaMa, + MI-GAN fast tier). Canonical output Image.
    //   • The first **two-input** surface (image AND mask). `InpaintContract.best`(LaMa)/`.fast`(MI-GAN).
    // 1.9.0 (2026-06-24, additive): raw-pixel image boundary —
    //   • `Image.Format.rawBGRA8` (+ `Image.bytesPerRow`, `Image.rawBGRA8(...)`) — raw interleaved
    //     BGRA8 pixel bytes in `data`, skipping the per-tile PNG encode/decode + 8-bit clamp at the
    //     model boundary for in-process consumers (ForgeOptimizer EngineImageEnhancer, BRIDGE-024).
    //   • Still serialized round-trip form (V1 rule holds, no contract fork); `width`/`height` required,
    //     `bytesPerRow` optional (defaults to width*4). png/jpeg call sites untouched (param defaulted).
    //     First adopters: NAFNet (imageRestore) + Real-ESRGAN (imageUpscale); other image capabilities
    //     opt in by branching their Image→pixel-buffer codec. A later `.rawRGBA16Half` is the 16-bit step.
    // 1.10.0 (2026-06-25, additive): promptable segmentation —
    //   • `promptSegment` (+ PromptSegmentRequest/Response/Contract) — Image + point/box prompts →
    //     `Matte` of the prompted object (introduced by EdgeTAM, on-device SAM 2). Reuses the `.matte`
    //     output (shared with `matting`); the interactive click/box-select lane for Extract + Erase.
    // 1.11.0 (2026-06-25, additive): promptable video object tracking —
    //   • `trackObject` (+ TrackObjectRequest/Response/Contract) — `Video` + point/box prompts on one
    //     frame → a per-frame `Matte` track of the object across the clip (masklet propagation); the
    //     temporal extension of `promptSegment` (introduced by EdgeTAM's video memory stack). V1 single
    //     object; the request is lane-ready for multi-object (additive) without a further bump.
    //   • `CanonicalOutput.matteSequence` — a time-ordered sequence of mattes (lossless per-frame, not a
    //     re-encoded mask video — hard edges survive); distinct from `.video` so consumers don't treat a
    //     mask track as a single playable clip. The request carries the whole `Video` (bytes); the
    //     runtime package decodes to frames (`FrameStreamNative`) — same convention as videoUpscale.
    // 1.12.0 (2026-06-26, additive): single-image to 3D —
    //   • `imageTo3D` (+ ImageTo3DRequest/Response/Contract) — one `Image` -> a 3D triangle mesh
    //     (introduced by Pixal3D / TRELLIS.2). Resolution tier (voxel grid 512/1024/1536) rides
    //     `mode` (`ImageTo3DContract.res512`/`.res1024`/`.res1536`); same input artifact, so a Mode
    //     tag (C4), not a surface. Input bg-removal reuses the shipped BiRefNet `matting` internally.
    //   • `CanonicalOutput.mesh` + the `Mesh` artifact (GLB bytes; geometry + vertex color in V1) —
    //     the first non-2D artifact kind (all others image/video/audio/text/matte). A later
    //     PBR-texture bake stays the same `.glb` artifact (no fork).
    // 1.13.0 (2026-06-27, additive): config-aware memory footprint —
    //   • `FootprintConfigured` (opt-in protocol; `var residentBytesHint: UInt64?`) — lets a config
    //     declare the *selected* variant's resident bytes when two modes share a quant so the
    //     `QuantFootprint` (keyed on quant) can't distinguish them (BiRefNet `fast`@1024 ≈ 4.9 GB vs
    //     `best`@2048 ≈ 18.3 GB, both fp16). The engine charges the hint over the quant match over the
    //     largest-that-fits survey; nil is safe. Detected by `as?` at registration like `QuantConfigured`.
    //     The hint is the max-over-phase working set (not the sum) — the manifest principle. Pairs with
    //     the R-MEM-1 real-pressure admission trigger (MLXServeCore) closing the declared-bytes-only gap.
    // 1.14.0 (2026-06-30, additive): persistent/transient footprint split + budget-aware load —
    //   • `QuantFootprint.peakActivationBytes` (default 0) — the transient activation scratch live only
    //     during inference, on top of the persistent `residentBytes` weights. Because inference is
    //     serialized (`@InferenceActor`), the engine reserves ONE max transient across residents instead
    //     of summing per model → more safe co-residency (ComfyUI's minimum_inference_memory idea, made
    //     exact for our serialized execution). Declare it as max-over-phase activation.
    //   • `FootprintConfigured.peakActivationBytesHint` (default nil via extension) — per-mode transient
    //     for same-quant multi-mode configs (BiRefNet best@2048 ≫ fast@1024 activation, both fp16).
    //   • `BudgetAware` (opt-in; `var availableBudgetBytes: UInt64?`) — the engine stamps the headroom a
    //     model is loading into (after admission/eviction) so `load()` can pick a memory-adaptive dtype.
    //   All additive + safe-defaulted: undeclared transient = 0 (reactive R-MEM-1 still covers overflow),
    //   so existing manifests behave exactly as before. `MemorySnapshot.transientReserveBytes` exposes the
    //   reserve. Enables the per-package efficiency sweep (mmap lazy load, per-stage eviction, adaptive dtype).
    // 1.15.0 (2026-07-04, additive): text embedding —
    //   • `embed` (+ EmbedRequest/Response/Contract) — batch of texts → one dense vector per text for
    //     semantic retrieval (introduced by Qwen3-Embedding-0.6B; unblocks MLXCompanion semantic memory,
    //     ENGINE-NEEDS N4). Rich shape: `texts` batch-first (order-preserving), `inputType`
    //     query/document for asymmetric retrieval (query-side texts get the model's instruction prefix,
    //     stored document-side texts don't), optional `instruction` task override, optional Matryoshka
    //     `dimensions` truncation (applied BEFORE L2-normalization; nil = native).
    //   • Vectors ride the response directly (`EmbedResponse.vectors: [[Float]]`) — the
    //     `imageQualityScore` non-Artifact precedent; no `CanonicalOutput.vector` artifact kind (no
    //     consumer needs the vector as a routed artifact — it feeds an index, not a media pipeline;
    //     canonical output maps to `.structuredText` like the other non-Artifact responses).
    //   • `EmbedResponse.dimension`/`normalized`/`modelID` — index-safety provenance: an index must
    //     never mix models or dimensions, so every batch is stamped with what produced it.
    // 1.16.0 (2026-07-05, additive): structured output on the `llm` surface (ENGINE-NEEDS N6) —
    //   • `LLMRequest.responseFormat: ResponseFormat?` — opt-in constrained decoding. A
    //     request-level knob, NOT a new capability (canonical output stays text); `nil` =
    //     freeform, all existing consumers unchanged. Introduced by three MLXCompanion call
    //     sites (parseFacts → JSON array, parseAffect → JSON object, decideSearchQuery) that
    //     regex-scraped free text and silently dropped passes when 0.8–4B models broke format.
    //   • `ResponseFormat.json(container: .any/.object/.array)` — grammar-constrained
    //     syntactically-valid JSON, exactly one top-level value then stop; the container hint
    //     is enforced from the first token. `.jsonSchema(String)` lands lane-ready: V1 packages
    //     satisfy it best-effort (`.json` syntax + container inferred from the schema root),
    //     full schema-DFA enforcement is a package-side upgrade needing no further bump.
    //   • Honest advertisement (C11): `LLMContract.descriptor(supportsStructuredOutput:)`
    //     includes a `responseFormat` ParameterSchema only when the package really constrains.
    //   • `PackageError.unsupportedRequestFeature(String)` — the legible rejection for a
    //     canonical request field a package can't honor; silent-ignore is a contract violation.
    //     Runtime home for the decoder: mlx-constrained-decoding-swift (shared by the llm
    //     packages; the contract stays MLX-free).
    // 1.17.0 (2026-07-09, additive): bundled-weights materialization vocabulary —
    //   • `BundledWeightSource` + `BundledWeightSourcing` — a configuration whose checkpoints are
    //     vendored in the binary's resource bundle declares role→bundle-URL sources; the MAT gate
    //     verifies them PRESENT on a fresh machine (the inverse of `WeightSourcing`'s
    //     required-missing network set). Closes the gap where bundled packages (first case:
    //     Real-ESRGAN's ~2 MB SRVGGNetCompact checkpoints) could honestly pass only MAT-1 —
    //     declaring a network source would either fail MAT-4 or force a pointless download.
    //   • One role namespace across both vocabularies (MAT-3); hybrid packages conform to both
    //     and get each subset checked by its own rule (MAT-4 "fresh-machine posture").
    //   • `MLXServeEngine.needsDownload` reads `false` for a bundled-only configuration whose
    //     sources all resolve — the sanctioned signal, replacing the always-present-prewarmPaths
    //     workaround (`WeightPrewarming` keeps its real job: cold-start page-in before load()).
    // 1.18.0 (2026-07-09, additive): run-phase progress plane (run-lifecycle program V2) —
    //   • `RunPhase` + `RunPhaseReport` + `RunProgress` — an ambient task-local sink mirroring
    //     `WeightDownloadProgress`, for COARSE run-time phases (encode → denoise → upsample →
    //     decode, optional 1-based step/totalSteps + stage/totalStages). No-op unbound; the
    //     engine binds it around `run()` per request (task-local ⇒ no cross-run talk). Born from
    //     the LTX M3 cancel-acceptance pass: a decode-chunk cancel was indistinguishable from a
    //     denoise-step cancel, and 16–21 s compile-heavy worst-case cancels read as hangs.
    //   • `RunPhase` is governed like `Mode`/`Specialty`: open String raw value + canonical
    //     constants (`.encode`/`.denoise`/`.upsample`/`.decode`/`.generate`/`.postprocess`);
    //     consumers tolerate unknown phases. NOT token streaming (companion N2) and NOT a new
    //     response shape. `RunPhaseReport` is a struct so later fields ride in additively.
    //   • `RunMonitor` — the observable engine-owned record (sibling of `PreparationMonitor`,
    //     same capability/package key scheme); `MLXServeEngine.runProgress` exposes it; entries
    //     clear when the run exits (success, failure, or cancellation). First reporter: LTX-2.3;
    //     Wan/Bernini, SeedVR2, IndexTTS2 follow. V3 preemption policy will read this signal
    //     when weighing mid-run eviction victims.
    // 1.19.0 (2026-07-10, additive): mesh auto-rigging —
    //   • `meshRig` (+ MeshRigRequest/Response/Contract) — a 3D triangle `Mesh` (GLB) → the SAME
    //     geometry with a skeleton + skin weights (JOINTS_0/WEIGHTS_0) injected (introduced by
    //     SkinTokens). The first surface whose INPUT and OUTPUT are both `Mesh` (`imageTo3D` only
    //     outputs one). Reuses `CanonicalOutput.mesh` (no new artifact kind).
    //   • `MeshRigContract.auto`/`.skinOnly` — generate-skeleton-and-skin vs skin-a-provided-skeleton
    //     (J-in==J-out, the companion-character VRM path). Same input artifact → a Mode tag (C4).
    //   • `MeshRigRequest.skeleton: Mesh?` — optional explicit skeleton source for `skinOnly` (the
    //     `imageInpaint` two-input precedent); nil = use the mesh's own embedded skeleton (a VRM).
    //   • `ParameterSchema.Kind.mesh` — first mesh-typed INPUT parameter. `meshRig` joins
    //     `longRunCapabilities` (grammar-constrained beam decode is a per-token-checkpoint long run).
    //   (Landed second — filled the 1.19.0 slot the stt branch reserved; stt took 1.20.0.)
    // 1.20.0 (2026-07-10, additive): speech-to-text —
    //   • `stt` (+ STTRequest/STTSegment/STTResponse/STTContract) — one complete spoken utterance
    //     (canonical `Audio`, any rate/channels) + optional BCP-47 `language` hint (nil =
    //     auto-detect) → transcript with native punctuation/capitalization, timestamped
    //     `segments`, and `detectedLanguage`. Canonical output `.text` (the transcript is the
    //     deliverable; segments/locale are response fields, per the embed/imageQualityScore
    //     non-Artifact precedent). Introduced by Nemotron 3.5 ASR streaming (cache-aware
    //     FastConformer-RNNT, 40 locales; unblocks MLXCompanion voice input).
    //   • Utterance-shaped and ONE-SHOT by design: live partial hypotheses remain the deferred
    //     token-streaming contract (companion N2) — the same boundary RunPhase drew in 1.18.0.
    //     The model's internal chunked cache-aware streaming is package-internal memory
    //     discipline (per-chunk RunPhase reports + cancellation checkpoints), not a request
    //     surface.
    //   • `SPDXLicense.openMDW1_1` ("OpenMDW-1.1", LF Open Model/Data/Weights v1.1) added to the
    //     permissive allowlist (C7) — reviewed maximally permissive (no field-of-use/revenue
    //     restriction, no output obligations; attribution + defensive-termination only).
    // 1.21.0 (2026-07-14, additive): multi-view conditioning on the `imageTo3D` surface —
    //   • `ImageTo3DRequest.additionalViews: [Image]?` — optional additional views of the SAME
    //     subject (e.g. a front/¾/side/back turnaround). A package that supports multi-view
    //     concatenates the views' image-conditioner features (resolving back/side ambiguity and
    //     reducing single-view artifacts); a package that doesn't ignores them and uses `image`.
    //     Same canonical output (`.mesh`), same Mode tiers — a request-level field, NOT a new
    //     surface. `nil`/empty = single-view, so every existing consumer is unchanged. Introduced
    //     by the TRELLIS.2 turnaround front door (klein + BiRefNet → 3 matted T-pose views).
    // 1.22.0 (2026-07-22, additive): canonical model-store layout (MS-1) —
    //   • `ModelStore` adopts the **HF cache convention**: `directory(for:)` now computes
    //     `<root>/models--<org>--<name>/` (was `<root>/<org>/<name>/`), which is where every
    //     package's hub client actually materializes weights. The `mlx-package.json` marker is
    //     written at the top of that repo dir (sibling of `refs/`), so the marker, the weights,
    //     and `MLXServeEngine.needsDownload` finally agree on one directory.
    //   • New: `ModelStore.repoFolderName(for:)`, `snapshotDirectory(for:revision:)` (resolves
    //     `refs/<rev>` → `snapshots/<commit>/`, nil when nothing is materialized — the probe seam
    //     MS-2 builds on), `markerURL(for:)` / `hasMarker(for:)`, and `legacyDirectory(for:)`.
    //   • Legacy tolerance: marker READS fall back to the pre-MS-1 `<root>/<org>/<name>/` path for
    //     one release (read-both, write-new). No data migration — markers regenerate on load().
    //     REMOVE `legacyDirectory(for:)` + its fallback at the next minor.
    //   • MS-2: `WeightSourcing.missingWeightSources(storeRoot:)` gains a DEFAULT implementation
    //     (+ `defaultMissingWeightSources(storeRoot:)` to delegate to from an override, and the
    //     `WeightSourceProbe` glob matcher). Packages stop hand-rolling the on-disk probe; a
    //     half-materialized snapshot (a declared glob matching nothing) reads as MISSING rather
    //     than silently degrading. Overriding is still supported — and still required for a
    //     configuration with an explicit local-path escape hatch, which must be honored first.
    //   • MS-4: disk governance to match memory governance — `ModelStore.remove(repo:)` (repo dir
    //     + its `.locks` entries) and `ModelStore.usage(at:)` (`Usage` = deduped bytes + marker
    //     count; an HF snapshot links into `blobs/`, so identity-dedup is what stops a 2×
    //     over-report). The residency guard is engine-side: `MLXServeEngine.deleteWeights(repo:)`
    //     → `EngineError.weightsInUse(repo:packageID:)`.
    //   • MS-3 (NOT in MLXToolKit — recorded here for the program's history): materialization
    //     preview + disk precheck ship in a NEW target `MLXHubMetadata` (Foundation + URLSession,
    //     metadata only, behind `HubMetadataProviding`) so MLXToolKit stays network-free and the
    //     "the engine downloads no weights" stance holds. `MLXServeEngine.materializationPreview`
    //     + `EngineError.insufficientDisk` + `diskPrecheckEnabled` are engine-side.
    //   • MS-5 (docs/comments only): the never-built `HubAssetSource` SHA256-verification claims
    //     are retired across both doc trees. Weight integrity is the hub client's responsibility
    //     (xet chunk hashes / ETag verification in swift-huggingface); the engine verifies
    //     presence, not content. We do not build a parallel hasher.
    // 1.23.0 (2026-07-22, additive): contract hardening (Phase 4 of the 2026-07 execution plan) —
    //   • 3.5 **Specialty vocabulary governance (C6).** `Specialty.registeredVocabulary` (+
    //     `isRegistered`) mirrors `SPDXLicense.permissiveAllowlist`: a core-owned, additive set of
    //     every term the fleet declares, so the namespace can't quietly fork ("line-art" vs
    //     "lineart"). Seeded from the fleet sweep — the tts/animation/3D terms plus `anime`
    //     (promoted from a package-side extension) and the grandfathered kebab-case 3D terms
    //     (`3d-generation`, `mesh-rigging`, `character-rigging` — their raw values already ship in
    //     manifests; new terms use camelCase). **Enforcement is warn-only** at
    //     `MLXServeEngine.register()` (logs + records `engine.unregisteredSpecialties`); hard
    //     rejection would break unknown third-party conformers with no deprecation window, so it
    //     is a next-major decision.
    //   • 3.2 **Per-surface quant eligibility.** `ToolDescriptor.quantFloor: Quant?` (nil = no
    //     constraint = every existing conformer) — a model can be int4-fine for analysis and
    //     int4-bad for generation, and quant gating was per-PACKAGE. Engine consumption: a surface
    //     whose floor outranks the configuration's `QuantConfigured` quant stops backing THAT
    //     capability while the package's other surfaces still do, and
    //     `admissibility(for:configuration:capability:)` reports the new
    //     `DeviceEligibility.quantBelowSurfaceFloor(capability:required:selected:)`. Comparison
    //     rides `Quant.precisionRank` / `meets(floor:)` — deliberately not `Comparable`, since
    //     fp16 and bf16 share a rank (and mxfp4 ranks with int4).
    // MS-6 (2026-07-23, engine-side behavior — no contract type change, recorded here for the
    // MS program's history): variant-aware install markers. `MLXServeEngine` now stamps one
    // `mlx-package.json` per declared `WeightSource` repo after load() (provenance.sourceRepo only
    // for configurations that declare no sources; a source's pinned revision rides its marker,
    // nil pin → "main"), and `needsDownload` probes the declared sources via the MS-2 missing-set
    // instead of the provenance marker. Closes the variant-multiplexing gap (Mage turbo/base/edit,
    // Klein base tier): the marker used to land under the STATIC family-primary repo while the
    // weights materialized under the variant's repos, so storage-panel counts credited the wrong
    // row and MaterializationBench read a false marker=NO. TestKit's bench now verifies markers
    // against the configuration's declared sources (caller-passed sourceRepo = fallback only).
    // Stale family-primary markers are harmless residue, deletable via the storage panel.
    // 1.24.0 (2026-07-23, additive): ENGINE-EXECUTED materialization — the executor moves
    //   engine-side; `load()` just loads.
    //   • `MLXServeEngine.resident()` now downloads a `WeightSourcing` configuration's missing
    //     sources into the store BEFORE constructing the package (`WeightMaterializer` in
    //     MLXServeCore: chunk-delegate streaming, 8-way ranged chunks for xet-backed files
    //     ≥ 64 MB, byte-accurate `WeightDownloadProgress` via an AsyncStream task-context
    //     bridge — lifted from the mage-flow reference executor, commits cf45682/6faa4cb).
    //     Every package gains first-run download for free; the per-package WeightMaterializer
    //     copies (MLXLTX2/MLXKlein/MLXZImage/MLXMageFlow) become deletable, and a package that
    //     still self-materializes stays correct — its own missing-check runs after the
    //     engine's pass and finds nothing left.
    //   • `SelfMaterializing` (marker protocol, this file's sibling in WeightSources.swift):
    //     the opt-out for packages whose downloads the generic executor can't do (non-HF
    //     hosts, wrappers whose runtime fetches internally). Bundled-only packages need
    //     nothing — their missing-set is empty.
    //   • MS-2 default probe extension: `defaultMissingWeightSources` accepts the
    //     engine-executed FLAT layout (files directly under `ModelStore.directory(for:)` — the
    //     fleet convention the per-package executors established) alongside the hub-client
    //     snapshot layout; `WeightSourceProbe.flatDirectory(_:satisfies:)` excludes hub-cache
    //     bookkeeping (`snapshots/`, `refs/`, `blobs/`) and the install marker so a
    //     half-materialized hub layout can't read as a satisfied flat one.
    //   • Engine seam: `MLXServeEngine.init(materializer:)` injects a `WeightMaterializing`
    //     executor (tests run the pre-load hook offline; default = live `WeightMaterializer`
    //     sharing the engine's `hubMetadata` listing — enumeration stays one public tree GET,
    //     still no hub-client dependency in the engine).
    // 1.25.0 (2026-07-24, additive): STREAMING TTS OUTPUT (ENGINE-NEEDS N2) — the token-
    //   streaming question RunPhase deliberately deferred (1.18.0), answered for audio first.
    //   • `TTSStreamChunk` (TTS.swift): mono normalized PCM `samples` + `sampleRate` + strictly
    //     monotonic `index` + exactly-once-last `isFinal`. NOT an `Audio` artifact — a per-chunk
    //     .wav container has no standalone semantics; the canonical artifact contract is
    //     untouched (the aggregated response is still always `.wav`). No timing field — timing
    //     rides `RunProgress`, the observability plane.
    //   • `StreamEmitting` (Streaming.swift, opt-in, `as?`-detected like `SelfMaterializing`):
    //     `runStream(_:emit:)` on `@InferenceActor` — the package calls a plain @Sendable
    //     closure SYNCHRONOUSLY from its run loop (so the `RunProgress.$sink` task-local
    //     binding and cancellation checkpoints hold — the WeightMaterializer task-context
    //     lesson, made structural) and still returns the aggregated canonical response, so the
    //     engine's run-handle machinery is reused unchanged. First realization: GepardPackage
    //     (causal NanoCodec decode every K frames, exact by causality).
    //   • `ToolDescriptor.streaming: StreamGranularity?` (nil = batch-only = every existing
    //     conformer; v1 vocabulary: `.audioChunk`). `TTSContract.descriptor` passes it through.
    //     Inert on the MCP wire in V1 (no streaming transport — mcp-wire-fidelity-spike.md).
    //   • Engine seam (MLXServeCore, recorded here for the program's history):
    //     `MLXServeEngine.stream(_:package:bufferingPolicy:)` → `TTSStreamHandle` (chunk stream
    //     + aggregated-response task). Streams are NON-requeueable: once chunks are delivered a
    //     from-scratch requeue would replay audio, so a governor preemption surfaces as the new
    //     `EngineError.streamPreempted` — a caller-distinguishable failure, never a
    //     `CancellationError` the caller didn't cause (the V3 invariant, preserved). An
    //     abandoned chunk stream cancels the run (no orphan GPU work); completion-only callers
    //     use `run()`. Buffering default `.unbounded` — dropping audio is corruption
    //     (~176 KB/s worst case, bounded by utterance length).
    //   • STR gate (MLXServeConformance/StreamingConformance.swift): offline STR-1..3
    //     (advertisement⇔conformance coherence, pre-cancelled runStream, posture declaration)
    //     + live STR-4..7 in the package CLI lane (sequence integrity, aggregation parity,
    //     task-context emission, mid-stream cancel). Latency is a TestKit bench
    //     (`StreamingBench`, the `[STR]` line), not a gate.
    // 1.26.0 (2026-07-24, additive): MEASURED LLM USAGE (ENGINE-NEEDS) — `LLMResponse` carried
    //   no token counts and, unlike `LLMRequest`, no `metaData` channel either, so a package had
    //   literally nowhere to put them. Every throughput consumer therefore FAKED it: the Liquid
    //   LFM 2.5 Demo's metrics harness computed `chars / 4 / runSeconds` and printed a caveat
    //   saying so. Meanwhile the real numbers were already arriving and being discarded —
    //   mlx-swift-lm's `GenerateCompletionInfo` rides the `Generation` stream as `.info`, and
    //   every package's `switch` swallowed it under `default: break`.
    //   • `LLMUsage` (LLM.swift): promptTokens / generationTokens / promptSeconds /
    //     generateSeconds, + derived `generationTokensPerSecond` / `promptTokensPerSecond`
    //     (Optional, nil rather than 0 when the phase was too short to time — a 0 would read as
    //     "measured slow"). Seconds are `Double`, not `TimeInterval`, so LLM.swift stays
    //     Foundation-free.
    //   • `LLMResponse.usage: LLMUsage?` — defaulted `nil` in the initializer, so all 31 existing
    //     construction sites (6 in packages, 25 engine test mocks) compile untouched. `nil` means
    //     "package doesn't report usage" and is NOT zero; consumers must not substitute an
    //     estimate for it — that substitution is the gap being closed.
    //   • MEASURED-NEVER-ESTIMATED is the contract: a package populates `usage` only from counts
    //     its runtime actually reported (the `.info` event, or its own token loop on a
    //     constrained-decoding path). Deriving them from the text is a contract violation.
    //   • Cross-package caveat, documented ON the field: `promptTokens` is not comparable
    //     between packages that differ in KV-cache reuse — a package holding a `ChatSession`
    //     across turns (qwen v0.3.0 prompt caching) prefills only the new suffix, while one
    //     building a fresh session per turn (lfm) re-counts the conversation. `generationTokens`
    //     / `generateSeconds` — decode throughput — is the comparable axis, and is the number a
    //     model bake-off should quote.
    //   • Ride-along fidelity fix: `GenerateCompletionInfo.stopReason` (`GenerateStopReason`,
    //     .stop/.length/.cancelled) maps 1:1 onto `FinishReason`, so capturing `.info` also
    //     retires the hardcoded `finishReason: .stop` on the freeform paths — a `maxTokens`
    //     truncation previously reported as a natural stop. Same code site, no new surface.
    //   • First adopter: mlx-lfm-llm-swift (both paths — `.info` capture on the freeform
    //     `streamDetails` drive; self-counted on the structured `TokenIterator` drive).
    //     qwen/gemma adopt incrementally: their freeform paths sit on `ChatSession.respond`
    //     (string plane), which does NOT surface `.info` — adoption there is a `streamDetails`
    //     migration, scoped separately.
    // 1.27.0 (2026-07-25, additive): INFERENCE MODE — the C14 conformance item + its INF gate.
    //   No contract TYPE changes: C14 is a checklist item and a test-facing seam, so every
    //   existing manifest is unchanged and no package is retroactively non-conformant. Recorded
    //   here because the conformance surface is what the version tracks.
    //   • Motivating defect (mlx-birefnet-swift, 2026-07-25): `MLXNN.Module.training` defaults to
    //     **true**, and in that state `BatchNorm.callAsFunction` normalizes by the CURRENT batch's
    //     statistics and OVERWRITES the checkpoint's `running_mean`/`running_var` every forward
    //     (mlx-swift `Source/MLXNN/Normalization.swift`). The trained statistics were never read
    //     and repeated calls on one instance drifted. Invisible to eyeball validation — the matte
    //     still looked like a matte while the PROD fast tier over-segmented by 68 % (foreground
    //     fraction 0.42 vs the PyTorch oracle's 0.25) and e2e logits cosine was 0.264. One
    //     `model.train(false)` at the pipeline construction choke point → 0.99999.
    //   • `Dropout` is the SAME hazard class and is NOT identity-safe: it short-circuits only at
    //     `p == 0` or `!training` (`Source/MLXNN/Dropout.swift`), so a port carrying its upstream
    //     `p` randomly zeroes activations at inference. Fleet sweep (2026-07-25) found exactly one
    //     live instantiation — kokoro-mlx-swift's Albert (`p` = hidden_dropout_prob, default 0.1)
    //     — whose `train(false)` is therefore load-bearing, not hygiene. Norms with no running
    //     statistics (LayerNorm/RMSNorm/GroupNorm) never read `training` and are unaffected.
    //   • INF gate (`MLXServeConformance/InferenceModeConformance.swift`): INF-1 every module in
    //     the LOADED graph reports `training == false` (an empty graph fails rather than passing
    //     vacuously — the "ran it before load()" trap); INF-2 a package with no module graph (a
    //     functional port reading running statistics straight from the weight dict, or a non-MLX
    //     package) declares `.notApplicable(reason:)`, an exemption that FAILS if the walk
    //     observed modules anyway. Presence of inference mode on the real graph is the criterion —
    //     never output plausibility (weights can make batch stats ≈ running stats by luck), and
    //     never the presence of `.train(false)` in source (it may sit on an untaken path).
    //   • `InferenceModeInspectable` (test-facing seam) — the package exposes its loaded graph's
    //     flags; only it knows where its models live. The shared `Module` walk ships in the NEW
    //     `MLXServeConformanceNN` product, split out so `MLXServeConformance` stays MLX-free
    //     (`mlx-audio-polish-swift`, the non-MLX capability seam, consumes the suite).
    //   • INF-3 idempotence is a TestKit bench (`InferenceModeBench`, the `[INF]` line), not a
    //     gate: two `run()` calls on ONE loaded instance must produce identical output. It catches
    //     the failure CLASS rather than the known mechanism — statistic drift, live Dropout, and
    //     anything training-mode-sensitive not yet met — which is what would have caught BiRefNet
    //     without anyone knowing BatchNorm was the mechanism.
    public static let current = SemanticVersion(major: 1, minor: 27, patch: 0)
}
