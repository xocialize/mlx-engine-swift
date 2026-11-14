import Foundation

// Character part (contract 1.63.0, AB-A-0277) — a reference of one part of a character, and
// optionally the body it goes on, → that part as a rigged, placed item (GLB).
//
// Introduced by HairDeck (`mlx-hairdeck-swift`): one character picture + the head box → hair cards
// with per-card colours, chain bones and a `VRMC_springBone` block, placed on a VRM's head; or the
// same from a 10,000-point cloud of the hairstyle. The slot is shaped for the next body-fitted part
// generators too (garments, accessories), which share the two things neither `imageTo3D` nor
// `meshRig` has: "the body it goes on" as an input, and a rigged part as the output.

/// Which part of a character a surface makes. An open tag (the `Mode` / `Specialty` governance): the
/// contract carries the plane and names the first terms; a package declares the ones it makes in
/// `CharacterPartControls.parts`.
public struct CharacterPartKind: RawRepresentable, Sendable, Codable, Equatable, Hashable,
                                 ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// Hair, hung on the head bone (HairDeck).
    public static let hair: CharacterPartKind = "hair"
    /// Clothing worn on the body.
    public static let garment: CharacterPartKind = "garment"
    /// A rigid or semi-rigid attachment (glasses, a hat, a bag).
    public static let accessory: CharacterPartKind = "accessory"
}

/// What a part can be generated FROM. A surface declares the ones it reads
/// (`CharacterPartControls.inputs`); a request carries exactly one.
public enum CharacterPartInput: String, Sendable, Codable, CaseIterable {
    /// `CharacterPartRequest.image` — a picture of the character wearing the part.
    case image
    /// `CharacterPartRequest.pointCloud` — a point cloud of the part's shape.
    case pointCloud
}

/// The optional levers of the character-part surface a package declares
/// (`CharacterPartControls.features`). A host renders a form element per declared feature; the engine
/// refuses an undeclared one before admission.
public enum CharacterPartFeature: String, Sendable, Codable, CaseIterable {
    /// `CharacterPartRequest.subjectBox` is honored: the caller says where in the picture the part is
    /// read from (for hair, the head). A surface that locates it itself does not declare this, and a
    /// box sent to it is refused — an ignored box is the wrong head in a picture with two.
    case subjectBox
    /// `CharacterPartRequest.body` is honored: the part comes back placed on that body and skinned to
    /// its bones (`CharacterPartResponse.fittedToBody == true`). Without it a surface returns the
    /// part in its own frame only, and a body sent to it is refused.
    case bodyFit
    /// The item can carry secondary-motion physics (`VRMC_springBone` chains), switched per request
    /// by `CharacterPartRequest.springBones`. Undeclared = the surface never emits them, and asking
    /// for them is refused.
    case springBones
    /// The item can carry the part's colours read from the source (a texture or vertex colours),
    /// switched per request by `CharacterPartRequest.colors`. Undeclared = the surface returns
    /// uncoloured geometry, and asking for colours is refused.
    case colors
}

/// What a **`characterPart`** surface can do (contract 1.63.0): the routing-time declaration a host
/// reads to choose a package and build the form, and the engine reads to refuse what the form should
/// not have offered.
///
/// Required on every character-part surface (`CharacterPartContract.descriptor(controls:)` will not
/// build one without it — the `speechEdit` / `music` precedent): a consumer must know BEFORE it runs
/// whether this package makes hair or clothes and whether it reads a picture or a cloud, and none of
/// that is learnable from a response.
public struct CharacterPartControls: Sendable, Codable, Equatable {
    /// The parts this surface makes, non-empty. The FIRST is the default: a request with a nil
    /// `part` gets it.
    public let parts: [CharacterPartKind]
    /// The sources this surface reads, non-empty.
    public let inputs: Set<CharacterPartInput>
    /// The optional levers this surface honors. `seed` is core and never declared.
    public let features: Set<CharacterPartFeature>
    /// An image request must carry `subjectBox` (HairDeck: the head box is the caller's, AB-D-0227).
    /// Engine-enforced. Needs `.subjectBox` and `.image` declared (`declarationProblems`).
    public let requiresSubjectBox: Bool

