/// The canonical capability surfaces MLXEngine exposes.
///
/// Capability is the *contract*: each case is a tool surface with one canonical input
/// schema and one canonical output artifact type. The enum is core-owned and **additive
/// only** — new cases arrive at minor contract versions and never invalidate existing
/// packages, *provided consumers switch with `@unknown default`* (C12). Contributors do
/// not add cases unilaterally; an addition is a versioned core change.
public enum Capability: String, Codable, Sendable, CaseIterable, Hashable {
    case tts
    case textToImage
    case imageEdit
    case textToVideo
    case llm
    case imageAnalysis
    case videoAnalysis
    case audioSeparation
    case speechEmotion
    case audioCodec
    case audioPolish
    case imageQualityScore
    case imageRestore
    case imageUpscale
    case videoUpscale
    case frameInterpolate
    case contentClassify
    case opticalFlow
    case soundEffect
    /// Instruction-driven **video** editing — source video (+ optional reference
    /// images) + prompt → edited video. Contract 1.3.0; introduced by Bernini-R's
    /// v2v/rv2v. (Image editing is `imageEdit`; reference-conditioned *generation*
    /// rides `textToVideo.referenceImages`.)
    case videoEdit
    /// Audio-driven **lip-sync / face reenactment** — a source face video + driving audio →
    /// a video whose mouth/lower-face is regenerated to match the speech. Contract 1.4.0;
    /// introduced by MuseTalk. (Distinct from `textToVideo`: conditioned on a source face and
    /// an audio track, not a text prompt.)
    case talkingHead
    /// Foreground **matte extraction** — an image → a single-channel matte (alpha / coverage map,
    /// 0 = background … 1 = foreground). Binary segmentation vs. soft alpha is chosen per-request
    /// (`MattingRequest.preferredKind`). The matte is a **first-class, reusable signal** — other
    /// capabilities consume it as a weight map (region-aware `imageRestore`/`imageUpscale`,
    /// `opticalFlow`-guided temporal propagation), so background removal is one consumer, not the
    /// only one. Contract 1.5.0; introduced by BiRefNet. (Distinct from `imageEdit`, which returns a
    /// full edited `Image`; matting returns the alpha, not a composited cutout.)
    case matting
    /// **Character animation / motion transfer** — a reference character `Image` + a driving
    /// `Video` → a video of that character performing the driving performance. Two semantics ride
    /// the `mode` tag: `.animation` (the reference identity performs the driving motion) and
    /// `.replacement` (the reference identity is swapped into the driving clip). An optional
    /// `drivingMask` video supplies spatial control and an optional `prompt` adds text steering.
    /// Contract 1.6.0; introduced by SCAIL-2, and the lane shared by Wan2.2-Animate (model-specific
    /// driver encodings — color-coded masks, pose/face extraction — stay package-internal
    /// preprocessing, not request fields). (Distinct from `textToVideo` — conditioned on a
    /// reference identity + a driving video, not a text prompt; distinct from `videoEdit` — the
    /// driving clip is a performance source, not the artifact being edited; distinct from
    /// `talkingHead` — full-body video-driven, not audio-driven facial.)
    case characterAnimation
    /// **Automatic colorization** — a grayscale / desaturated `Image` → a plausibly colorized
    /// `Image` at the same dimensions. Color is *invented* (no reference), so unlike `imageRestore`
    /// there is no full-reference quality floor — it's an opt-in enhance-style transform. Contract
    /// 1.7.0; introduced by DDColor. (Distinct from `imageEdit`, which is instruction-driven and may
    /// restructure content; from `imageRestore`, which cleans artifacts without adding color; and
    /// from `imageUpscale`, which changes resolution.)
    case imageColorize
    /// **Promptable segmentation** — an `Image` + point/box prompts → a single-channel `Matte` of the
    /// indicated object. Interactive (the caller clicks/boxes the thing to segment), unlike `matting`'s
    /// automatic foreground extraction. Output is the same `Matte` artifact, so consumers (Extract's
    /// cutout, Erase's fill mask) treat it uniformly. Contract 1.9.0; introduced by EdgeTAM (on-device
    /// SAM 2). (Distinct from `matting` — promptable vs automatic, same `.matte` output; the shared
    /// promptable-mask lane for Extract Stage-2 click-select and Erase click-to-erase.)
    case promptSegment
    /// **Object removal / inpainting** — an `Image` + a `mask` (white = remove) → an `Image` with the
    /// masked region plausibly filled from surrounding context, at the same dimensions. The fill is
    /// *invented* (no full-reference floor) — an opt-in transform. Contract 1.8.0; introduced by LaMa
    /// (+ MI-GAN fast tier). The two-input (image **and** mask) shape is unique to this surface.
    /// (Distinct from `imageEdit` — instruction-driven, may add new content; from `matting` — returns
    /// the mask, not a filled image. The "what to remove" mask is produced upstream, e.g. by `matting`.)
    case imageInpaint
    /// **Promptable video object tracking** — a `Video` + point/box prompts on one frame → a per-frame
    /// `Matte` track of the indicated object across the whole clip (masklet propagation). The temporal
    /// extension of `promptSegment`: click an object once, get its mask on every frame. Output is a
    /// **sequence** of `Matte`s (`CanonicalOutput.matteSequence`), lossless per-frame (not a re-encoded
    /// mask video). Contract 1.11.0; introduced by EdgeTAM (on-device SAM 2). (Distinct from
    /// `promptSegment` — propagates through time vs a single still; from `matting` — promptable +
    /// temporal. The video masklet lane for Erase click-to-erase across frames + Extract video cutout.)
    case trackObject
    /// **Single-image → 3D** — one `Image` → a 3D triangle mesh (`CanonicalOutput.mesh`, GLB bytes).
    /// The geometry is *invented* from a single view (no multi-view reconstruction). Resolution tier
    /// (voxel grid 512/1024/1536) rides `mode`. Contract 1.12.0; introduced by Pixal3D / TRELLIS.2.
    /// (Distinct from every existing surface — the first capability whose artifact is a 3D mesh, not a
    /// 2D image / video / matte. Background removal of the input is package-internal preprocessing,
    /// reusing the shipped BiRefNet `matting`, not a request field.)
    case imageTo3D
    /// **Text embedding** — a batch of texts → one dense vector per text, for semantic retrieval.
    /// Asymmetric-retrieval-aware: `inputType` distinguishes query-side texts (which receive an
    /// instruction prefix) from stored document-side texts (which don't), and an optional
    /// Matryoshka `dimensions` truncates before L2-normalization so a consumer can shrink its
    /// index. Vectors ride the response directly (`EmbedResponse.vectors`, the
    /// `imageQualityScore` non-Artifact precedent) — an index must never mix models or
    /// dimensions, so the response also carries `modelID` + `dimension` provenance. Contract
    /// 1.15.0; introduced by Qwen3-Embedding-0.6B. (Distinct from `llm` — deterministic
    /// text → vector encoding, no generation; from `MLXRetrievalKit` — that is web search,
    /// not vector production.)
    case embed
    /// **Speech-to-text** — a speech `Audio` clip (+ optional BCP-47 `language` hint, nil = auto-detect)
    /// → the transcript with native punctuation/capitalization, plus timestamped segments and the
    /// detected language. Utterance-shaped and one-shot: the caller sends a complete utterance; live
    /// partial hypotheses are NOT this surface (that is the deferred token-streaming contract,
    /// companion N2 — same boundary `RunPhase` drew in 1.18.0). Contract 1.20.0; introduced by
    /// Nemotron 3.5 ASR streaming (cache-aware FastConformer-RNNT; the model's internal chunked
    /// streaming is package-internal memory discipline, not a request surface). (Distinct from
    /// `speechEmotion` — transcription, not classification; from `llm` — deterministic audio → text
    /// recognition, not generation.)
    case stt
    /// **Mesh auto-rigging** — a 3D triangle `Mesh` (GLB) → the SAME mesh with a skeleton + skin
    /// weights injected (`CanonicalOutput.mesh`, rigged GLB bytes). Two modes ride `mode`
    /// (`MeshRigContract.auto` = generate skeleton + skin · `.skinOnly` = predict skin for a
    /// caller-provided skeleton). Contract 1.19.0; introduced by SkinTokens. (Distinct from
    /// `imageTo3D`: that INVENTS geometry from an image; this takes existing geometry and adds a
    /// rig — mesh-in / rigged-mesh-out, the first surface whose input AND output are `Mesh`.
    /// The companion-character path: a VRM's own skeleton → `skinOnly` → skinned VRM.)
    case meshRig
    /// **Exposure / lighting correction** — an `Image` → the SAME scene re-exposed (lifted shadows,
    /// recovered mid-tones) at the same dimensions, plus a `strength` dial. Contract 1.29.0;
    /// introduced by HVI-CIDNet.
    ///
    /// Deliberately NOT folded into `imageRestore`. Three reasons: the request carries a
    /// **strength** parameter that restoration has no notion of; the operation is **continuously
    /// dialable and reversible in intent** (an exposure choice) rather than a defect being removed;
    /// and it needs a **bypass** — low-light models drive output toward a target mean luma
    /// regardless of input, so on an already-correctly-exposed image they *degrade* it (measured:
    /// 16–23 dB across HVI-CIDNet's checkpoints). A planner asking "restore this" must not
    /// silently re-expose a correctly-exposed photo, and a user asking "brighten this" would not
    /// think to look under restoration.
    ///
    /// (Distinct from `imageRestore` — that removes defects at fixed appearance; from `imageEdit` —
    /// instruction-driven and free to invent content; from `imageColorize` — adds chroma to
    /// greyscale rather than redistributing luminance.)
    case imageRelight
}

