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
    //   • MS-5 (docs/comments only): the never-built `HubAssetSource` SHA256-verification claims
    //     are retired across both doc trees. Weight integrity is the hub client's responsibility
    //     (xet chunk hashes / ETag verification in swift-huggingface); the engine verifies
    //     presence, not content. We do not build a parallel hasher.
    public static let current = SemanticVersion(major: 1, minor: 22, patch: 0)
}
