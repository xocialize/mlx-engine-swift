import Foundation

// MARK: - The video surfaces' typed levers — contract 1.61.0 (AB-A-0236, MES Video 0.1)
//
// Before 1.61.0 a video package reached into `metaData` for everything the Media Engine Spec's Video
// profile needs: LTX read `retake.start` / `retake.duration` / `extend.seconds` / `kf.keyframes` (file
// paths) from it because `VEditRequest` had no time-span field, `VideoUpscale` had no way to be told
// live action from drawn, `FrameInterpolate` took an integer factor only, and a `Video` made a caller
// reopen the file to learn its size, frame count and audio. This file is those levers, in the shape
// the `music` (1.56.0) and `speechEdit` (1.59.0) surfaces set: a package DECLARES what it honors in a
// controls struct, the engine REFUSES an undeclared lever before admission (an ignored retake span
// regenerates the whole clip; an ignored keyframe yields a video that never reaches the frame the
// caller pinned; an ignored content kind picks the wrong upscaler — each is wrong output nothing in
// the file reveals), and the descriptor advertises only what is declared. Every refusal is a method on
// the controls struct (`refusal(for:)`), so a package driven directly refuses identically.
//
// A package that declares nothing behaves exactly as before: no request field here is read, no
// existing request is refused, and a surface with no controls block refuses every NEW lever.

// MARK: Shared value types

/// The unit of a `VideoSpan` or `VideoExtend` length. `seconds` is the canonical unit — a package that
/// honors any time lever honors seconds. `frames` is admitted only where a surface declares it
/// (`spanUnits`), because converting needs a frame rate a package may not trust the container for.
public enum VideoSpanUnit: String, Sendable, Codable, CaseIterable {
    case seconds
    case frames
}

/// A stretch of a clip: `start` inclusive, `end` exclusive, in `unit` from the clip's first frame.
/// Valid ⇔ finite, `start >= 0`, `end > start`, and whole numbers when `unit == .frames`
/// (`isValid`). The engine does not clamp: a span past the clip's end is refused where the source's
/// duration or frame count is known (`VEditControls.refusal(for:)`).
public struct VideoSpan: Sendable, Codable, Equatable {
    public let start: Double
    public let end: Double
    public let unit: VideoSpanUnit

    public init(start: Double, end: Double, unit: VideoSpanUnit = .seconds) {
        self.start = start
        self.end = end
        self.unit = unit
    }

    public static func seconds(_ start: Double, _ end: Double) -> VideoSpan {
        VideoSpan(start: start, end: end, unit: .seconds)
    }

    public static func frames(_ start: Int, _ end: Int) -> VideoSpan {
        VideoSpan(start: Double(start), end: Double(end), unit: .frames)
    }

    public var length: Double { end - start }

    public var isValid: Bool {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return false }
        if unit == .frames { return start == start.rounded() && end == end.rounded() }
        return true
    }

    /// This span as seconds. `frameRate` converts a `.frames` span and is ignored for `.seconds`; nil
    /// for a `.frames` span with no usable frame rate.
    public func inSeconds(frameRate: Double?) -> (start: Double, end: Double)? {
        switch unit {
        case .seconds: return (start, end)
        case .frames:
            guard let frameRate, frameRate > 0 else { return nil }
            return (start / frameRate, end / frameRate)
        }
    }

    private enum CodingKeys: String, CodingKey { case start, end, unit }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        unit = try c.decodeIfPresent(VideoSpanUnit.self, forKey: .unit) ?? .seconds
    }
}

/// Which track of a clip a retake regenerates. `both` is the default and what a package that cannot
/// separate its tracks (LTX's joint audio-video latent) can honor only as `both`.
public enum VideoModality: String, Sendable, Codable, CaseIterable {
    /// The picture; the soundtrack under the span is kept.
    case picture
    /// The soundtrack; the picture under the span is kept.
    case sound
    /// Picture and sound together.
    case both
}

/// Where an extension grows the clip. `before` exists in the contract for the packages that can
/// (a package declares which directions it honors); nothing requires one to.
public enum VideoExtendDirection: String, Sendable, Codable, CaseIterable {
    case after
    case before
}

/// "Regenerate this stretch of the source, keep the rest" — `VEditRequest.retake`.
public struct VideoRetake: Sendable, Codable, Equatable {
    public let span: VideoSpan
    public let modality: VideoModality

    public init(span: VideoSpan, modality: VideoModality = .both) {
        self.span = span
        self.modality = modality
    }