/// The fixed output artifact kind for a capability. Not negotiable per package (C2).
public enum CanonicalOutput: String, Codable, Sendable {
    case audio
    case image
    case video
    case text
    case structuredText
    case codes
    case flow
    /// A single-channel matte / alpha map (grayscale). The canonical output of `matting`.
    case matte
    /// A time-ordered **sequence** of mattes (one per video frame) — a masklet. The canonical output of
    /// `trackObject`. Lossless per-frame (each element is a `Matte`), distinct from `.video` so generic
    /// consumers don't treat a mask track as a single playable clip.
    case matteSequence
    /// A 3D triangle **mesh** (vertices + faces), serialized as GLB bytes. The canonical output of
    /// `imageTo3D`. Net-new artifact kind (all others are 2D image / video / audio / text / matte) —
    /// distinct from `.image`/`.video` so generic consumers don't treat geometry as a rendered frame.
    case mesh
}

extension Capability {
    /// The canonical output for this capability (TTS -> .wav audio, T2I -> image, ...).
    public var canonicalOutput: CanonicalOutput {
        switch self {
        case .tts: return .audio
        case .textToImage: return .image
        case .imageEdit: return .image
        case .textToVideo: return .video
        case .llm: return .text
        case .imageAnalysis, .videoAnalysis: return .structuredText
        case .audioSeparation: return .audio
        case .speechEmotion: return .structuredText
        case .audioCodec: return .codes
        case .audioPolish: return .audio
        case .imageQualityScore: return .structuredText
        case .imageRestore: return .image
        case .imageUpscale: return .image
        case .videoUpscale: return .video
        case .frameInterpolate: return .video
        case .contentClassify: return .structuredText
        case .opticalFlow: return .flow
        case .soundEffect: return .audio
        case .videoEdit: return .video
        case .talkingHead: return .video
        case .matting: return .matte
        case .characterAnimation: return .video
        case .imageColorize: return .image
        case .imageInpaint: return .image
        case .promptSegment: return .matte
        case .trackObject: return .matteSequence
        case .imageTo3D: return .mesh
        case .embed: return .structuredText
        case .stt: return .text
        case .meshRig: return .mesh
        case .imageRelight: return .image
        }
    }
}
