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
        }
    }
}