    private enum CodingKeys: String, CodingKey { case span, modality }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        span = try c.decode(VideoSpan.self, forKey: .span)
        modality = try c.decodeIfPresent(VideoModality.self, forKey: .modality) ?? .both
    }
}

/// "Grow the clip by this much, in this direction" — `VEditRequest.extend`. The extension is
/// generated from the source's edge frames and its prompt; the source is kept intact and the result
/// is the source plus `length`.
public struct VideoExtend: Sendable, Codable, Equatable {
    public let length: Double
    public let unit: VideoSpanUnit
    public let direction: VideoExtendDirection

    public init(length: Double, unit: VideoSpanUnit = .seconds, direction: VideoExtendDirection = .after) {
        self.length = length
        self.unit = unit
        self.direction = direction
    }

    public static func seconds(_ length: Double, direction: VideoExtendDirection = .after) -> VideoExtend {
        VideoExtend(length: length, unit: .seconds, direction: direction)
    }

    public var isValid: Bool {
        guard length.isFinite, length > 0 else { return false }
        return unit == .seconds || length == length.rounded()
    }

    private enum CodingKeys: String, CodingKey { case length, unit, direction }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        length = try c.decode(Double.self, forKey: .length)
        unit = try c.decodeIfPresent(VideoSpanUnit.self, forKey: .unit) ?? .seconds
        direction = try c.decodeIfPresent(VideoExtendDirection.self, forKey: .direction) ?? .after
    }
}

/// An image pinned to a frame of the clip a package generates — `T2VRequest.keyframes`.
///
/// `frame` is a 0-based index into the OUTPUT's frames. A **negative** index counts from the end, so a
/// caller who does not know the resolved frame count (the package may round `numFrames` to its
/// 8k+1 grid) still names the final frame: `-1` is the last frame, `-2` the one before it. The final
/// frame is therefore a keyframe like any other (`VideoKeyframe.last(_:strength:)`), not a separate
/// field — one way to say it. `strength` 0…1 is how firmly the frame is held (nil = the package's
/// default); honored only where the surface declares `supportsStrength`.
public struct VideoKeyframe: Sendable, Codable, Equatable {
    public let image: Image
    public let frame: Int
    public let strength: Double?

    public init(image: Image, frame: Int, strength: Double? = nil) {
        self.image = image
        self.frame = frame
        self.strength = strength
    }

    /// The final frame of the output (`frame == -1`).
    public static func last(_ image: Image, strength: Double? = nil) -> VideoKeyframe {
        VideoKeyframe(image: image, frame: -1, strength: strength)
    }

    /// `frame` as a 0-based index into an output of `frameCount` frames, or nil when it falls outside
    /// it (`frame >= frameCount`, or a negative index reaching before frame 0).
    public func resolvedFrame(in frameCount: Int) -> Int? {
        let index = frame >= 0 ? frame : frameCount + frame
        return (0..<frameCount).contains(index) ? index : nil
    }

    private enum CodingKeys: String, CodingKey { case image, frame, strength }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decode(Image.self, forKey: .image)
        frame = try c.decode(Int.self, forKey: .frame)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength)
    }
}

/// What a clip's soundtrack is, as a FACT about an artifact (`Video.audio`). Unknown is the property
/// being nil; "no soundtrack" is `VideoAudioFacts.noAudio`.
public struct VideoAudioFacts: Sendable, Codable, Equatable {
    public let hasAudio: Bool
    public let sampleRate: Int?
    public let channels: Int?

    public init(hasAudio: Bool, sampleRate: Int? = nil, channels: Int? = nil) {
        self.hasAudio = hasAudio
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// A clip that carries no soundtrack. Named `noAudio`, not `none`: `Video(audio: .none)` would
    /// resolve to `Optional.none` — "unknown" — and say the opposite.
    public static let noAudio = VideoAudioFacts(hasAudio: false)

    /// A soundtrack of `sampleRate` Hz and `channels` channels.
    public static func present(sampleRate: Int?, channels: Int?) -> VideoAudioFacts {
        VideoAudioFacts(hasAudio: true, sampleRate: sampleRate, channels: channels)
    }

    private enum CodingKeys: String, CodingKey { case hasAudio, sampleRate, channels }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasAudio = try c.decode(Bool.self, forKey: .hasAudio)
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
    }
}

/// What a video upscaler's content is, as MES Video §3.4 names it — told, never guessed.
public enum VideoContent: String, Sendable, Codable, CaseIterable {
    case liveAction
    case drawn
}