    public init(parts: [CharacterPartKind],
                inputs: Set<CharacterPartInput>,
                features: Set<CharacterPartFeature> = [],
                requiresSubjectBox: Bool = false) {
        self.parts = parts
        self.inputs = inputs
        self.features = features
        self.requiresSubjectBox = requiresSubjectBox
    }

    public func declares(_ feature: CharacterPartFeature) -> Bool { features.contains(feature) }

    /// The part a request with a nil `part` gets (`parts.first`).
    public var defaultPart: CharacterPartKind? { parts.first }

    /// Internal inconsistencies of the declaration. Empty for a coherent one. A package's manifest
    /// test asserts this is empty (the C11 "honest descriptor" expectation).
    public var declarationProblems: [String] {
        var problems: [String] = []
        if parts.isEmpty { problems.append("no parts are declared") }
        if Set(parts).count != parts.count { problems.append("parts lists a part twice") }
        if parts.contains(where: { $0.rawValue.isEmpty }) { problems.append("parts lists an empty tag") }
        if inputs.isEmpty { problems.append("no inputs are declared") }
        if declares(.subjectBox), !inputs.contains(.image) {
            problems.append("subjectBox is declared without the image input it is a box of")
        }
        if requiresSubjectBox, !declares(.subjectBox) {
            problems.append("requiresSubjectBox is set without the subjectBox feature")
        }
        return problems
    }

    /// Why this surface cannot take `request`, or nil when it can. The engine's pre-flight throws it
    /// as `PackageError.unsupportedRequestFeature` before admission; a package driven directly may
    /// call it first for the same refusal. Checks the request's own shape (exactly one source, a
    /// well-formed box) and then only what an ignored field would make WRONG.
    public func refusal(for request: CharacterPartRequest) -> String? {
        if let problem = request.shapeProblem { return problem }

        if request.image != nil, !inputs.contains(.image) {
            return "image — this surface reads no picture (CharacterPartControls.inputs: "
                + inputList + "); choose a package that declares the image input"
        }
        if request.pointCloud != nil, !inputs.contains(.pointCloud) {
            return "pointCloud — this surface reads no point cloud (CharacterPartControls.inputs: "
                + inputList + "); choose a package that declares the pointCloud input"
        }
        if request.subjectBox != nil, !declares(.subjectBox) {
            return "subjectBox — this surface locates the part itself and declares no box "
                + "(CharacterPartControls.features); drop it, or crop the picture to the subject"
        }
        if request.image != nil, request.subjectBox == nil, requiresSubjectBox {
            return "subjectBox — this surface needs the box the part is read from, in source pixels "
                + "[x0, y0, x1, y1] (CharacterPartControls.requiresSubjectBox); it does not locate it"
        }
        if request.body != nil, !declares(.bodyFit) {
            return "body — this surface declares no body fitting (CharacterPartControls.features); "
                + "the part would come back in the model's own frame, so drop the body and place it "
                + "yourself, or choose a package that declares bodyFit"
        }
        if let part = request.part, !parts.contains(part) {
            return "part(\"\(part.rawValue)\") — not one of the parts this surface makes "
                + "(CharacterPartControls.parts: " + parts.map(\.rawValue).joined(separator: " / ") + ")"
        }
        if request.springBones == true, !declares(.springBones) {
            return "springBones — this surface emits no spring-bone physics "
                + "(CharacterPartControls.features); drop it, or choose a package that declares springBones"
        }
        if request.colors == true, !declares(.colors) {
            return "colors — this surface returns uncoloured geometry (CharacterPartControls.features); "
                + "drop it, or choose a package that declares colors"
        }
        return nil
    }

    private var inputList: String { inputs.map(\.rawValue).sorted().joined(separator: " / ") }
}

