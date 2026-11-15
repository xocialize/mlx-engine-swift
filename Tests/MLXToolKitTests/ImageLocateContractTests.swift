//
//  ImageLocateContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.66.0 (AB-A-0295) — the imageLocate capability: a picture + a phrase (+ a count) →
//  typed boxes in shares of the upright image, best first, an empty list a success. Pins the request
//  and box shapes, the declaration and its refusals, the result check, the descriptor and the wire
//  forms (incl. MES's `LocatedBox` JSON). Offline.
//

import XCTest
@testable import MLXToolKit

final class ImageLocateContractTests: XCTestCase {
    private let picture = Image(format: .png, data: Data([1, 2, 3]), width: 1024, height: 1536)
    /// The mlx-locate-swift v0.1.0 shape: up to 16 boxes, scored, greedy (unseeded).
    private let locator = ImageLocateControls(maxCount: 16, scores: true)
    /// A pointer: one box, no score, sampled.
    private let pointer = ImageLocateControls(maxCount: 1, scores: false, seeded: true)

    func testImageLocateIsACapabilityWithStructuredOutput() {
        XCTAssertEqual(Capability.imageLocate.canonicalOutput, .structuredText)
        XCTAssertEqual(ImageLocateRequest.capability, .imageLocate)
        XCTAssertTrue(Capability.allCases.contains(.imageLocate))
        XCTAssertGreaterThanOrEqual(ContractVersion.current, SemanticVersion(major: 1, minor: 66, patch: 0))
    }

    func testRequestShapeAndDefaultCount() {
        let plain = ImageLocateRequest(image: picture, prompt: "the character's head including the hair")
        XCTAssertNil(plain.count)
        XCTAssertEqual(plain.effectiveCount, 1)
        XCTAssertNil(plain.shapeProblem)
        XCTAssertNotNil(ImageLocateRequest(image: picture, prompt: " \n").shapeProblem)
        XCTAssertNotNil(ImageLocateRequest(image: picture, prompt: "x", count: 0).shapeProblem)
        XCTAssertEqual(ImageLocateRequest(image: picture, prompt: "x", count: 5).effectiveCount, 5)
    }

    func testDeclarationAndRefusals() {
        XCTAssertTrue(locator.declarationProblems.isEmpty)
        XCTAssertTrue(pointer.declarationProblems.isEmpty)
        XCTAssertFalse(ImageLocateControls(maxCount: 0, scores: true).declarationProblems.isEmpty)

        XCTAssertNil(locator.refusal(for: ImageLocateRequest(image: picture, prompt: "windows", count: 16)))
        XCTAssertTrue(locator.refusal(for: ImageLocateRequest(image: picture, prompt: "windows", count: 17))?
            .hasPrefix("count(17) — this surface returns at most 16 boxes") ?? false)
        XCTAssertTrue(pointer.refusal(for: ImageLocateRequest(image: picture, prompt: "eyes", count: 2))?
            .contains("at most 1 box ") ?? false)
        // A seed on an unseeded surface is ignored, never refused.
        XCTAssertNil(locator.refusal(for: ImageLocateRequest(image: picture, prompt: "a", seed: 9)))
        XCTAssertNotNil(locator.refusal(for: ImageLocateRequest(image: picture, prompt: "")))
    }