/// Whether and how a generating surface puts a soundtrack in its output.
public enum VideoAudioOutput: String, Sendable, Codable, CaseIterable {
    /// Never: the output carries no audio (a silent model). `includeAudio: true` is refused;
    /// `false` is trivially honored.
    case silent
    /// Always: the audio is part of the generation (LTX's joint latent) and is muxed. `includeAudio:
    /// false` is refused — the engine does not pretend the track was dropped.
    case always
    /// Either: `includeAudio` is honored in both directions.
    case switchable
}

// MARK: - videoEdit: retake and extend

/// What a **`videoEdit`** surface can do beyond the whole-clip edit — optional (`SurfaceControls.
/// videoEdit`, read via `ToolDescriptor.videoEditControls`). Retake is declared by listing the
/// modalities it can regenerate, extend by listing the directions it can grow; an empty list means
/// the lever is not declared, so there is one source of truth and no feature set to contradict it.
public struct VEditControls: Sendable, Codable, Equatable {
    /// The modalities `VEditRequest.retake` may name. Non-empty ⇔ retake is declared. A package that
    /// cannot separate tracks declares `[.both]`.
    public let retakeModalities: [VideoModality]
    /// The directions `VEditRequest.extend` may name. Non-empty ⇔ extend is declared.
    public let extendDirections: [VideoExtendDirection]
    /// The units a span or extension length may be given in. `seconds` is always honored by a surface
    /// that declares retake or extend; list `.frames` too where the package takes frame indices.
    public let spanUnits: [VideoSpanUnit]
    /// The longest extension, in seconds. Engine-enforced; nil = unstated.
    public let maxExtendSeconds: Double?
    /// The package emits `RunPreviewFrame`s while it runs (see `RunProgress.reportPreview`).
    /// OUTPUT-side: it tells a host to render a preview strip. Nothing to refuse.
    public let emitsFramePreviews: Bool

    public init(retakeModalities: [VideoModality] = [],
                extendDirections: [VideoExtendDirection] = [],
                spanUnits: [VideoSpanUnit] = [.seconds],
                maxExtendSeconds: Double? = nil,
                emitsFramePreviews: Bool = false) {
        self.retakeModalities = retakeModalities
        self.extendDirections = extendDirections
        self.spanUnits = spanUnits
        self.maxExtendSeconds = maxExtendSeconds
        self.emitsFramePreviews = emitsFramePreviews
    }

    public var declaresRetake: Bool { !retakeModalities.isEmpty }
    public var declaresExtend: Bool { !extendDirections.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case retakeModalities, extendDirections, spanUnits, maxExtendSeconds, emitsFramePreviews
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retakeModalities = try c.decodeIfPresent([VideoModality].self, forKey: .retakeModalities) ?? []
        extendDirections = try c.decodeIfPresent([VideoExtendDirection].self, forKey: .extendDirections) ?? []
        spanUnits = try c.decodeIfPresent([VideoSpanUnit].self, forKey: .spanUnits) ?? [.seconds]
        maxExtendSeconds = try c.decodeIfPresent(Double.self, forKey: .maxExtendSeconds)
        emitsFramePreviews = try c.decodeIfPresent(Bool.self, forKey: .emitsFramePreviews) ?? false
    }