/// Canonical **character part** request (contract 1.63.0, AB-A-0277). Introduced for HairDeck.
///
/// ONE source — `image` or `pointCloud`, never both, never neither — and optionally the `body` the
/// part goes on. Both sources are fields of this one request rather than modes or two capabilities:
/// a `Mode` selects different output semantics for the SAME input artifacts (C4), and here the input
/// differs while the output is the same item; a consumer that wants "hair for this avatar" should
/// find one surface and read from its declaration which sources the package takes.
///
/// Everything a usable result needs is a typed field. `metaData` is for package-only levers (a step
/// count, a card budget) — never the box or the body (C5).
public struct CharacterPartRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .characterPart }

    /// A picture of the character wearing the part. Background removal is package-internal
    /// preprocessing (the shipped BiRefNet `matting`), not a request field — the `imageTo3D` rule.
    public let image: Image?
    /// Where in `image` the part is read from, `[x0, y0, x1, y1]` in SOURCE-IMAGE pixels, origin
    /// top-left, `x1 > x0` and `y1 > y0` (the `PromptSegmentRequest.box` convention). For hair it is
    /// the HEAD box (hair and face), not the hair alone. Needs `.subjectBox`; required where the
    /// surface says so (`requiresSubjectBox`). Only meaningful with `image`.
    public let subjectBox: [Float]?
    /// A point cloud of the part's shape (PLY). The package states the count and whether it needs
    /// normals in its descriptor summary, and refuses a cloud it cannot read.
    public let pointCloud: PointCloud?
    /// The body the part goes on: the avatar's VRM, or any rigged GLB with the bones the part hangs
    /// from. The package reads what it needs from the file (for hair: the head bone and the face
    /// bounds) and returns the part placed on that body, skinned to bones NAMED as the body's are.
    /// Nil → the part in the model's own frame (`fittedToBody == false`). Needs `.bodyFit`. Read
    /// only: the body is never modified or returned.
    public let body: Mesh?
    /// Which part to make. Nil → the surface's default (`CharacterPartControls.parts.first`).
    public let part: CharacterPartKind?
    /// Generation seed. Core: every surface honors it. Nil → the package picks one.
    public let seed: UInt64?
    /// Emit secondary-motion physics (`VRMC_springBone` chains and their bones). Nil → the surface's
    /// default (on where `.springBones` is declared). `true` on a surface that declares none is refused.
    public let springBones: Bool?
    /// Carry the part's colours read from the source. Nil → the surface's default (on where `.colors`
    /// is declared). `true` on a surface that declares none is refused.
    public let colors: Bool?
    public let mode: Mode?
    public let metaData: MetaData

    public init(image: Image? = nil,
                subjectBox: [Float]? = nil,
                pointCloud: PointCloud? = nil,
                body: Mesh? = nil,
                part: CharacterPartKind? = nil,
                seed: UInt64? = nil,
                springBones: Bool? = nil,
                colors: Bool? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.image = image
        self.subjectBox = subjectBox
        self.pointCloud = pointCloud
        self.body = body
        self.part = part
        self.seed = seed
        self.springBones = springBones
        self.colors = colors
        self.mode = mode
        self.metaData = metaData
    }

    /// The source this request carries, or nil when it carries none or both (`shapeProblem`).
    public var input: CharacterPartInput? {
        switch (image != nil, pointCloud != nil) {
        case (true, false): return .image
        case (false, true): return .pointCloud
        default: return nil
        }
    }

    /// What is wrong with the request on ANY surface, or nil: no source, two sources, a box without
    /// a picture, a box that is not four finite numbers enclosing an area.
    public var shapeProblem: String? {
        if image == nil, pointCloud == nil {
            return "no source — a character-part request carries an image or a pointCloud"
        }
        if image != nil, pointCloud != nil {
            return "two sources — a character-part request carries an image OR a pointCloud, not both"
        }
        if let box = subjectBox {
            if image == nil {
                return "subjectBox — a box is in the pixels of an image, and this request carries none"
            }
            guard box.count == 4, box.allSatisfy(\.isFinite), box[2] > box[0], box[3] > box[1] else {
                return "subjectBox — expected [x0, y0, x1, y1] in source pixels with x1 > x0 and y1 > y0"
            }
        }
        return nil
    }
}