    func testBoxShapeClipOverlapAndPixelCorners() {
        let head = ImageLocateBox(x: 0.31, y: 0.04, width: 0.38, height: 0.33, label: "head", score: 0.94)
        XCTAssertNil(head.shapeProblem)
        XCTAssertNil(ImageLocateBox(x: 0.5, y: 0, width: 0.5 + 1e-9, height: 1).shapeProblem)
        XCTAssertNotNil(ImageLocateBox(x: 0.5, y: 0, width: 0.6, height: 0.5).shapeProblem)
        XCTAssertNotNil(ImageLocateBox(x: 0.1, y: 0.1, width: 0, height: 0.5).shapeProblem)
        XCTAssertNotNil(ImageLocateBox(x: .nan, y: 0.1, width: 0.2, height: 0.5).shapeProblem)
        XCTAssertNotNil(ImageLocateBox(x: 0.1, y: 0.1, width: 0.2, height: 0.5, score: 1.2).shapeProblem)

        let off = ImageLocateBox(x: 0.8, y: -0.1, width: 0.4, height: 0.3, label: "l", score: 1.5)
        let clipped = try! XCTUnwrap(off.clipped)
        XCTAssertEqual(clipped.x, 0.8, accuracy: 1e-12)
        XCTAssertEqual(clipped.y, 0)
        XCTAssertEqual(clipped.width, 0.2, accuracy: 1e-12)
        XCTAssertEqual(clipped.height, 0.2, accuracy: 1e-12)
        XCTAssertEqual(clipped.score, 1)
        XCTAssertEqual(clipped.label, "l")
        XCTAssertNil(ImageLocateBox(x: 1.2, y: 0, width: 0.1, height: 0.1).clipped)

        XCTAssertEqual(head.overlap(head), 1, accuracy: 1e-12)
        XCTAssertEqual(head.overlap(ImageLocateBox(x: 0.9, y: 0.9, width: 0.1, height: 0.1)), 0)

        // Into the characterPart / promptSegment convention: [x0, y0, x1, y1] in pixels.
        let corners = head.pixelCorners(width: 1024, height: 1536)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0], 317.44, accuracy: 0.01)
        XCTAssertEqual(corners[1], 61.44, accuracy: 0.01)
        XCTAssertEqual(corners[2], 706.56, accuracy: 0.01)
        XCTAssertEqual(corners[3], 568.32, accuracy: 0.01)
        let request = CharacterPartRequest(image: picture, subjectBox: corners)
        XCTAssertNil(request.shapeProblem)
    }

    func testServedClipsOrdersAndCuts() {
        let raw = [
            ImageLocateBox(x: 0.0, y: 0.0, width: 0.2, height: 0.2, label: "a", score: 0.3),
            ImageLocateBox(x: 1.5, y: 0.0, width: 0.2, height: 0.2, label: "gone", score: 0.99),
            ImageLocateBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2, label: "b", score: 0.8),
            ImageLocateBox(x: 0.3, y: 0.3, width: 0.2, height: 0.2, label: "c", score: 0.8),
        ]
        XCTAssertEqual(raw.served(count: 8).map(\.label), ["b", "c", "a"])
        XCTAssertEqual(raw.served(count: 2).map(\.label), ["b", "c"])
        XCTAssertEqual(raw.served(count: 0), [])
        // Unscored boxes keep the provider's order.
        let unscored = [ImageLocateBox(x: 0, y: 0, width: 0.1, height: 0.1, label: "first"),
                        ImageLocateBox(x: 0.5, y: 0, width: 0.1, height: 0.1, label: "second")]
        XCTAssertEqual(unscored.served(count: 2).map(\.label), ["first", "second"])
    }

    func testResponseProblems() {
        let request = ImageLocateRequest(image: picture, prompt: "balls", count: 2)
        let a = ImageLocateBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2, score: 0.9)
        let b = ImageLocateBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2, score: 0.6)
        XCTAssertTrue(locator.responseProblems(ImageLocateResponse(boxes: [a, b]), for: request).isEmpty)
        XCTAssertTrue(locator.responseProblems(ImageLocateResponse(boxes: []), for: request).isEmpty,
                      "an empty list is a success")
        XCTAssertFalse(locator.responseProblems(ImageLocateResponse(boxes: [b, a]), for: request).isEmpty,
                       "ascending score")
        XCTAssertFalse(locator.responseProblems(ImageLocateResponse(boxes: [a, b, b]), for: request).isEmpty,
                       "more than count")
        let unscored = ImageLocateBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertFalse(locator.responseProblems(ImageLocateResponse(boxes: [unscored]), for: request).isEmpty,
                       "scores declared, one missing")
        let one = ImageLocateRequest(image: picture, prompt: "eyes")
        XCTAssertTrue(pointer.responseProblems(ImageLocateResponse(boxes: [unscored]), for: one).isEmpty)
        XCTAssertFalse(pointer.responseProblems(ImageLocateResponse(boxes: [a]), for: one).isEmpty,
                       "no scores declared, one given")
        let bad = ImageLocateBox(x: 0.9, y: 0.1, width: 0.2, height: 0.2, score: 0.5)
        XCTAssertFalse(locator.responseProblems(ImageLocateResponse(boxes: [bad]), for: request).isEmpty,
                       "a box outside the image")
    }

    func testDescriptorAdvertisesOnlyWhatIsDeclared() {
        let many = ImageLocateContract.descriptor(name: "locate", summary: "s", controls: locator)
        XCTAssertEqual(many.capability, .imageLocate)
        XCTAssertEqual(many.imageLocateControls, locator)
        XCTAssertTrue(many.controlsMatchCapability)
        XCTAssertEqual(many.parameters.map(\.name), ["image", "prompt", "count"])
        XCTAssertTrue(many.parameters.first { $0.name == "count" }?.summary?.contains("1 – 16") ?? false)

        let one = ImageLocateContract.descriptor(name: "pointer", summary: "s", controls: pointer)
        XCTAssertEqual(one.parameters.map(\.name), ["image", "prompt", "seed"])

        let mismatched = ToolDescriptor(name: "x", capability: .imageAnalysis, summary: "s",
                                        controls: .imageLocate(locator))
        XCTAssertFalse(mismatched.controlsMatchCapability)
        XCTAssertNil(ImageAnalysisContract.descriptor(name: "a", summary: "s").imageLocateControls)
    }

    func testWireRoundTripsAndMESBoxJSON() throws {
        let descriptor = ImageLocateContract.descriptor(name: "locate", summary: "s", controls: pointer)
        XCTAssertEqual(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor)),
                       descriptor)

        XCTAssertTrue(CapabilityWire.requestType(for: .imageLocate) == ImageLocateRequest.self)
        XCTAssertTrue(CapabilityWire.responseType(for: .imageLocate) == ImageLocateResponse.self)
        let request = ImageLocateRequest(image: picture, prompt: "every window", count: 8, seed: 3,
                                         metaData: ["side": .int(1024)])
        let json = try CapabilityWire.encoder().encode(CapabilityRequestEnvelope(request, package: "locate"))
        let decoded = try CapabilityWire.decoder().decode(CapabilityRequestEnvelope.self, from: json)
        XCTAssertEqual(decoded.capability, .imageLocate)
        let typed = try XCTUnwrap(decoded.request as? ImageLocateRequest)
        XCTAssertEqual(typed.image, picture)
        XCTAssertEqual(typed.prompt, "every window")
        XCTAssertEqual(typed.count, 8)
        XCTAssertEqual(typed.seed, 3)

        // A minimal request decodes without count or seed.
        let minimal = try JSONDecoder().decode(
            ImageLocateRequest.self,
            from: Data(#"{"image":{"format":"png","data":"AQID"},"prompt":"a head","metaData":{}}"#.utf8))
        XCTAssertNil(minimal.count)
        XCTAssertEqual(minimal.effectiveCount, 1)

        // A box decodes from MES's LocatedBox JSON, label and score optional.
        let boxes = try JSONDecoder().decode([ImageLocateBox].self, from: Data(#"""
            [{"x":0.31,"y":0.04,"width":0.38,"height":0.33,"label":"head","score":0.94},
             {"x":0.1,"y":0.2,"width":0.3,"height":0.4}]
            """#.utf8))
        XCTAssertEqual(boxes[0], ImageLocateBox(x: 0.31, y: 0.04, width: 0.38, height: 0.33,
                                                label: "head", score: 0.94))
        XCTAssertNil(boxes[1].label)
        XCTAssertNil(boxes[1].score)

        let response = ImageLocateResponse(boxes: boxes)
        let back = try JSONDecoder().decode(ImageLocateResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(back.boxes, boxes)
        XCTAssertTrue(try JSONDecoder().decode(ImageLocateResponse.self,
                                               from: Data(#"{"boxes":[]}"#.utf8)).isEmpty)
    }
}
