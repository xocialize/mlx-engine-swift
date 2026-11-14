//
//  CharacterPartContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.63.0 (AB-A-0277) — the characterPart capability: a picture + box, or a point cloud, and
//  optionally a body → the part as a rigged item. The declaration is required; these pin the request
//  shape, the refusal rules, the descriptor and the wire forms. Offline.
//

import XCTest
@testable import MLXToolKit

final class CharacterPartContractTests: XCTestCase {
    private let picture = Image(format: .png, data: Data([1, 2, 3]), width: 1024, height: 1536)
    private let cloud = PointCloud(data: Data([4, 5, 6]), pointCount: 10_000, hasNormals: true)
    private let vrm = Mesh(data: Data([7, 8, 9]))
    private let headBox: [Float] = [310, 120, 720, 640]

    /// The HairDeck declaration: both sources, the caller's head box, body fit, chains and colours.
    private let hairDeck = CharacterPartControls(
        parts: [.hair], inputs: [.image, .pointCloud],
        features: [.subjectBox, .bodyFit, .springBones, .colors], requiresSubjectBox: true)
    /// A picture-only garment maker that finds the garment itself and returns it unfitted.
    private let garmentOnly = CharacterPartControls(parts: [.garment, .accessory], inputs: [.image])

    func testCharacterPartIsACapabilityWithMeshOutput() {
        XCTAssertEqual(Capability.characterPart.canonicalOutput, .mesh)
        XCTAssertEqual(CharacterPartRequest.capability, .characterPart)
        XCTAssertEqual(ContractVersion.current, SemanticVersion(major: 1, minor: 63, patch: 0))
        XCTAssertTrue(Specialty.characterHair.isRegistered)
    }

    func testBothHairDeckSourcesPass() {
        XCTAssertTrue(hairDeck.declarationProblems.isEmpty)
        let fromPicture = CharacterPartRequest(image: picture, subjectBox: headBox, body: vrm, seed: 7,
                                               springBones: false, colors: true)
        XCTAssertEqual(fromPicture.input, .image)
        XCTAssertNil(hairDeck.refusal(for: fromPicture))
        let fromCloud = CharacterPartRequest(pointCloud: cloud, body: vrm)
        XCTAssertEqual(fromCloud.input, .pointCloud)
        XCTAssertNil(hairDeck.refusal(for: fromCloud))
        // No body is a valid request: the part comes back in the model's own frame.
        XCTAssertNil(hairDeck.refusal(for: CharacterPartRequest(pointCloud: cloud)))
        XCTAssertNil(hairDeck.refusal(for: CharacterPartRequest(image: picture, subjectBox: headBox, part: .hair)))
    }

    func testARequestCarriesExactlyOneSource() throws {
        let none = CharacterPartRequest(body: vrm)
        XCTAssertNil(none.input)
        XCTAssertTrue(try XCTUnwrap(hairDeck.refusal(for: none)).hasPrefix("no source"))
        let both = CharacterPartRequest(image: picture, subjectBox: headBox, pointCloud: cloud)
        XCTAssertNil(both.input)
        XCTAssertTrue(try XCTUnwrap(hairDeck.refusal(for: both)).hasPrefix("two sources"))
    }

    func testTheBoxIsFourPixelsEnclosingAnAreaAndBelongsToAPicture() throws {
        for bad: [Float] in [[1, 2, 3], [10, 10, 10, 50], [10, 50, 90, 50], [0, 0, .nan, 4], [9, 9, 1, 1]] {
            let refusal = hairDeck.refusal(for: CharacterPartRequest(image: picture, subjectBox: bad))
            XCTAssertTrue(try XCTUnwrap(refusal).hasPrefix("subjectBox — expected"), "\(bad)")
        }
        let boxOfACloud = CharacterPartRequest(subjectBox: headBox, pointCloud: cloud)
        XCTAssertTrue(try XCTUnwrap(boxOfACloud.shapeProblem).hasPrefix("subjectBox — a box is in the pixels"))
    }

    func testEachLeverNeedsItsDeclaration() throws {
        // The required box.
        XCTAssertTrue(try XCTUnwrap(hairDeck.refusal(for: CharacterPartRequest(image: picture)))
            .hasPrefix("subjectBox — this surface needs the box"))
        // A box, a body, physics and colours on a surface that declares none of them.
        XCTAssertNil(garmentOnly.refusal(for: CharacterPartRequest(image: picture)))
        XCTAssertTrue(try XCTUnwrap(garmentOnly.refusal(for: CharacterPartRequest(image: picture, subjectBox: headBox)))
            .hasPrefix("subjectBox — this surface locates the part itself"))
        XCTAssertTrue(try XCTUnwrap(garmentOnly.refusal(for: CharacterPartRequest(image: picture, body: vrm)))
            .hasPrefix("body — this surface declares no body fitting"))
        XCTAssertTrue(try XCTUnwrap(garmentOnly.refusal(for: CharacterPartRequest(image: picture, springBones: true)))
            .hasPrefix("springBones —"))
        XCTAssertTrue(try XCTUnwrap(garmentOnly.refusal(for: CharacterPartRequest(image: picture, colors: true)))
            .hasPrefix("colors —"))
        // Asking for neither is satisfiable anywhere.
        XCTAssertNil(garmentOnly.refusal(for: CharacterPartRequest(image: picture, springBones: false, colors: false)))
        // An undeclared source and an undeclared part.
        XCTAssertTrue(try XCTUnwrap(garmentOnly.refusal(for: CharacterPartRequest(pointCloud: cloud)))
            .hasPrefix("pointCloud — this surface reads no point cloud"))
        XCTAssertTrue(try XCTUnwrap(garmentOnly.refusal(for: CharacterPartRequest(image: picture, part: .hair)))
            .hasPrefix("part(\"hair\") — not one of the parts"))
        XCTAssertNil(garmentOnly.refusal(for: CharacterPartRequest(image: picture, part: .accessory)))
        XCTAssertEqual(garmentOnly.defaultPart, .garment)
    }

