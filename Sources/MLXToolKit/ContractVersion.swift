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
    public static let current = SemanticVersion(major: 1, minor: 14, patch: 0)
}
