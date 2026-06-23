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
        }
    }
}
