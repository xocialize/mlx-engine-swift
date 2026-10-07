//
//  TTSSpeakersTests.swift
//  MLXToolKitTests
//
//  Contract 1.49.0 — the multi-speaker cast (AB-A-0136). The two properties every additive pass
//  promises: the additions are INERT for existing call sites, and a declaration DRIVES what the
//  surface advertises (so a planner is never offered a voice that would be dropped).
//

import XCTest
@testable import MLXToolKit

final class TTSSpeakersTests: XCTestCase {

    private let s1 = TTSSpeakerVoice(voice: VoiceSelector(.referenceAudio(Audio(data: Data([1])))),
                                     referenceTranscript: "first speaker's prefix")
    private let s2 = TTSSpeakerVoice(voice: VoiceSelector(.referenceAudio(Audio(data: Data([2])))),
                                     referenceTranscript: "second speaker's prefix")

    // MARK: - TTSRequest.additionalSpeakers / speakers

    func testAOneVoiceRequestIsACastOfOne() {
        let legacy = TTSRequest(text: "hello")
        XCTAssertNil(legacy.additionalSpeakers)
        XCTAssertEqual(legacy.speakers, [TTSSpeakerVoice()])

        let cloned = TTSRequest(text: "hello", voice: s1.voice,
                                referenceTranscript: s1.referenceTranscript)
        XCTAssertEqual(cloned.speakers, [s1])
    }

    // speakers[0] is DERIVED from voice + referenceTranscript, so the alias cannot drift from them.
    func testSpeakersListsTheCastInScriptOrder() {
        let scene = TTSRequest(text: "[S1] a [S2] b", voice: s1.voice,
                               referenceTranscript: s1.referenceTranscript,
                               additionalSpeakers: [s2])
        XCTAssertEqual(scene.speakers, [s1, s2])
    }

    // The list initializer and the field-wise one build the same value.
    func testTheListInitializerSplitsTheCast() {
        let scene = TTSRequest(text: "[S1] a [S2] b", speakers: [s1, s2], mode: .expressive,
                               metaData: ["seed": .int(7)])
        XCTAssertEqual(scene.voice, s1.voice)
        XCTAssertEqual(scene.referenceTranscript, s1.referenceTranscript)
        XCTAssertEqual(scene.additionalSpeakers, [s2])
        XCTAssertEqual(scene.speakers, [s1, s2])
        XCTAssertEqual(scene.mode, .expressive)
        XCTAssertEqual(scene.metaData["seed"], .int(7))

        // One voice through the list is the one-voice request exactly: nothing extra to gate.
        XCTAssertNil(TTSRequest(text: "a", speakers: [s1]).additionalSpeakers)
        // An empty cast is a default-voice request.
        let none = TTSRequest(text: "a", speakers: [])
        XCTAssertEqual(none.voice, VoiceSelector(.auto))
        XCTAssertNil(none.referenceTranscript)
        XCTAssertNil(none.additionalSpeakers)
    }

    func testSpeakerVoiceDefaultsToAutoAndRoundTrips() throws {
        XCTAssertEqual(TTSSpeakerVoice().voice, VoiceSelector(.auto))
        XCTAssertNil(TTSSpeakerVoice().referenceTranscript)
        let round = try JSONDecoder().decode(TTSSpeakerVoice.self, from: JSONEncoder().encode(s2))
        XCTAssertEqual(round, s2)
    }

    // MARK: - TTSControls.speakerTags — declaration drives advertisement

    func testSpeakerTagsDeriveMaxSpeakers() {
        XCTAssertNil(TTSControls().speakerTags)
        XCTAssertEqual(TTSControls().maxSpeakers, 1)
        XCTAssertEqual(TTSControls(speakerTags: []).maxSpeakers, 1)
        XCTAssertEqual(TTSControls(speakerTags: ["[S1]", "[S2]"]).maxSpeakers, 2)
    }

