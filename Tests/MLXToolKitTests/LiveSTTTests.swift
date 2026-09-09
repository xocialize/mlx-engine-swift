//
//  LiveSTTTests.swift
//  MLXToolKitTests
//
//  Contract 1.39.0 — the live-STT plane (companion N2, AB-A-0062 / AB-D-0069). The checks here
//  are about the three properties the pass promised: the addition is INERT for pre-1.39 call
//  sites, the discipline declaration is EXECUTABLE (not prose), and the watermark says something
//  a Bool could not.
//

import XCTest
@testable import MLXToolKit

final class LiveSTTTests: XCTestCase {

    // MARK: - Additivity — every pre-1.39 construction site is untouched

    func testLiveDisciplineIsAdditiveAndDefaultsNil() throws {
        // The 1.38.0 call site VibeVoice's V5 spec was written against still compiles unchanged.
        let shipped = STTControls(attributesSpeakers: true, supportsContextBiasing: true)
        XCTAssertNil(shipped.liveDiscipline)

        let live = STTControls(attributesSpeakers: true, supportsContextBiasing: true,
                               liveDiscipline: .incremental)
        XCTAssertEqual(live.liveDiscipline, .incremental)

        // Optional property ⇒ the synthesized Codable decodes pre-1.39 JSON with no key.
        let old = Data(#"{"attributesSpeakers":true,"supportsContextBiasing":false}"#.utf8)
        let decoded = try JSONDecoder().decode(STTControls.self, from: old)
        XCTAssertNil(decoded.liveDiscipline)
        XCTAssertTrue(decoded.attributesSpeakers)
    }

    func testDescriptorCarriesTheDeclarationThroughSurfaceControls() {
        let descriptor = STTContract.descriptor(
            name: "live-stt", summary: "s",
            controls: STTControls(liveDiscipline: .cumulative))
        XCTAssertEqual(descriptor.sttControls?.liveDiscipline, .cumulative)
        XCTAssertTrue(descriptor.controlsMatchCapability)
        // `streaming` is the StreamEmitting axis and stays nil: a live surface is not a
        // streaming surface, and STR-1 would fail if it claimed to be.
        XCTAssertNil(descriptor.streaming)
    }

    // Live transcription is a different ENTRY POINT, not a knob on `run(STTRequest)` — so unlike
    // `context` it derives no ParameterSchema entry. Advertising one would offer a planner a
    // parameter the one-shot surface cannot honor.
    func testLiveDeclarationAddsNoRequestParameter() {
        let live = STTContract.descriptor(name: "live-stt", summary: "s",
                                          controls: STTControls(liveDiscipline: .incremental))
        let plain = STTContract.descriptor(name: "plain-stt", summary: "s")
        XCTAssertEqual(live.parameters.map(\.name), plain.parameters.map(\.name))

        // …while `context` still does, and the two declarations compose.
        let both = STTContract.descriptor(
            name: "both", summary: "s",
            controls: STTControls(supportsContextBiasing: true, liveDiscipline: .incremental))
        XCTAssertTrue(both.parameters.contains { $0.name == "context" })
    }

    // MARK: - The discipline is executable, not prose

    func testCumulativeAssemblyReplaces() {
        let chunks = [
            chunk(text: "the quick", index: 0, processed: 1),
            chunk(text: "the quick brown", index: 1, processed: 2),
            chunk(text: "the quick brown fox", index: 2, processed: 3, isFinal: true),
        ]
        XCTAssertEqual(STTStreamDiscipline.cumulative.assemble(chunks), "the quick brown fox")
    }

    func testIncrementalAssemblyConcatenatesVerbatim() {
        // The package carries the separator — whether two chunks want a space between them is a
        // fact about the model's tokenization that only the package knows.
        let chunks = [
            chunk(text: "the quick", index: 0, processed: 1),
            chunk(text: " brown", index: 1, processed: 2),
            chunk(text: " fox", index: 2, processed: 3, isFinal: true),
        ]
        XCTAssertEqual(STTStreamDiscipline.incremental.assemble(chunks), "the quick brown fox")
    }

    func testAssemblyOfAnEmptySessionIsEmpty() {
        XCTAssertEqual(STTStreamDiscipline.cumulative.assemble([]), "")
        XCTAssertEqual(STTStreamDiscipline.incremental.assemble([]), "")
    }

    // The two axes are INDEPENDENT, and Nemotron is the proof: greedy RNN-T over a cache-aware
    // encoder delivers cumulatively and never revises. `.cumulative` is a delivery rule, not a
    // claim that anything may change — which is where AB-D-0069's own prose was wrong.
    func testCumulativeDeliveryIsCompatibleWithFullCommitment() {
        let nemotronShaped = chunk(text: "hello there", index: 1, processed: 2.24,
                                   committed: 2.24)
        XCTAssertEqual(nemotronShaped.committedThrough, nemotronShaped.processedSeconds)
    }

    // MARK: - The watermark says what a Bool could not

    func testChunkRoundTripsAndKeepsSpeakerAttribution() throws {
        let original = STTStreamChunk(
            text: "Speaker 0: hello",
            segments: [STTSegment(text: "hello", start: 0.5, duration: 1.0, speaker: "Speaker 0")],
            detectedLanguage: "en-US", processedSeconds: 2.9333,
            committedThrough: 2.4, index: 3, isFinal: false)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(STTStreamChunk.self, from: data), original)
    }

    func testNilWatermarkMeansNoGuaranteeNotZero() throws {
        let unknown = chunk(text: "…", index: 0, processed: 1, committed: nil)
        XCTAssertNil(unknown.committedThrough)
        // Encoded absent, not as 0 — a 0 would claim "nothing is settled", which is a different
        // statement from "this package makes no commitment guarantee".
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(unknown)) as? [String: Any]
        XCTAssertFalse(json?.keys.contains("committedThrough") ?? true)
    }

    // MARK: - STTSessionRequest

    func testSessionRequestIsAnSTTCapabilityRequest() {
        let request = STTSessionRequest(language: "en-US", context: ["MLXEngine"])
        XCTAssertEqual(STTSessionRequest.capability, .stt)
        XCTAssertEqual(request.capability, .stt)
        XCTAssertEqual(request.context, ["MLXEngine"])
        // Defaulted throughout: opening a session needs no arguments.
        XCTAssertNil(STTSessionRequest().language)
    }

    func testPushOutcomeNamesEachReasonAudioWasDropped() {
        // Four cases, not the designed two. Every one of the three failures is something a
        // caller does differently: back off (`.overrun`), convert (`.unsupportedSampleRate`),
        // stop pushing (`.ended`). Collapsing them loses exactly the actionable part.
        let outcomes: Set<PushOutcome> = [.accepted, .overrun, .unsupportedSampleRate, .ended]
        XCTAssertEqual(outcomes.count, 4)
    }

    // MARK: - Helper

    private func chunk(text: String, index: Int, processed: Double,
                       committed: TimeInterval? = nil, isFinal: Bool = false) -> STTStreamChunk {
        STTStreamChunk(text: text, processedSeconds: processed, committedThrough: committed,
                       index: index, isFinal: isFinal)
    }
}
