import Foundation

// Image locate (contract 1.66.0, AB-A-0295): a picture + a phrase → where the things the phrase
// names are, as typed boxes, best first.
//
// Introduced for MES `image.locate` (media-engine-spec RFC 0010) and its first provider,
// `mlx-locate-swift` (Qwen3-VL-4B). Before this, the provider served `imageAnalysis` with the boxes
// as JSON in `ImageAnalysisResponse.text` and the cap in `metaData["count"]`: untyped output and a
// C5 lever. The box geometry is MES's (Image §1.11): shares of the upright image from its top-left
// corner, so a client hands the result to MES or to another surface without knowing pixel sizes.

/// One thing an `imageLocate` surface found: its box, what the model calls it, and how sure it is.
///
/// The box is in SHARES of the upright image (EXIF orientation applied) from its top-left corner:
/// `x`, `y`, `width`, `height` each 0 to 1, `width` and `height` above 0, `x + width` and
/// `y + height` at most 1 (`shapeProblem`). This differs on purpose from the pixel boxes of
/// `PromptSegmentRequest.box` and `CharacterPartRequest.subjectBox`: a located box goes to clients
/// that may never see the decoded pixels. `pixelCorners(width:height:)` converts to those.
public struct ImageLocateBox: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// What the box holds, in the prompt's words, where the model says which of several things it
    /// found ("the left eye"). Optional: a model that points at one thing has none to give.
    public let label: String?
    /// The model's confidence, 0 to 1. On every box where the surface declares scores
    /// (`ImageLocateControls.scores`), on none where it does not — never an invented 1.0.
    public let score: Double?

    public init(x: Double, y: Double, width: Double, height: Double,
                label: String? = nil, score: Double? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.label = label
        self.score = score
    }

    /// Tolerance for `x + width <= 1` after float arithmetic on the provider's side.
    static let edgeSlack = 1e-6

    /// What is wrong with this box, or nil: a number that is not finite, a corner outside the
    /// image, no area, a score outside 0…1.
    public var shapeProblem: String? {
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            return "a box has a coordinate that is not a finite number"
        }
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1 + Self.edgeSlack, y + height <= 1 + Self.edgeSlack else {
            return "a box is not inside the image with some area (x, y, width, height are shares "
                + "of the upright image from its top-left corner, width and height above 0, "
                + "x + width and y + height at most 1)"
        }
        if let score, !(score.isFinite && (0...1).contains(score)) {
            return "a box's score is outside 0…1"
        }
        return nil
    }

    /// The part of the box inside the image, or nil when none of it is or it has no area. Label and
    /// score carry over, the score held to 0…1.
    public var clipped: ImageLocateBox? {
        guard [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        let x0 = min(1, max(0, x)), y0 = min(1, max(0, y))
        let x1 = min(1, max(0, x + width)), y1 = min(1, max(0, y + height))
        guard x1 > x0, y1 > y0 else { return nil }
        let held = score.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        return ImageLocateBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0, label: label, score: held)
    }

    /// The box as `[x0, y0, x1, y1]` in pixels of an upright image `width` × `height` — the
    /// convention of `PromptSegmentRequest.box` and `CharacterPartRequest.subjectBox`, so a head
    /// located here can be handed to a character-part surface.
    public func pixelCorners(width imageWidth: Int, height imageHeight: Int) -> [Float] {
        let w = Double(imageWidth), h = Double(imageHeight)
        return [Float(x * w), Float(y * h), Float((x + width) * w), Float((y + height) * h)]
    }

    /// Intersection over union with another box, 0 to 1.
    public func overlap(_ other: ImageLocateBox) -> Double {
        let w = min(x + width, other.x + other.width) - max(x, other.x)
        let h = min(y + height, other.y + other.height) - max(y, other.y)
        guard w > 0, h > 0 else { return 0 }
        let both = w * h, either = width * height + other.width * other.height - both
        return either > 0 ? both / either : 0
    }

    /// What a provider's raw boxes become before they are returned (MES Image §3.4, the rule
    /// MESKit's `LocatedBox.served` applies): each clipped to the image, those left with no area
    /// dropped, the list in descending score (the provider's order among equal or absent scores),
    /// at most `count`. A package may return `ImageLocateResponse(boxes: .served(raw, count:))`.
    public static func served(_ boxes: [ImageLocateBox], count: Int) -> [ImageLocateBox] {
        let kept = boxes.compactMap(\.clipped)
        let ordered = kept.enumerated().sorted { a, b in
            let (sa, sb) = (a.element.score ?? -1, b.element.score ?? -1)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
        return Array(ordered.prefix(max(0, count)))
    }
}

extension Array where Element == ImageLocateBox {
    /// `ImageLocateBox.served(self, count:)`.
    public func served(count: Int) -> [ImageLocateBox] { ImageLocateBox.served(self, count: count) }
}

/// What an **`imageLocate`** surface can do (contract 1.66.0): how many boxes it returns and whether
/// it scores them. MES reads these as an offer's `limits.max_count` and `supports.scores` /
/// `supports.seed`.
///
/// Required on every locate surface (`ImageLocateContract.descriptor(controls:)` will not build one
/// without it, the `characterPart` precedent): a host must know before it runs how many boxes it
/// may ask for, and whether it can rank or threshold them.
public struct ImageLocateControls: Sendable, Codable, Equatable {
    /// The most boxes one request may ask for, at least 1. A model that points at one thing declares
    /// 1. A request's `count` above it is refused before admission (MES: 422 `out_of_limits`).
    public let maxCount: Int
    /// Every returned box carries a `score` (true) or none does (false).
    public let scores: Bool
    /// The result depends on `ImageLocateRequest.seed` (a sampled decode). False: the surface is
    /// deterministic and a seed changes nothing (it is accepted and ignored, never refused).
    public let seeded: Bool