    /// Internal inconsistencies of the declaration; empty for a coherent one (a package's manifest
    /// test asserts it, the C11 "honest descriptor" expectation).
    public var declarationProblems: [String] {
        var problems: [String] = []
        if (declaresRetake || declaresExtend), !spanUnits.contains(.seconds) {
            problems.append("spanUnits must include .seconds when retake or extend is declared")
        }
        if let limit = maxExtendSeconds {
            if !(limit > 0) { problems.append("maxExtendSeconds must be positive") }
            if !declaresExtend { problems.append("maxExtendSeconds is declared without extendDirections") }
        }
        return problems
    }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it
    /// as `PackageError.unsupportedRequestFeature` before admission; a package driven directly may
    /// call it first for the same refusal.
    public func refusal(for request: VEditRequest) -> String? {
        if request.retake != nil, request.extend != nil {
            return "retake and extend — a request names one or the other: retake regenerates a stretch "
                + "of the source, extend grows the clip"
        }
        if let retake = request.retake {
            guard declaresRetake else {
                return "retake — this surface declares no retake (VEditControls.retakeModalities); it "
                    + "would regenerate the whole clip instead of the span, so choose a package that "
                    + "declares retake"
            }
            let span = retake.span
            guard span.isValid else {
                return "retake.span(\(Self.format(span.start))…\(Self.format(span.end)) \(span.unit.rawValue)) "
                    + "— needs a finite start >= 0 and an end > start"
                    + (span.unit == .frames ? ", in whole frames" : "")
            }
            guard spanUnits.contains(span.unit) else {
                return "retake.span in \(span.unit.rawValue) — not one of the units this surface declares "
                    + "(VEditControls.spanUnits: " + spanUnits.map(\.rawValue).joined(separator: " / ") + ")"
            }
            guard retakeModalities.contains(retake.modality) else {
                return "retake.modality(.\(retake.modality.rawValue)) — not one of the modalities this "
                    + "surface declares (VEditControls.retakeModalities: "
                    + retakeModalities.map(\.rawValue).joined(separator: " / ") + ")"
            }
            if let past = Self.pastSourceEnd(span, in: request.video) {
                return "retake.span — ends at \(past), past the end of the source clip"
            }
        }
        if let extend = request.extend {
            guard declaresExtend else {
                return "extend — this surface declares no extension (VEditControls.extendDirections); "
                    + "choose a package that declares extend"
            }
            guard extend.isValid else {
                return "extend.length(\(Self.format(extend.length)) \(extend.unit.rawValue)) — must be finite "
                    + "and > 0" + (extend.unit == .frames ? ", in whole frames" : "")
            }
            guard spanUnits.contains(extend.unit) else {
                return "extend.length in \(extend.unit.rawValue) — not one of the units this surface declares "
                    + "(VEditControls.spanUnits: " + spanUnits.map(\.rawValue).joined(separator: " / ") + ")"
            }
            guard extendDirections.contains(extend.direction) else {
                return "extend.direction(.\(extend.direction.rawValue)) — not one of the directions this "
                    + "surface declares (VEditControls.extendDirections: "
                    + extendDirections.map(\.rawValue).joined(separator: " / ") + ")"
            }
            if let limit = maxExtendSeconds {
                let seconds = extend.unit == .seconds ? extend.length
                    : request.video.frameRate.flatMap { $0 > 0 ? extend.length / $0 : nil }
                if let seconds, seconds > limit {
                    return "extend.length(\(Self.format(seconds)) s) — this surface extends by at most "
                        + "\(Self.format(limit)) s (VEditControls.maxExtendSeconds)"
                }
            }
        }
        return nil
    }

    /// The span's end, formatted, when the source's own facts show it ends beyond the clip; nil when
    /// within it or when the source states nothing to judge by.
    private static func pastSourceEnd(_ span: VideoSpan, in video: Video) -> String? {
        switch span.unit {
        case .frames:
            if let count = video.frameCount, span.end > Double(count) {
                return "frame \(format(span.end)) of \(count)"
            }
        case .seconds:
            if let duration = video.durationSeconds, span.end > duration + 1e-3 {
                return "\(format(span.end)) s of \(format(duration)) s"
            }
        }
        return nil
    }

    static func format(_ value: Double) -> String { String(format: "%g", value) }
}

// MARK: - textToVideo: keyframes and the audio switch

/// Which frames a surface lets a keyframe pin.
public enum VideoKeyframePlacement: String, Sendable, Codable, CaseIterable {
    /// The first and last frame only (`frame == 0` or `-1`) — first/last-frame models.
    case endpoints
    /// Any frame (LTX).
    case anyFrame
}

/// The keyframes a `textToVideo` surface honors — `T2VControls.keyframes`.
public struct VideoKeyframeSupport: Sendable, Codable, Equatable {
    /// The most keyframes one request can carry (an endpoints surface: 2).
    public let maxCount: Int
    public let placement: VideoKeyframePlacement
    /// `VideoKeyframe.strength` is honored. Without it a `strength` is refused (a weaker hold the
    /// caller asked for would silently become a full one).
    public let supportsStrength: Bool

    public init(maxCount: Int = 2, placement: VideoKeyframePlacement = .endpoints,
                supportsStrength: Bool = false) {
        self.maxCount = maxCount
        self.placement = placement
        self.supportsStrength = supportsStrength
    }

