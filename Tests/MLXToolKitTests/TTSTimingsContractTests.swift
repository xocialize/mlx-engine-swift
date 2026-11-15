//
//  TTSTimingsContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.65.0 — speech timings on TTS (AB-A-0289, mlx-3d avatar lip-sync). The additive
//  promises: every pre-1.65 call site and JSON payload is untouched, the declaration DRIVES what
//  the surface advertises, and the shape validator refuses what a lip-sync consumer cannot schedule.
//

import XCTest
@testable import MLXToolKit

final class TTSTimingsContractTests: XCTestCase {

    private let hello = TTSWordTiming(text: "hello", start: 0.12, duration: 0.31)
    private let world = TTSWordTiming(text: "world", start: 0.48, duration: 0.40)

    // MARK: - Inert for existing call sites

    func testPre165CallSitesCompileAndCarryNoTimings() {
        let response = TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
        XCTAssertNil(response.timings)
        let chunk = TTSStreamChunk(samples: [0], sampleRate: 24_000, index: 0, isFinal: true)
        XCTAssertNil(chunk.timings)
        let request = TTSRequest(text: "hi", targetDuration: 2, mode: .neutral)
        XCTAssertNil(request.timingDetail)
        let controls = TTSControls(emotionModes: [.categorical], supportsTargetDuration: true)
        XCTAssertNil(controls.timings)
        XCTAssertFalse(controls.providesWordTimings)
        XCTAssertFalse(controls.providesPhonemeTimings)
    }

