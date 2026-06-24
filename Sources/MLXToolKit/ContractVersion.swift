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
    public static let current = SemanticVersion(major: 1, minor: 8, patch: 0)
}
