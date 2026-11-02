//
//  SpeechEditContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.50.0 — `Capability.speechEdit` (AB-A-0137); 1.59.0 — the AuK kinds and speaker picks
//  (AB-A-0188): an existing take + its transcript, re-delivered
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

    // MARK: - contract 1.59.0 (AB-A-0188): the AuK kinds

    /// The AuK shape: no transcript, a length, trained grids, a closed nonverbal set.
    private let auk = SpeechEditControls(
        operations: [.emotion, .style, .denoise, .replaceWords, .insertWords, .removeWords, .speed, .pitch,
                     .volume, .timbre, .deAccent, .dereverberate, .addNonverbal, .removeNonverbal],
        emotionLabels: ["happy", "sad"],
        styleLabels: ["whisper", "normal"],
        nonverbalSounds: ["breath", "laugh"],
        speedFactors: [0.5, 0.75, 1.25, 1.5, 2.0],
        pitchSemitones: [-3, -2, -1, 1, 2, 3],
        volumeDecibels: [-15, -10, -5, 5, 10, 15],
        transcript: .unused,
        supportsTargetDuration: true)

    private let clip = Audio(data: Data([1]))

    func testNewKindsMapOntoTheirDeclarations() {
        let cases: [(SpeechEditOperation, SpeechEditControls.Operation, String?, Bool)] = [
            (.replaceWords(original: "rain", new: "sun"), .replaceWords, nil, true),
            (.insertWords(text: "very", anchor: "nice", before: true), .insertWords, nil, true),
            (.removeWords(text: "um", anchor: nil, before: false), .removeWords, nil, true),
            (.speed(factor: 1.5), .speed, nil, true),
            (.pitch(semitones: -2), .pitch, nil, false),
            (.volume(dB: 10), .volume, nil, false),
            (.timbre(description: "a deep voice"), .timbre, nil, false),
            (.deAccent, .deAccent, nil, false),
            (.dereverberate, .dereverberate, nil, false),
            (.addNonverbal(sound: "laugh", atEnd: true), .addNonverbal, "laugh", true),
            (.removeNonverbal(sound: "breath"), .removeNonverbal, "breath", true),
            (.removeNonverbal(sound: nil), .removeNonverbal, nil, true),
            (.emotion("happy"), .emotion, "happy", false),
        ]
        for (operation, kind, label, changesLength) in cases {
            XCTAssertEqual(operation.kind, kind)
            XCTAssertEqual(operation.label, label)
            XCTAssertEqual(operation.changesLength, changesLength, "\(operation)")
        }
    }

    func testNewKindsRoundTrip() throws {
        let all: [SpeechEditOperation] = [
            .replaceWords(original: "rain", new: "sun"), .insertWords(text: "very", anchor: "nice", before: false),
            .removeWords(text: "um", anchor: "so", before: true), .removeWords(text: "um", anchor: nil, before: false),
            .speed(factor: 0.75), .pitch(semitones: 3), .volume(dB: -15), .timbre(description: "bright"),
            .deAccent, .dereverberate, .addNonverbal(sound: "laugh", atEnd: false), .removeNonverbal(sound: nil),
        ]
        for operation in all {
            XCTAssertEqual(try JSONDecoder().decode(SpeechEditOperation.self,
                                                    from: JSONEncoder().encode(operation)), operation)
        }
    }

    // A 1.50.0 declaration decodes with every 1.59.0 member at the 1.50.0 behaviour.
    func testPre159ControlsJSONDecodesWithDefaults() throws {
        let json = #"{"operations":["emotion"],"emotionLabels":["happy"],"styleLabels":[],"paralinguisticTags":[]}"#
        let decoded = try JSONDecoder().decode(SpeechEditControls.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, SpeechEditControls(operations: [.emotion], emotionLabels: ["happy"]))
        XCTAssertEqual(decoded.transcript, .required)
        XCTAssertFalse(decoded.supportsTargetDuration)
        XCTAssertEqual(try JSONDecoder().decode(SpeechEditControls.self,
                                                from: JSONEncoder().encode(auk)), auk)
    }

    // A request with no transcript may omit the key; one with a length round-trips it.
    func testRequestWithoutATranscriptDecodes() throws {
        let request = SpeechEditRequest(audio: clip, edit: .speed(factor: 2), targetDuration: 3.5)
        XCTAssertEqual(request.transcript, "")
        let round = try JSONDecoder().decode(SpeechEditRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(round.targetDuration, 3.5)
        XCTAssertEqual(round.edit, .speed(factor: 2))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                                   as? [String: Any])
        object.removeValue(forKey: "transcript")
        let bare = try JSONDecoder().decode(SpeechEditRequest.self,
                                            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(bare.transcript, "")
    }

    func testAuKDescriptorAdvertisesItsDeclaration() throws {
        let descriptor = SpeechEditContract.descriptor(name: "auk", summary: "s", controls: auk)
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "transcript", "edit", "targetDuration", "seed"])
        XCTAssertEqual(descriptor.parameters.filter(\.required).map(\.name), ["audio", "edit"])
        let edit = try XCTUnwrap(descriptor.parameters.first { $0.name == "edit" })
        XCTAssertEqual(edit.summary, "One edit: emotion (happy / sad); style (whisper / normal); denoise; "
                       + "replaceWords (original, new); insertWords (text, anchor, before); "
                       + "removeWords (text, optional anchor, before); speed (factor: 0.5x / 0.75x / 1.25x / "
                       + "1.5x / 2x); pitch (semitones: -3 / -2 / -1 / +1 / +2 / +3); volume (dB: -15 / -10 / -5 / "
                       + "+5 / +10 / +15); timbre (description); deAccent; dereverberate; addNonverbal (sound: "
                       + "breath / laugh; atEnd); removeNonverbal (sound: breath / laugh; absent = all).")
        XCTAssertEqual(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor)),
                       descriptor)
    }

    func testRefusalAdmitsWhatIsDeclared() {
        let admitted: [SpeechEditRequest] = [
            SpeechEditRequest(audio: clip, edit: .replaceWords(original: "rain", new: "sun"), targetDuration: 4),
            SpeechEditRequest(audio: clip, edit: .speed(factor: 1.25)),
            SpeechEditRequest(audio: clip, edit: .pitch(semitones: -3)),
            SpeechEditRequest(audio: clip, edit: .volume(dB: 15)),
            SpeechEditRequest(audio: clip, edit: .removeNonverbal(sound: nil)),
            SpeechEditRequest(audio: clip, edit: .addNonverbal(sound: "laugh", atEnd: true)),
            SpeechEditRequest(audio: clip, transcript: "echoed", edit: .style("normal")),
        ]
        for request in admitted { XCTAssertNil(auk.refusal(for: request), "\(request.edit)") }
        XCTAssertNil(editX.refusal(for: SpeechEditRequest(audio: clip, transcript: "t", edit: .denoise)))
    }

    func testRefusalNamesWhatIsWrong() {
        func reason(_ controls: SpeechEditControls, _ request: SpeechEditRequest) -> String {
            controls.refusal(for: request) ?? "<admitted>"
        }
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .trimSilence)).contains("operations"))
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .speed(factor: 1.1))).contains("speedFactors"))
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .speed(factor: -1))).contains("positive"))
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .pitch(semitones: 5))).contains("pitchSemitones"))
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .volume(dB: 3))).contains("volumeDecibels"))
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .addNonverbal(sound: "cough", atEnd: false)))
                      .contains("cough"))
        XCTAssertTrue(reason(auk, SpeechEditRequest(audio: clip, edit: .deAccent, targetDuration: 0))
                      .contains("positive"))
        // Step-Audio-EditX conditions on the words and takes no length.
        XCTAssertTrue(reason(editX, SpeechEditRequest(audio: clip, transcript: "  ", edit: .denoise))
                      .contains("transcript"))
        XCTAssertTrue(reason(editX, SpeechEditRequest(audio: clip, transcript: "t", edit: .denoise, targetDuration: 3))
                      .contains("supportsTargetDuration"))
        // An open grid admits any value; the package judges it.
        let open = SpeechEditControls(operations: [.speed], transcript: .optional)
        XCTAssertNil(open.refusal(for: SpeechEditRequest(audio: clip, edit: .speed(factor: 1.1))))
    }

    // MARK: - audioSeparation speaker picks (1.59.0)

    func testSeparationWithoutControlsIsUnchanged() {
        let descriptor = AudioSeparationContract.descriptor(name: "demucs", summary: "s")
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "stems"])
        XCTAssertNil(descriptor.controls)
        XCTAssertNil(AudioSeparationRequest(audio: clip, stems: [.vocals]).speaker)
    }

    func testSeparationSpeakerPicks() throws {
        let controls = AudioSeparationControls(stems: [.speech, .singing, .voices, .speaker],
                                               speakerSelection: [.ordinal])
        let descriptor = AudioSeparationContract.descriptor(name: "auk-sep", summary: "s", controls: controls)
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "stems", "speaker"])
        XCTAssertEqual(descriptor.audioSeparationControls, controls)
        XCTAssertTrue(descriptor.controlsMatchCapability)
        XCTAssertEqual(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor)),
                       descriptor)

        XCTAssertNil(controls.refusal(for: AudioSeparationRequest(audio: clip, speaker: .ordinal(2))))
        XCTAssertNotNil(controls.refusal(for: AudioSeparationRequest(audio: clip, speaker: .ordinal(0))))
        XCTAssertTrue(controls.refusal(for: AudioSeparationRequest(audio: clip, speaker: .saying("hello")))?
            .contains("speakerSelection") == true)

        let request = AudioSeparationRequest(audio: clip, speaker: .saying("hello there"))
        XCTAssertEqual(try JSONDecoder().decode(AudioSeparationRequest.self,
                                                from: JSONEncoder().encode(request)).speaker, .saying("hello there"))
        let mismatched = ToolDescriptor(name: "x", capability: .stt, summary: "s",
                                        controls: .audioSeparation(controls))
        XCTAssertFalse(mismatched.controlsMatchCapability)
    }
}
