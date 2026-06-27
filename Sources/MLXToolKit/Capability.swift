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
        }
    }
}