    func testPre165JSONDecodes() throws {
        let dec = JSONDecoder()
        let chunk = try dec.decode(TTSStreamChunk.self, from: Data(
            #"{"samples":[0.5],"sampleRate":24000,"index":0,"isFinal":true}"#.utf8))
        XCTAssertNil(chunk.timings)
        let controls = try dec.decode(TTSControls.self, from: Data(
            #"{"emotionModes":[],"supportsTargetDuration":false}"#.utf8))
        XCTAssertNil(controls.timings)
        let request = try dec.decode(TTSRequest.self, from: Data(
            #"{"text":"hi","voice":{"selection":{"auto":{}}},"metaData":{}}"#.utf8))
        XCTAssertNil(request.timingDetail)
        let response = try dec.decode(TTSResponse.self, from: JSONEncoder().encode(
            TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))))
        XCTAssertNil(response.timings)
    }

    // MARK: - Round trips

    func testTimingsRoundTripOnResponseChunkAndRequest() throws {
        let timings = TTSTimings(
            words: [hello, world],
            phonemes: [TTSPhonemeTiming(symbol: "h", start: 0.12, duration: 0.05, wordIndex: 0),
                       TTSPhonemeTiming(symbol: "ə", start: 0.17, duration: 0.06, wordIndex: 0),
                       TTSPhonemeTiming(symbol: "w", start: 0.48, duration: 0.07)],
            phonemeAlphabet: .misaki)
        let enc = JSONEncoder(), dec = JSONDecoder()

        let response = TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)), timings: timings)
        XCTAssertEqual(try dec.decode(TTSResponse.self, from: enc.encode(response)).timings, timings)

        let chunk = TTSStreamChunk(samples: [0.1], sampleRate: 24_000, index: 2, isFinal: false,
                                   timings: timings)
        XCTAssertEqual(try dec.decode(TTSStreamChunk.self, from: enc.encode(chunk)), chunk)

        let request = TTSRequest(text: "hello world", timingDetail: .phonemes)
        XCTAssertEqual(try dec.decode(TTSRequest.self, from: enc.encode(request)).timingDetail, .phonemes)
        // The list initializer carries it too.
        XCTAssertEqual(TTSRequest(text: "a", speakers: [], timingDetail: .words).timingDetail, .words)

        let declared = TTSControls(timings: TTSTimingDeclaration(
            source: .native, phonemeAlphabet: "espeak", wordResolution: 0.067, streamed: true))
        XCTAssertEqual(try dec.decode(TTSControls.self, from: enc.encode(declared)), declared)
        XCTAssertTrue(declared.providesWordTimings)
        XCTAssertTrue(declared.providesPhonemeTimings)
        XCTAssertEqual(hello.end, 0.43, accuracy: 1e-12)
    }

    // MARK: - Declaration

    func testDeclarationCoversPhonemesOnlyWithAnAlphabet() {
        let wordsOnly = TTSTimingDeclaration(source: .aligned)
        XCTAssertTrue(wordsOnly.covers(.words))
        XCTAssertFalse(wordsOnly.covers(.phonemes))
        XCTAssertFalse(wordsOnly.streamed)
        let withPhonemes = TTSTimingDeclaration(source: .native, phonemeAlphabet: .ipa)
        XCTAssertTrue(withPhonemes.covers(.phonemes))
        XCTAssertFalse(TTSControls(timings: wordsOnly).providesPhonemeTimings)
    }

    // A planner is never offered a knob the surface would ignore.
    func testTheDescriptorAdvertisesTimingDetailOnlyWhenDeclared() {
        let plain = TTSContract.descriptor(name: "p", summary: "s")
        XCTAssertFalse(plain.parameters.contains { $0.name == "timingDetail" })
        let words = TTSContract.descriptor(
            name: "w", summary: "s",
            controls: TTSControls(timings: TTSTimingDeclaration(source: .aligned)))
        let wordParam = words.parameters.first { $0.name == "timingDetail" }
        XCTAssertNotNil(wordParam)
        XCTAssertFalse(wordParam?.summary?.contains("phonemes") ?? true)
        let phonemes = TTSContract.descriptor(
            name: "k", summary: "s",
            controls: TTSControls(timings: TTSTimingDeclaration(source: .native,
                                                                phonemeAlphabet: .misaki)))
        XCTAssertTrue(phonemes.parameters.first { $0.name == "timingDetail" }?
            .summary?.contains("phonemes (misaki)") ?? false)
        XCTAssertEqual(phonemes.ttsControls?.providesPhonemeTimings, true)
    }

    // MARK: - Shape

    func testShapeProblemAcceptsWellFormedTimings() {
        XCTAssertNil(TTSTimings(words: []).shapeProblem)
        XCTAssertNil(TTSTimings(words: [hello, world]).shapeProblem)
        // Equal starts are allowed (a zero-length word at a boundary).
        XCTAssertNil(TTSTimings(words: [hello, TTSWordTiming(text: "a", start: 0.12, duration: 0)])
            .shapeProblem)
    }

    func testShapeProblemRefusesWhatALipSyncConsumerCannotSchedule() {
        XCTAssertNotNil(TTSTimings(words: [world, hello]).shapeProblem)            // out of order
        XCTAssertNotNil(TTSTimings(words: [TTSWordTiming(text: "x", start: -0.1, duration: 0.2)])
            .shapeProblem)
        XCTAssertNotNil(TTSTimings(words: [TTSWordTiming(text: "x", start: 0, duration: -1)])
            .shapeProblem)
        XCTAssertNotNil(TTSTimings(words: [TTSWordTiming(text: "x", start: .nan, duration: 1)])
            .shapeProblem)
        XCTAssertNotNil(TTSTimings(words: [TTSWordTiming(text: "x", start: 0, duration: .infinity)])
            .shapeProblem)
        // Phonemes without the alphabet they are written in.
        let bare = TTSTimings(words: [hello],
                              phonemes: [TTSPhonemeTiming(symbol: "h", start: 0.12, duration: 0.05)])
        XCTAssertEqual(bare.shapeProblem, "phonemes without a phonemeAlphabet")
        let badIndex = TTSTimings(
            words: [hello],
            phonemes: [TTSPhonemeTiming(symbol: "h", start: 0.12, duration: 0.05, wordIndex: -1)],
            phonemeAlphabet: .ipa)
        XCTAssertNotNil(badIndex.shapeProblem)
    }

    // MARK: - Concatenation

    func testConcatenatingJoinsChunkTimingsInStreamOrder() {
        XCTAssertNil(TTSTimings.concatenating([nil, nil]))
        let a = TTSTimings(words: [hello],
                           phonemes: [TTSPhonemeTiming(symbol: "h", start: 0.12, duration: 0.05,
                                                       wordIndex: 0)],
                           phonemeAlphabet: .ipa)
        let b = TTSTimings(words: [world])
        let joined = TTSTimings.concatenating([nil, a, nil, b])
        XCTAssertEqual(joined?.words, [hello, world])
        XCTAssertEqual(joined?.phonemes?.count, 1)
        XCTAssertEqual(joined?.phonemeAlphabet, .ipa)
        XCTAssertNil(TTSTimings.concatenating([b])?.phonemes)
    }

    func testThePhonemeAlphabetIsOpen() {
        let custom: TTSPhonemeAlphabet = "x-sampa"
        XCTAssertEqual(custom.rawValue, "x-sampa")
        XCTAssertEqual(TTSPhonemeAlphabet(rawValue: "ipa"), .ipa)
    }
}