/// Canonical **character part** response: the part as an ITEM.
///
/// The `mesh` is a GLB holding the part alone — its geometry and materials, a skin whose joints
/// include the bone(s) of the body it hangs from, named as on the body and at the body's rest pose
/// when fitted, any bones of its own beneath them, and a `VRMC_springBone` extension when physics
/// was emitted. It is not an avatar: merging the item into the body's file is the consumer's step.
public struct CharacterPartResponse: CapabilityResponse, Codable {
    public let mesh: Mesh
    /// The part that was made (the request's, or the surface's default).
    public let part: CharacterPartKind
    /// Whether the item is placed on the request's `body` (true) or left in the model's own frame
    /// (false — no body was given). Stated here so a consumer holding only the response can tell.
    public let fittedToBody: Bool

    public init(mesh: Mesh, part: CharacterPartKind, fittedToBody: Bool) {
        self.mesh = mesh
        self.part = part
        self.fittedToBody = fittedToBody
    }
}

/// The canonical descriptor for a character-part tool. The declaration is required, and only what it
/// declares is advertised, so a planner is never offered a parameter the engine would refuse.
public enum CharacterPartContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  controls: CharacterPartControls) -> ToolDescriptor {
        var parameters: [ParameterSchema] = []
        let readsImage = controls.inputs.contains(.image)
        let readsCloud = controls.inputs.contains(.pointCloud)
        if readsImage {
            parameters.append(ParameterSchema(
                name: "image", kind: .image, required: !readsCloud,
                summary: "A picture of the character wearing the part."
                    + (readsCloud ? " Send this or pointCloud, not both." : "")))
        }
        if controls.declares(.subjectBox) {
            parameters.append(ParameterSchema(
                name: "subjectBox", kind: .array, required: controls.requiresSubjectBox && !readsCloud,
                summary: "Where in the image the part is read from, [x0,y0,x1,y1] in source pixels "
                    + "(for hair: the head box)."
                    + (controls.requiresSubjectBox ? " Required with an image." : "")))
        }
        if readsCloud {
            parameters.append(ParameterSchema(
                name: "pointCloud", kind: .pointCloud, required: !readsImage,
                summary: "A point cloud (PLY) of the part's shape."
                    + (readsImage ? " Send this or image, not both." : "")))
        }
        if controls.declares(.bodyFit) {
            parameters.append(ParameterSchema(
                name: "body", kind: .mesh, required: false,
                summary: "The body the part goes on (a VRM or rigged GLB); the part comes back placed "
                    + "on it. Omit for the part in the model's own frame."))
        }
        if controls.parts.count > 1 {
            parameters.append(ParameterSchema(
                name: "part", kind: .string, required: false,
                summary: "Which part to make: "
                    + controls.parts.map { "\"\($0.rawValue)\"" }.joined(separator: " / ")
                    + ". Default \"\(controls.parts[0].rawValue)\"."))
        }
        parameters.append(ParameterSchema(name: "seed", kind: .integer, required: false,
                                          summary: "Generation seed."))
        if controls.declares(.springBones) {
            parameters.append(ParameterSchema(
                name: "springBones", kind: .boolean, required: false,
                summary: "Emit spring-bone physics chains (VRMC_springBone). Default on."))
        }
        if controls.declares(.colors) {
            parameters.append(ParameterSchema(
                name: "colors", kind: .boolean, required: false,
                summary: "Carry the part's colours read from the source. Default on."))
        }
        return ToolDescriptor(name: name, capability: .characterPart, summary: summary,
                              parameters: parameters, supportedModes: modes,
                              controls: .characterPart(controls))
    }
}
