//
//  T2VControlsTests.swift
//  MLXToolKitTests
//
//  Contract 1.40.0 — `T2VRequest.initAudio` (audio-to-video) and the `T2VControls` declaration
//  that gates it (AB-A-0023, verdict on AB-A-0066). The shape mirrors `TTSControls`: the request
//  field is additive and nil-by-default, the descriptor advertises the knob ONLY when declared,
//  and the declaration must sit on a surface of the matching capability.
//

import XCTest
import MLXToolKit

final class T2VControlsTests: XCTestCase {

    func testInitAudioIsAdditiveAndDefaultsNil() {
        let legacy = T2VRequest(prompt: "p")
        XCTAssertNil(legacy.initAudio)
        // A pre-1.40 call site passing the envelope still compiles in positional order.
        let withEnvelope = T2VRequest(prompt: "p", referenceImages: [], numFrames: 9, seed: 1)
        XCTAssertNil(withEnvelope.initAudio)
        XCTAssertEqual(withEnvelope.numFrames, 9)

        let a2v = T2VRequest(prompt: "p", initAudio: Audio(data: Data(count: 44), sampleRate: 48000, channels: 2))
        XCTAssertEqual(a2v.initAudio?.sampleRate, 48000)
    }

    func testDescriptorAdvertisesInitAudioOnlyWhenDeclared() throws {
        let plain = T2VContract.descriptor(name: "gen", summary: "s")
        XCTAssertNil(plain.controls)
        XCTAssertNil(plain.t2vControls)
        XCTAssertFalse(plain.parameters.contains { $0.name == "initAudio" })
        // The ignorable inputs stay advertised regardless — they were never gated.
        XCTAssertTrue(plain.parameters.contains { $0.name == "initImage" })
        XCTAssertTrue(plain.parameters.contains { $0.name == "referenceImages" })

        let a2v = T2VContract.descriptor(name: "gen", summary: "s",
                                         controls: T2VControls(supportsInitAudio: true))
        XCTAssertEqual(a2v.t2vControls?.supportsInitAudio, true)
        let param = try XCTUnwrap(a2v.parameters.first { $0.name == "initAudio" })
        XCTAssertEqual(param.kind, .audio)
        XCTAssertFalse(param.required)
        // Sits with the other conditioning inputs, not appended after `seed`.
        XCTAssertEqual(a2v.parameters.map(\.name).prefix(5),
                       ["prompt", "negativePrompt", "initImage", "referenceImages", "initAudio"])

        // Declaring the block with the lever OFF advertises nothing — same as no block.
        let declaredOff = T2VContract.descriptor(name: "gen", summary: "s",
                                                 controls: T2VControls(supportsInitAudio: false))
        XCTAssertNotNil(declaredOff.t2vControls)
        XCTAssertFalse(declaredOff.parameters.contains { $0.name == "initAudio" })
    }

    func testControlsMustMatchTheSurfaceCapability() {
        XCTAssertTrue(T2VContract.descriptor(
            name: "gen", summary: "s",
            controls: T2VControls(supportsInitAudio: true)).controlsMatchCapability)
        // A textToVideo block on a tts surface tells a consumer nothing true.
        let mismatched = ToolDescriptor(name: "speak", capability: .tts, summary: "s",
                                        controls: .textToVideo(T2VControls(supportsInitAudio: true)))
        XCTAssertFalse(mismatched.controlsMatchCapability)
    }

    func testDescriptorRoundTripsThroughJSON() throws {
        let a2v = T2VContract.descriptor(name: "gen", summary: "s",
                                         controls: T2VControls(supportsInitAudio: true))
        let round = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(a2v))
        XCTAssertEqual(round, a2v)
        XCTAssertEqual(round.t2vControls?.supportsInitAudio, true)

        // Pre-1.40 JSON (no `controls`) still decodes to a nil declaration.
        let legacy = T2VContract.descriptor(name: "gen", summary: "s")
        let legacyRound = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(legacyRound.t2vControls)
    }
}