    private enum CodingKeys: String, CodingKey { case maxCount, placement, supportsStrength }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxCount = try c.decodeIfPresent(Int.self, forKey: .maxCount) ?? 2
        placement = try c.decodeIfPresent(VideoKeyframePlacement.self, forKey: .placement) ?? .endpoints
        supportsStrength = try c.decodeIfPresent(Bool.self, forKey: .supportsStrength) ?? false
    }
}

extension T2VControls {
    /// Why this surface cannot take the 1.61.0 levers of `request` — keyframes and the audio switch —
    /// or nil when it can. `initAudio` keeps its own engine check (1.40.0). A surface that declares no
    /// controls refuses every one of them: `T2VControls().refusal(for:)`.
    public func refusal(for request: T2VRequest) -> String? {
        if !request.keyframes.isEmpty {
            guard let support = keyframes else {
                return "keyframes — this surface declares no keyframe conditioning (T2VControls.keyframes); "
                    + "the frames would be ignored and the clip never reach them, so choose a package that "
                    + "declares keyframes, or use initImage for the first frame"
            }
            if request.keyframes.count > support.maxCount {
                return "keyframes — \(request.keyframes.count) in the request, this surface takes at most "
                    + "\(support.maxCount) (VideoKeyframeSupport.maxCount)"
            }
            var seen: Set<Int> = []
            for keyframe in request.keyframes {
                if support.placement == .endpoints, keyframe.frame != 0, keyframe.frame != -1 {
                    return "keyframes(frame \(keyframe.frame)) — this surface pins only the first (0) and "
                        + "last (-1) frame (VideoKeyframeSupport.placement: endpoints)"
                }
                if let strength = keyframe.strength {
                    guard support.supportsStrength else {
                        return "keyframes(frame \(keyframe.frame)).strength — this surface declares no "
                            + "keyframe strength (VideoKeyframeSupport.supportsStrength); drop it"
                    }
                    guard strength.isFinite, (0...1).contains(strength) else {
                        return "keyframes(frame \(keyframe.frame)).strength(\(strength)) — must be 0…1"
                    }
                }
                var index = keyframe.frame
                if let count = request.numFrames {
                    guard let resolved = keyframe.resolvedFrame(in: count) else {
                        return "keyframes(frame \(keyframe.frame)) — outside the \(count) frames requested"
                    }
                    index = resolved
                }
                if !seen.insert(index).inserted {
                    return "keyframes(frame \(keyframe.frame)) — two keyframes name the same frame"
                }
            }
            if request.initImage != nil {
                let pinsOpeningFrame = request.keyframes.contains { keyframe in
                    if keyframe.frame == 0 { return true }
                    guard let count = request.numFrames else { return false }
                    return keyframe.resolvedFrame(in: count) == 0
                }
                if pinsOpeningFrame {
                    return "keyframes(frame 0) with initImage — both pin the opening frame; name it once"
                }
            }
        }
        if let includeAudio = request.includeAudio {
            switch audioOutput {
            case nil:
                return "includeAudio — this surface declares no audio output (T2VControls.audioOutput)"
            case .silent where includeAudio:
                return "includeAudio(true) — this surface is silent (T2VControls.audioOutput: silent); "
                    + "it cannot return a soundtrack"
            case .always where !includeAudio:
                return "includeAudio(false) — this surface's audio is part of the generation "
                    + "(T2VControls.audioOutput: always); drop the track from the result instead"
            default:
                break
            }
        }
        return nil
    }
}

// MARK: - videoUpscale: content

/// What a **`videoUpscale`** surface honors beyond the scale — optional (`SurfaceControls.
/// videoUpscale`, read via `ToolDescriptor.videoUpscaleControls`).
public struct VideoUpscaleControls: Sendable, Codable, Equatable {
    /// The content kinds this surface upscales for. Non-empty ⇔ `VideoUpscaleRequest.content` is
    /// honored, and the engine refuses a kind not listed: an upscaler told "drawn" that ignored it ran
    /// the live-action model. A package that serves both with one network lists both.
    public let contents: [VideoContent]
    /// The package emits `RunPreviewFrame`s (per finished frame). OUTPUT-side; nothing to refuse.
    public let emitsFramePreviews: Bool

    public init(contents: [VideoContent] = [], emitsFramePreviews: Bool = false) {
        self.contents = contents
        self.emitsFramePreviews = emitsFramePreviews
    }

