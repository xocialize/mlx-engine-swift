/// Canonical **character-animation / motion-transfer** surface (contract 1.6.0). Canonical output
/// is one **Video** artifact (`CharacterAnimationResponse.video`), serialized round-trip form (C3).
///
/// A `referenceImage` (the character identity) is combined with a `drivingVideo` (the performance
/// source) to produce a video of that character performing the driving motion. Two semantics ride
/// the `mode` tag — `.animation` (the reference identity performs the driving motion) and
/// `.replacement` (the reference identity is swapped into the driving clip) — same input artifacts,
/// different output semantics, so it's a Mode, not a separate surface (C4). Introduced by SCAIL-2;
/// the lane shared by Wan2.2-Animate.
///
/// The request is **lane-ready**: `drivingMask` and `prompt` are optional now so Wan2.2-Animate
/// plugs into the same capability with no further contract bump. Model-specific driver encodings —
/// SCAIL's 28-channel color-coded mask compression, Animate's pose/face extraction — are
/// **package-internal preprocessing**, not request fields (the caller supplies a plain RGB
/// `drivingMask` video). Package-specific levers ride `metaData` (C5).
public struct CharacterAnimationRequest: CapabilityRequest {
    public static var capability: Capability { .characterAnimation }

    /// The reference character whose identity is animated / inserted.
    public let referenceImage: Image
    /// The driving performance video (the motion to transfer).
    public let drivingVideo: Video
    /// Optional spatial-control mask video (e.g. foreground / per-subject correspondence). The
    /// caller supplies a plain RGB video; model-specific encoding is package-internal preprocessing.
    public let drivingMask: Video?
    /// Optional text steering.
    public let prompt: String?
    public let numFrames: Int?
    public let fps: Double?
    public let width: Int?
    public let height: Int?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    /// `.animation` (reference performs the motion) or `.replacement` (reference swapped into clip).
    public let mode: Mode?
    public let metaData: MetaData

    public init(referenceImage: Image,
                drivingVideo: Video,
                drivingMask: Video? = nil,
                prompt: String? = nil,
                numFrames: Int? = nil,
                fps: Double? = nil,
                width: Int? = nil,
                height: Int? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.referenceImage = referenceImage
        self.drivingVideo = drivingVideo
        self.drivingMask = drivingMask
        self.prompt = prompt
        self.numFrames = numFrames
        self.fps = fps
        self.width = width
        self.height = height
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical characterAnimation response — one `Video` artifact.
public struct CharacterAnimationResponse: CapabilityResponse {
    public let video: Video
    public init(video: Video) { self.video = video }
}

/// Canonical descriptor shape for a characterAnimation tool (C11).
public enum CharacterAnimationContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .characterAnimation,
            summary: summary,
            parameters: [
                ParameterSchema(name: "referenceImage", kind: .image, required: true,
                                summary: "The reference character whose identity is animated / inserted."),
                ParameterSchema(name: "drivingVideo", kind: .video, required: true,
                                summary: "The driving performance video (the motion to transfer)."),
                ParameterSchema(name: "drivingMask", kind: .video, required: false,
                                summary: "Optional spatial-control mask video (plain RGB)."),
                ParameterSchema(name: "prompt", kind: .string, required: false,
                                summary: "Optional text steering."),
                ParameterSchema(name: "numFrames", kind: .integer, required: false, summary: "Frame count."),
                ParameterSchema(name: "fps", kind: .number, required: false, summary: "Frames per second."),
                ParameterSchema(name: "width", kind: .integer, required: false, summary: "Output width."),
                ParameterSchema(name: "height", kind: .integer, required: false, summary: "Output height."),
                ParameterSchema(name: "steps", kind: .integer, required: false, summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false, summary: "CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false, summary: "RNG seed."),
            ],
            supportedModes: modes
        )
    }
}