    func testDeclarationProblemsNameIncoherence() {
        XCTAssertTrue(garmentOnly.declarationProblems.isEmpty)
        XCTAssertEqual(CharacterPartControls(parts: [], inputs: []).declarationProblems,
                       ["no parts are declared", "no inputs are declared"])
        XCTAssertEqual(CharacterPartControls(parts: [.hair, .hair], inputs: [.image]).declarationProblems,
                       ["parts lists a part twice"])
        XCTAssertEqual(CharacterPartControls(parts: [.hair], inputs: [.pointCloud], features: [.subjectBox])
            .declarationProblems, ["subjectBox is declared without the image input it is a box of"])
        XCTAssertEqual(CharacterPartControls(parts: [.hair], inputs: [.image], requiresSubjectBox: true)
            .declarationProblems, ["requiresSubjectBox is set without the subjectBox feature"])
    }

    func testDescriptorAdvertisesOnlyWhatItDeclares() throws {
        let hair = CharacterPartContract.descriptor(name: "hairdeck", summary: "s", controls: hairDeck)
        XCTAssertEqual(hair.capability, .characterPart)
        XCTAssertTrue(hair.controlsMatchCapability)
        XCTAssertEqual(hair.characterPartControls, hairDeck)
        XCTAssertEqual(hair.parameters.map(\.name),
                       ["image", "subjectBox", "pointCloud", "body", "seed", "springBones", "colors"])
        // Two sources: neither is required on its own, and so neither is the box.
        XCTAssertTrue(hair.parameters.allSatisfy { !$0.required })
        XCTAssertEqual(hair.parameters.first { $0.name == "pointCloud" }?.kind, .pointCloud)
        XCTAssertEqual(hair.parameters.first { $0.name == "body" }?.kind, .mesh)

        let garment = CharacterPartContract.descriptor(name: "garment", summary: "s", controls: garmentOnly)
        XCTAssertEqual(garment.parameters.map(\.name), ["image", "part", "seed"])
        XCTAssertEqual(garment.parameters.first?.required, true)

        let pictureHair = CharacterPartContract.descriptor(
            name: "h", summary: "s",
            controls: CharacterPartControls(parts: [.hair], inputs: [.image], features: [.subjectBox],
                                            requiresSubjectBox: true))
        XCTAssertEqual(pictureHair.parameters.first { $0.name == "subjectBox" }?.required, true)
    }

    func testControlsMustMatchTheSurfaceCapability() {
        let mismatched = ToolDescriptor(name: "i23d", capability: .imageTo3D, summary: "s",
                                        controls: .characterPart(hairDeck))
        XCTAssertFalse(mismatched.controlsMatchCapability)
        XCTAssertNil(ImageTo3DContract.descriptor(name: "i23d", summary: "s").characterPartControls)
    }

    func testDescriptorRequestAndResponseRoundTripOnTheWire() throws {
        let descriptor = CharacterPartContract.descriptor(name: "hairdeck", summary: "s", controls: hairDeck)
        XCTAssertEqual(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor)),
                       descriptor)

        XCTAssertTrue(CapabilityWire.requestType(for: .characterPart) == CharacterPartRequest.self)
        XCTAssertTrue(CapabilityWire.responseType(for: .characterPart) == CharacterPartResponse.self)
        let request = CharacterPartRequest(image: picture, subjectBox: headBox, body: vrm, part: .hair,
                                           seed: 42, springBones: true, colors: false,
                                           metaData: ["steps": .int(50)])
        let json = try CapabilityWire.encoder().encode(CapabilityRequestEnvelope(request, package: "hairdeck"))
        let decoded = try CapabilityWire.decoder().decode(CapabilityRequestEnvelope.self, from: json)
        XCTAssertEqual(decoded.capability, .characterPart)
        let typed = try XCTUnwrap(decoded.request as? CharacterPartRequest)
        XCTAssertEqual(typed.image, picture)
        XCTAssertEqual(typed.subjectBox, headBox)
        XCTAssertNil(typed.pointCloud)
        XCTAssertEqual(typed.body, vrm)
        XCTAssertEqual(typed.part, .hair)
        XCTAssertEqual(typed.seed, 42)
        XCTAssertEqual(typed.springBones, true)
        XCTAssertEqual(typed.colors, false)

        // A minimal request decodes from the two keys it needs.
        let minimal = try JSONDecoder().decode(
            CharacterPartRequest.self,
            from: Data(#"{"pointCloud":{"format":"ply","data":"BAUG","hasNormals":true},"metaData":{}}"#.utf8))
        XCTAssertEqual(minimal.pointCloud?.data, Data([4, 5, 6]))
        XCTAssertNil(minimal.body)

        let response = CharacterPartResponse(mesh: vrm, part: .hair, fittedToBody: true)
        let back = try JSONDecoder().decode(CharacterPartResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(back.mesh, vrm)
        XCTAssertEqual(back.part, .hair)
        XCTAssertTrue(back.fittedToBody)
    }

    func testPointCloudRoundTripsAndCarriesItsFacts() throws {
        let back = try JSONDecoder().decode(PointCloud.self, from: JSONEncoder().encode(cloud))
        XCTAssertEqual(back, cloud)
        XCTAssertEqual(back.format, .ply)
        XCTAssertEqual(back.pointCount, 10_000)
        XCTAssertTrue(back.hasNormals)
        XCTAssertFalse(PointCloud(data: Data()).hasNormals)
    }
}
