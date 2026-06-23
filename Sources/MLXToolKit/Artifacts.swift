import Foundation

/// A canonical, contracted media artifact.
///
/// V1 rule: artifacts cross every boundary in **serialized round-trip form** (`data`).
/// The in-process zero-copy path (tensor / IOSurface) is a V2 additive optimization behind
/// the same type, and must not fork the artifact contract.
public protocol Artifact: Sendable, Codable {
    var data: Data { get }
}

/// Canonical audio artifact. TTS always returns `.wav`.
public struct Audio: Artifact, Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case wav }
    public let format: Format
    public let data: Data
    public let sampleRate: Int?
    public let channels: Int?

    public init(format: Format = .wav, data: Data, sampleRate: Int? = nil, channels: Int? = nil) {
        self.format = format
        self.data = data
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Canonical image artifact.
public struct Image: Artifact, Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case png, jpeg }
    public let format: Format
    public let data: Data
    public let width: Int?
    public let height: Int?

    public init(format: Format, data: Data, width: Int? = nil, height: Int? = nil) {
        self.format = format
        self.data = data
        self.width = width
        self.height = height
    }
}

/// Canonical matte artifact — a single-channel alpha / coverage map (0 = background … 1 = foreground),
/// serialized as a grayscale PNG. The first-class output of the `matting` capability; consumable as a
/// weight-map signal by other capabilities (region-aware restore/upscale, flow-guided propagation),
/// not just as a cutout source. `kind` records whether the map is a hard segmentation or a soft matte.
public struct Matte: Artifact, Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case png }
    /// Hard binary segmentation vs. soft alpha matte (fine hair/fur/semi-transparency).
    public enum Kind: String, Sendable, Codable { case binary, softAlpha }
    public let format: Format
    public let data: Data
    public let width: Int?
    public let height: Int?
    public let kind: Kind

    public init(format: Format = .png, data: Data, width: Int? = nil, height: Int? = nil, kind: Kind) {
        self.format = format
        self.data = data
        self.width = width
        self.height = height
        self.kind = kind
    }
}

/// Canonical video artifact.
public struct Video: Artifact, Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case mp4, mov }
    public let format: Format
    public let data: Data
    public let durationSeconds: Double?
    public let frameRate: Double?

    public init(format: Format, data: Data, durationSeconds: Double? = nil, frameRate: Double? = nil) {
        self.format = format
        self.data = data
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
    }
}
