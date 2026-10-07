//
//  SpeechEditContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.50.0 — `Capability.speechEdit` (AB-A-0137): an existing take + its transcript, re-delivered
//  in the same voice. Checks the capability's place in the contract, the operation ↔ declaration
//  mapping, and that the descriptor is born declared and advertises exactly what it declares.
//

import XCTest
@testable import MLXToolKit

final class SpeechEditContractTests: XCTestCase {

    /// The Step-Audio-EditX shape, trimmed: every operation, closed vocabularies, a length limit.
    private let editX = SpeechEditControls(
        operations: [.emotion, .style, .paralinguistic, .denoise, .trimSilence],
        emotionLabels: ["happy", "sad", "angry", "remove"],
        styleLabels: ["whisper", "older"],
        paralinguisticTags: ["[Laughter]", "[Breathing]"],
        maxInputSeconds: 150)

    func testSpeechEditIsACapabilityWithAudioOutput() {
        XCTAssertTrue(Capability.allCases.contains(.speechEdit))
        XCTAssertEqual(Capability.speechEdit.rawValue, "speechEdit")
        XCTAssertEqual(Capability.speechEdit.canonicalOutput, .audio)
        XCTAssertEqual(SpeechEditRequest.capability, .speechEdit)
    }

    func testRequestEnvelopeDefaults() {
        let request = SpeechEditRequest(audio: Audio(data: Data([1])), transcript: "the take",
                                        edit: .emotion("happy"))
        XCTAssertEqual(request.capability, .speechEdit)
        XCTAssertNil(request.seed)
        XCTAssertNil(request.mode)
        XCTAssertTrue(request.metaData.isEmpty)
    }

    // The value's case maps 1:1 onto the declaration a package makes — the TTSEmotion.mode pattern.
    func testOperationKindAndLabel() {
        XCTAssertEqual(SpeechEditOperation.emotion("happy").kind, .emotion)
        XCTAssertEqual(SpeechEditOperation.emotion("happy").label, "happy")
        XCTAssertEqual(SpeechEditOperation.style("whisper").kind, .style)
        XCTAssertEqual(SpeechEditOperation.style("whisper").label, "whisper")
        XCTAssertEqual(SpeechEditOperation.paralinguistic(targetTranscript: "Hi[Laughter]").kind,
                       .paralinguistic)
        XCTAssertNil(SpeechEditOperation.paralinguistic(targetTranscript: "Hi[Laughter]").label)
        XCTAssertEqual(SpeechEditOperation.denoise.kind, .denoise)
        XCTAssertEqual(SpeechEditOperation.trimSilence.kind, .trimSilence)
        XCTAssertNil(SpeechEditOperation.trimSilence.label)
    }

    func testOperationsRoundTrip() throws {
        let all: [SpeechEditOperation] = [.emotion("remove"), .style("older"),
                                          .paralinguistic(targetTranscript: "Great[Laughter], the weather"),
                                          .denoise, .trimSilence]
        for operation in all {
            let round = try JSONDecoder().decode(SpeechEditOperation.self,
                                                 from: JSONEncoder().encode(operation))
            XCTAssertEqual(round, operation)
        }
    }

    func testVocabularyFollowsTheOperation() {
        XCTAssertEqual(editX.vocabulary(for: .emotion), ["happy", "sad", "angry", "remove"])
        XCTAssertEqual(editX.vocabulary(for: .style), ["whisper", "older"])
        XCTAssertEqual(editX.vocabulary(for: .paralinguistic), ["[Laughter]", "[Breathing]"])
        XCTAssertEqual(editX.vocabulary(for: .denoise), [])
        XCTAssertEqual(editX.vocabulary(for: .trimSilence), [])
    }

    // Born declared: the descriptor carries the declaration and derives the `edit` summary from it.
    func testDescriptorCarriesAndAdvertisesTheDeclaration() throws {
        let descriptor = SpeechEditContract.descriptor(name: "step-audio-editx", summary: "s",
                                                       controls: editX)
        XCTAssertEqual(descriptor.capability, .speechEdit)
        XCTAssertEqual(descriptor.speechEditControls, editX)
        XCTAssertTrue(descriptor.controlsMatchCapability)
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "transcript", "edit", "seed"])
        XCTAssertEqual(descriptor.parameters.filter(\.required).map(\.name),
                       ["audio", "transcript", "edit"])

        let edit = try XCTUnwrap(descriptor.parameters.first { $0.name == "edit" })
        XCTAssertEqual(edit.summary, "One edit: emotion (happy / sad / angry / remove); "
                       + "style (whisper / older); paralinguistic (targetTranscript with inline tags: "
                       + "[Laughter] / [Breathing]); denoise; trimSilence. Takes up to 150 s.")
    }

    // An open vocabulary and an unstated limit read as such; an undeclared operation is not offered.
    func testSummaryOfAnOpenNarrowSurface() throws {
        let open = SpeechEditContract.descriptor(
            name: "open-edit", summary: "s", controls: SpeechEditControls(operations: [.emotion]))
        let edit = try XCTUnwrap(open.parameters.first { $0.name == "edit" })
        XCTAssertEqual(edit.summary, "One edit: emotion (any label).")
    }

    func testControlsMustMatchTheSurfaceCapability() {
        let mismatched = ToolDescriptor(name: "speak", capability: .tts, summary: "s",
                                        controls: .speechEdit(editX))
        XCTAssertFalse(mismatched.controlsMatchCapability)
        XCTAssertNil(mismatched.ttsControls)
        // And a tts surface never reads as a speech-edit declaration.
        XCTAssertNil(TTSContract.descriptor(name: "speak", summary: "s").speechEditControls)
    }

    func testDescriptorRoundTrips() throws {
        let descriptor = SpeechEditContract.descriptor(name: "step-audio-editx", summary: "s",
                                                       controls: editX)
        let round = try JSONDecoder().decode(ToolDescriptor.self,
                                             from: JSONEncoder().encode(descriptor))
        XCTAssertEqual(round, descriptor)
        XCTAssertEqual(round.speechEditControls?.maxInputSeconds, 150)
    }

    // The response carries the text the take should carry — what a content check compares against.
    func testResponseCarriesTheExpectedTranscript() {
        let response = SpeechEditResponse(audio: Audio(data: Data([2])),
                                          transcript: "Great[Laughter], the weather")
        XCTAssertEqual(response.transcript, "Great[Laughter], the weather")
        XCTAssertEqual(response.audio.format, .wav)
    }
}