    private enum CodingKeys: String, CodingKey { case contents, emitsFramePreviews }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contents = try c.decodeIfPresent([VideoContent].self, forKey: .contents) ?? []
        emitsFramePreviews = try c.decodeIfPresent(Bool.self, forKey: .emitsFramePreviews) ?? false
    }

    public func refusal(for request: VideoUpscaleRequest) -> String? {
        guard let content = request.content else { return nil }
        guard !contents.isEmpty else {
            return "content(.\(content.rawValue)) — this surface declares no content control "
                + "(VideoUpscaleControls.contents); it would upscale with its one model whatever the "
                + "footage, so choose a package that declares content"
        }
        guard contents.contains(content) else {
            return "content(.\(content.rawValue)) — not one of the content kinds this surface declares "
                + "(VideoUpscaleControls.contents: " + contents.map(\.rawValue).joined(separator: " / ") + ")"
        }
        return nil
    }
}

// MARK: - frameInterpolate: target frame rate

/// Which output rates a target frame rate may name.
public enum FrameRateRatios: String, Sendable, Codable, CaseIterable {
    /// The target must be a whole multiple of the source rate (24 → 48, 72, 96).
    case integerMultiples
    /// Any rate above the source (RIFE's arbitrary timestep: 24 → 60).
    case any
}

/// The target frame rate a `frameInterpolate` surface honors — `FrameInterpolateControls.
/// targetFrameRate`.
public struct TargetFrameRateSupport: Sendable, Codable, Equatable {
    public let ratios: FrameRateRatios
    /// The highest output rate. Engine-enforced; nil = unstated.
    public let maxFrameRate: Double?

    public init(ratios: FrameRateRatios = .any, maxFrameRate: Double? = nil) {
        self.ratios = ratios
        self.maxFrameRate = maxFrameRate
    }

    private enum CodingKeys: String, CodingKey { case ratios, maxFrameRate }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratios = try c.decodeIfPresent(FrameRateRatios.self, forKey: .ratios) ?? .any
        maxFrameRate = try c.decodeIfPresent(Double.self, forKey: .maxFrameRate)
    }
}

/// What a **`frameInterpolate`** surface honors beyond the integer factor — optional
/// (`SurfaceControls.frameInterpolate`, read via `ToolDescriptor.frameInterpolateControls`).
public struct FrameInterpolateControls: Sendable, Codable, Equatable {
    /// Non-nil ⇔ `FrameInterpolateRequest.targetFrameRate` is honored.
    public let targetFrameRate: TargetFrameRateSupport?
    /// The package emits `RunPreviewFrame`s (per finished frame). OUTPUT-side; nothing to refuse.
    public let emitsFramePreviews: Bool

    public init(targetFrameRate: TargetFrameRateSupport? = nil, emitsFramePreviews: Bool = false) {
        self.targetFrameRate = targetFrameRate
        self.emitsFramePreviews = emitsFramePreviews
    }

    private enum CodingKeys: String, CodingKey { case targetFrameRate, emitsFramePreviews }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetFrameRate = try c.decodeIfPresent(TargetFrameRateSupport.self, forKey: .targetFrameRate)
        emitsFramePreviews = try c.decodeIfPresent(Bool.self, forKey: .emitsFramePreviews) ?? false
    }

    public func refusal(for request: FrameInterpolateRequest) -> String? {
        guard let target = request.targetFrameRate else { return nil }
        if request.factor != nil {
            return "targetFrameRate and factor — a request names one or the other"
        }
        guard let support = targetFrameRate else {
            return "targetFrameRate — this surface declares no target frame rate "
                + "(FrameInterpolateControls.targetFrameRate); send an integer factor instead"
        }
        guard target.isFinite, target > 0 else {
            return "targetFrameRate(\(VEditControls.format(target))) — must be a finite rate > 0"
        }
        if let limit = support.maxFrameRate, target > limit {
            return "targetFrameRate(\(VEditControls.format(target))) — this surface interpolates to at most "
                + "\(VEditControls.format(limit)) fps (TargetFrameRateSupport.maxFrameRate)"
        }
        if let source = request.video.frameRate, source > 0 {
            if target < source {
                return "targetFrameRate(\(VEditControls.format(target))) — below the source's "
                    + "\(VEditControls.format(source)) fps; interpolation raises the rate"
            }
            let ratio = target / source
            if support.ratios == .integerMultiples, abs(ratio - ratio.rounded()) > 1e-3 {
                return "targetFrameRate(\(VEditControls.format(target))) — not a whole multiple of the "
                    + "source's \(VEditControls.format(source)) fps "
                    + "(TargetFrameRateSupport.ratios: integerMultiples)"
            }
        }
        return nil
    }
}
