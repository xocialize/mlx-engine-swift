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
///
/// `.png`/`.jpeg` carry compressed bytes. `.rawBGRA8` (1.9.0, additive) carries **raw interleaved
/// BGRA8 pixel bytes** in `data` — the same serialized round-trip form (so the V1 rule holds, this
/// does not fork the contract), but with no compression/clamp at the model boundary. For `.rawBGRA8`,
/// `width` and `height` are **required** (a consumer/package may assume them present), and
/// `bytesPerRow` is the optional row stride in bytes (defaults to `width * 4`, i.e. tightly packed).
public struct Image: Artifact, Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case png, jpeg, rawBGRA8 }
    public let format: Format
    public let data: Data
    public let width: Int?
    public let height: Int?
    /// Row stride in bytes for `.rawBGRA8` (`nil` ⇒ tightly packed `width * 4`). Ignored for png/jpeg.
    public let bytesPerRow: Int?

    public init(format: Format, data: Data, width: Int? = nil, height: Int? = nil, bytesPerRow: Int? = nil) {
        self.format = format
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    /// Convenience for the raw BGRA8 case, where `width`/`height` are required.
    /// `bytesPerRow` defaults to tightly packed (`width * 4`).
    public static func rawBGRA8(data: Data, width: Int, height: Int, bytesPerRow: Int? = nil) -> Image {
        Image(format: .rawBGRA8, data: data, width: width, height: height, bytesPerRow: bytesPerRow)
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

/// Canonical 3D mesh artifact — a triangle mesh serialized as **GLB** bytes (binary glTF) in `data`
/// (the V1 serialized round-trip form). The first-class output of the `imageTo3D` capability.
///
/// `vertexCount`/`faceCount` are optional descriptive metadata (a consumer can read the true counts
/// from the GLB). `hasVertexColors` flags whether per-vertex color is baked in (TRELLIS.2 V1 ships
/// geometry + vertex color; a PBR-texture follow-on stays the same `.glb` artifact, so no fork).
public struct Mesh: Artifact, Sendable, Codable, Equatable {
    public enum Format: String, Sendable, Codable { case glb }
    public let format: Format
    public let data: Data
    public let vertexCount: Int?
    public let faceCount: Int?
    public let hasVertexColors: Bool

    public init(format: Format = .glb, data: Data,
                vertexCount: Int? = nil, faceCount: Int? = nil, hasVertexColors: Bool = false) {
        self.format = format
        self.data = data
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.hasVertexColors = hasVertexColors
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
