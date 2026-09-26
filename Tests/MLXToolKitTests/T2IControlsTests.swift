//
//  T2IControlsTests.swift
//  MLXToolKitTests
//
//  Contract 1.48.0 — `T2IRequest.background` (native alpha) and the `T2IControls` declaration
//  that gates it. The shape mirrors `T2VControls` (1.40.0): the request field is additive and
//  nil-by-default, the descriptor advertises the knob ONLY when declared, and the declaration
//  must sit on a surface of the matching capability.
//

import XCTest
import MLXToolKit

final class T2IControlsTests: XCTestCase {

    func testBackgroundIsAdditiveAndDefaultsNil() {
        let legacy = T2IRequest(prompt: "p")
        XCTAssertNil(legacy.background)
        // A pre-1.48 call site passing the envelope, mode and metaData still compiles in order.
        let withEnvelope = T2IRequest(prompt: "p", width: 1024, height: 576, steps: 12, seed: 1,
                                      mode: nil, metaData: ["k": .string("v")])
        XCTAssertNil(withEnvelope.background)
        XCTAssertEqual(withEnvelope.width, 1024)

        let alpha = T2IRequest(prompt: "a red enamel badge", seed: 1, background: .transparent)
        XCTAssertEqual(alpha.background, .transparent)
    }

    // The raw values are the wire form a tool client sends in the `background` parameter.
    func testBackgroundWireValues() throws {
        XCTAssertEqual(T2IBackground.opaque.rawValue, "opaque")
        XCTAssertEqual(T2IBackground.transparent.rawValue, "transparent")
        XCTAssertEqual(try JSONDecoder().decode(T2IBackground.self, from: Data(#""transparent""#.utf8)),
                       .transparent)
    }

    func testDescriptorAdvertisesBackgroundOnlyWhenDeclared() throws {
        let plain = T2IContract.descriptor(name: "gen", summary: "s")
        XCTAssertNil(plain.controls)
        XCTAssertNil(plain.t2iControls)
        XCTAssertFalse(plain.parameters.contains { $0.name == "background" })

        let alpha = T2IContract.descriptor(name: "gen", summary: "s",
                                           controls: T2IControls(supportsTransparentBackground: true))
        XCTAssertEqual(alpha.t2iControls?.supportsTransparentBackground, true)
        let param = try XCTUnwrap(alpha.parameters.first { $0.name == "background" })
        XCTAssertEqual(param.kind, .string)
        XCTAssertFalse(param.required)
        // Everything a pre-1.48 descriptor advertised is still there, in the same order.
        XCTAssertEqual(Array(alpha.parameters.map(\.name).dropLast()), plain.parameters.map(\.name))

        // Declaring the block with the lever OFF advertises nothing — same as no block.
        let declaredOff = T2IContract.descriptor(name: "gen", summary: "s",
                                                 controls: T2IControls(supportsTransparentBackground: false))
        XCTAssertNotNil(declaredOff.t2iControls)
        XCTAssertFalse(declaredOff.parameters.contains { $0.name == "background" })
    }

    func testControlsMustMatchTheSurfaceCapability() {
        XCTAssertTrue(T2IContract.descriptor(
            name: "gen", summary: "s",
            controls: T2IControls(supportsTransparentBackground: true)).controlsMatchCapability)
        // A textToImage block on an imageEdit surface tells a consumer nothing true.
        let mismatched = ToolDescriptor(name: "edit", capability: .imageEdit, summary: "s",
                                        controls: .textToImage(T2IControls(supportsTransparentBackground: true)))
        XCTAssertFalse(mismatched.controlsMatchCapability)
        // Nor does another capability's block read as a t2i declaration.
        let t2v = ToolDescriptor(name: "gen", capability: .textToVideo, summary: "s",
                                 controls: .textToVideo(T2VControls(supportsInitAudio: true)))
        XCTAssertNil(t2v.t2iControls)
    }

    func testDescriptorRoundTripsThroughJSON() throws {
        let alpha = T2IContract.descriptor(name: "gen", summary: "s",
                                           controls: T2IControls(supportsTransparentBackground: true))
        let round = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(alpha))
        XCTAssertEqual(round, alpha)
        XCTAssertEqual(round.t2iControls?.supportsTransparentBackground, true)

        // Pre-1.48 JSON (no `controls`) still decodes to a nil declaration.
        let legacy = T2IContract.descriptor(name: "gen", summary: "s")
        let legacyRound = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(legacyRound.t2iControls)
    }
}