    func testOnlyAMultiSpeakerSurfaceAdvertisesAdditionalSpeakers() throws {
        let plain = TTSContract.descriptor(name: "speak", summary: "s")
        XCTAssertFalse(plain.parameters.contains { $0.name == "additionalSpeakers" })

        // One tag names speaker 1's syntax but offers no second voice.
        let oneTag = TTSContract.descriptor(
            name: "speak", summary: "s", controls: TTSControls(speakerTags: ["[S1]"]))
        XCTAssertFalse(oneTag.parameters.contains { $0.name == "additionalSpeakers" })

        let dia2 = TTSContract.descriptor(
            name: "dia2-2b", summary: "s", modes: [.expressive],
            controls: TTSControls(speakerTags: ["[S1]", "[S2]"]))
        let extra = try XCTUnwrap(dia2.parameters.first { $0.name == "additionalSpeakers" })
        XCTAssertEqual(extra.kind, .array)
        XCTAssertFalse(extra.required)
        // The planner is told how many speakers and the exact tags to write.
        XCTAssertEqual(extra.summary?.contains("Up to 2 speakers, tagged [S1] / [S2]."), true)
        // Independent of the 1.38.0 controls: no emotion or duration knob was declared.
        XCTAssertEqual(dia2.parameters.map(\.name),
                       ["text", "voice", "referenceTranscript", "additionalSpeakers"])
        XCTAssertEqual(dia2.ttsControls?.maxSpeakers, 2)
        XCTAssertTrue(dia2.controlsMatchCapability)
    }

    func testDescriptorRoundTripsSpeakerTags() throws {
        let descriptor = TTSContract.descriptor(
            name: "dia2-2b", summary: "s", controls: TTSControls(speakerTags: ["[S1]", "[S2]"]))
        let round = try JSONDecoder().decode(
            ToolDescriptor.self, from: JSONEncoder().encode(descriptor))
        XCTAssertEqual(round, descriptor)
        XCTAssertEqual(round.ttsControls?.speakerTags, ["[S1]", "[S2]"])
    }

    // TTSControls JSON written against 1.38–1.48 (no speakerTags key) still decodes.
    func testControlsDecodePre149JSON() throws {
        let json = Data(#"{"emotionModes":["categorical"],"supportsTargetDuration":true}"#.utf8)
        let decoded = try JSONDecoder().decode(TTSControls.self, from: json)
        XCTAssertNil(decoded.speakerTags)
        XCTAssertEqual(decoded.maxSpeakers, 1)
        XCTAssertEqual(decoded.emotionModes, [.categorical])
        XCTAssertTrue(decoded.supportsTargetDuration)
    }
}

/// Source-compatibility harness for contract 1.49.0: the shapes `mlx-dia2-tts-swift` v0.1.2
/// ships against engine 0.62.0 (`Dia2TTSPackage.swift:55` / `:67`, `dia2-gates/Validate.swift:116`),
/// copied in shape, so a later edit that breaks one fails here before it fails in that repo.
final class Dia2CallSiteCompatibilityTests: XCTestCase {

    func testShippedManifestCallSitesStillCompile() {
        let license = LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit)
        XCTAssertNil(license.additionalWeightLicenses)

        let descriptor = TTSContract.descriptor(name: "dia2-2b", summary: "…", modes: [.expressive])
        XCTAssertNil(descriptor.ttsControls)
        XCTAssertEqual(descriptor.parameters.map(\.name), ["text", "voice", "referenceTranscript"])
    }

    // The interim path: speaker 2 in package metaData. 1.49.0 leaves it exactly where it was.
    func testInterimSpeaker2MetaDataPathIsUnchanged() {
        let request = TTSRequest(
            text: "[S1] Did you hear that? [S2] Hear what?",
            voice: VoiceSelector(.referenceAudio(Audio(data: Data([1])))),
            referenceTranscript: "speaker one",
            metaData: ["seed": .int(1), "speaker2Audio": .string("UklGRg=="),
                       "speaker2Transcript": .string("speaker two")])
        XCTAssertNil(request.additionalSpeakers)
        XCTAssertEqual(request.speakers.count, 1)
        XCTAssertEqual(request.metaData["speaker2Transcript"], .string("speaker two"))
    }
}