    public init(maxCount: Int, scores: Bool, seeded: Bool = false) {
        self.maxCount = maxCount
        self.scores = scores
        self.seeded = seeded
    }

    /// Internal inconsistencies of the declaration. Empty for a coherent one. A package's manifest
    /// test asserts this is empty (C11).
    public var declarationProblems: [String] {
        maxCount < 1 ? ["maxCount is \(maxCount); a locate surface returns at least one box"] : []
    }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it
    /// as `PackageError.unsupportedRequestFeature` before admission; a package driven directly may
    /// call it first for the same refusal.
    public func refusal(for request: ImageLocateRequest) -> String? {
        if let problem = request.shapeProblem { return problem }
        if request.effectiveCount > maxCount {
            return "count(\(request.effectiveCount)) — this surface returns at most \(maxCount) "
                + "box\(maxCount == 1 ? "" : "es") (ImageLocateControls.maxCount); ask for fewer, "
                + "or choose a package that declares more"
        }
        return nil
    }

    /// What is wrong with a response to `request` from this surface, empty when nothing is: a
    /// malformed box, more boxes than asked, scores on a surface that declares none or missing on one
    /// that declares them, an order other than descending score. The package conformance check
    /// (C2) for an `imageLocate` surface; an empty list is a success, never a problem.
    public func responseProblems(_ response: ImageLocateResponse,
                                 for request: ImageLocateRequest) -> [String] {
        var problems: [String] = []
        let boxes = response.boxes
        if let shape = boxes.lazy.compactMap(\.shapeProblem).first { problems.append(shape) }
        if boxes.count > request.effectiveCount {
            problems.append("\(boxes.count) boxes for a count of \(request.effectiveCount)")
        }
        let scored = boxes.filter { $0.score != nil }.count
        if scores, scored != boxes.count {
            problems.append("the surface declares scores, and \(boxes.count - scored) of "
                + "\(boxes.count) boxes carry none")
        }
        if !scores, scored > 0 {
            problems.append("the surface declares no scores, and \(scored) boxes carry one")
        }
        let ranked = boxes.compactMap(\.score)
        if ranked.count == boxes.count, zip(ranked, ranked.dropFirst()).contains(where: { $0 < $1 }) {
            problems.append("the boxes are not in descending score")
        }
        return problems
    }
}

/// Canonical **image locate** request (contract 1.66.0, AB-A-0295): a picture and what to find in it.
///
/// Every lever MES's `image.locate` has is a typed field; `metaData` is for package-only levers (an
/// input resolution), never the count (C5).
public struct ImageLocateRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .imageLocate }

    /// The picture. Coordinates in the response are shares of it UPRIGHT (EXIF orientation applied).
    public let image: Image
    /// What to find, in a person's words: "the character's head including the hair", "every window".
    /// Required and non-empty. The package's descriptor summary says which languages and kinds of
    /// things its model understands.
    public let prompt: String
    /// The most boxes to return, at least 1. Nil → 1 (MES's default). Above the surface's
    /// `ImageLocateControls.maxCount` is refused.
    public let count: Int?
    /// Decode seed, where the surface is seeded (`ImageLocateControls.seeded`). Nil → the package
    /// picks one. Ignored, never refused, by a deterministic surface.
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image, prompt: String, count: Int? = nil, seed: UInt64? = nil,
                mode: Mode? = nil, metaData: MetaData = [:]) {
        self.image = image
        self.prompt = prompt
        self.count = count
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }

    /// The count that applies: `count`, or 1.
    public var effectiveCount: Int { count ?? 1 }

    /// What is wrong with the request on ANY surface, or nil: an empty prompt, a count below 1.
    public var shapeProblem: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "prompt — an image-locate request says what to find; it is empty"
        }
        if let count, count < 1 {
            return "count(\(count)) — the most boxes to return is at least 1"
        }
        return nil
    }
}

/// Canonical **image locate** response: the boxes, best first — in descending `score`, or without
/// scores in the model's own order, most likely first — at most the request's count.
///
/// **An empty list is a success** ("it is not there"), never an error, and a package must not
/// return a box it does not believe in to avoid one (MES: the job succeeds with `nothing_found`).
public struct ImageLocateResponse: CapabilityResponse, Codable {
    public let boxes: [ImageLocateBox]

    public init(boxes: [ImageLocateBox]) { self.boxes = boxes }

    /// Whether nothing was found.
    public var isEmpty: Bool { boxes.isEmpty }
}

/// The canonical descriptor for an image-locate tool. The declaration is required, and the count's
/// range and the seed are advertised from it.
public enum ImageLocateContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: ImageLocateControls) -> ToolDescriptor {
        var parameters: [ParameterSchema] = [
            ParameterSchema(name: "image", kind: .image, required: true,
                            summary: "The picture to look in."),
            ParameterSchema(name: "prompt", kind: .string, required: true,
                            summary: "What to find, in a person's words."),
        ]
        if controls.maxCount > 1 {
            parameters.append(ParameterSchema(
                name: "count", kind: .integer, required: false,
                summary: "The most boxes to return, 1 – \(controls.maxCount). Default 1."))
        }
        if controls.seeded {
            parameters.append(ParameterSchema(name: "seed", kind: .integer, required: false,
                                              summary: "Decode seed."))
        }
        return ToolDescriptor(name: name, capability: .imageLocate, summary: summary,
                              parameters: parameters, supportedModes: modes,
                              controls: .imageLocate(controls))
    }
}
