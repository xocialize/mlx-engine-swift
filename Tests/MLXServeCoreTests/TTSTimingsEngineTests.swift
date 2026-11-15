//
//  TTSTimingsEngineTests.swift
//  MLXServeCoreTests
//
//  Contract 1.65.0 — speech timings on TTS (AB-A-0289). The engine refuses `timingDetail` a surface
//  does not declare BEFORE admission (the `targetDuration` pattern), passes a declared one through,
//  and carries chunk and response timings unchanged on both `run` and `stream`.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private func timingManifest(_ controls: TTSControls?, streaming: StreamGranularity? = nil)
    -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/timings", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: [TTSContract.descriptor(name: "timing-tts", summary: "m",
                                          streaming: streaming, controls: controls)])
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/timings") }

private let words = [TTSWordTiming(text: "hello", start: 0.1, duration: 0.3),
                     TTSWordTiming(text: "there", start: 0.45, duration: 0.25),
                     TTSWordTiming(text: "friend", start: 0.75, duration: 0.4)]

/// A cloner that declares nothing (every TTS package before 1.65).
@InferenceActor
private final class NoTimingsTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { timingManifest(nil) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

/// The aligner shape: word timings only, from a forced aligner, not streamed.
@InferenceActor
private final class AlignedWordsTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        timingManifest(TTSControls(timings: TTSTimingDeclaration(source: .aligned,
                                                                 wordResolution: 0.001)))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        let asked = (request as? TTSRequest)?.timingDetail != nil
        return TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)),
                           timings: asked ? TTSTimings(words: words) : nil)
    }
}

/// The ZONOS3 + LACI shape: native, streamed word timings that become final one word late, plus
/// phonemes (to exercise the alphabet path).
@InferenceActor
private final class StreamedTimingsTTSPackage: ModelPackage, StreamEmitting {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        timingManifest(TTSControls(timings: TTSTimingDeclaration(
            source: .native, phonemeAlphabet: .ipa, wordResolution: 0.067, streamed: true)),
                       streaming: .audioChunk)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try await runStream(request) { _ in }
    }
    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse {
        // Chunk 0: no word is final yet. Chunk 1: "hello" (its end known once "there" starts).
        // Chunk 2 (final): the trailing two words and one phoneme.
        let parts: [TTSTimings?] = [
            nil,
            TTSTimings(words: [words[0]]),
            TTSTimings(words: [words[1], words[2]],
                       phonemes: [TTSPhonemeTiming(symbol: "f", start: 0.75, duration: 0.06,
                                                   wordIndex: 2)],
                       phonemeAlphabet: .ipa),
        ]
        for (i, part) in parts.enumerated() {
            emit(TTSStreamChunk(samples: [Float(i)], sampleRate: 24_000, index: i,
                                isFinal: i == parts.count - 1, timings: part))
        }
        return TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)),
                           timings: TTSTimings.concatenating(parts))
    }
}

private func unsupportedFeature(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

// MARK: - Refusal

// The failure this prevents: an avatar host asks a cloner for timings, gets audio alone, and the
// mouth never moves, with nothing in the response saying why.
@Test func timingDetailAgainstAPackageWithoutTimingsIsRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(NoTimingsTTSPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(TTSRequest(text: "hi", timingDetail: .words))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("timingDetail") == true)
        #expect(unsupportedFeature(error)?.contains("providesWordTimings") == true)
    }
    // Asking for nothing is untouched.
    _ = try await engine.run(TTSRequest(text: "hi"))
}

@Test func phonemesAgainstAWordsOnlySurfaceAreRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(AlignedWordsTTSPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(TTSRequest(text: "hi", timingDetail: .phonemes))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("phonemes") == true)
    }
}

// The stream door shares the pre-flight, so the refusal is the stream's terminal throw.
@Test func theStreamDoorRefusesUndeclaredTimingsToo() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(NoTimingsTTSPackage.self),
                              configuration: mockConfig())
    let handle = engine.stream(TTSRequest(text: "hi", timingDetail: .words))
    do {
        for try await _ in handle.chunks {}
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("timingDetail") == true)
    }
}

// MARK: - Pass-through

@Test func declaredWordTimingsReachTheCallerOnRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(AlignedWordsTTSPackage.self),
                              configuration: mockConfig())
    let response = try #require(
        try await engine.run(TTSRequest(text: "hello there friend", timingDetail: .words))
            as? TTSResponse)
    #expect(response.timings?.words == words)
}

@Test func streamedTimingsRideTheChunksAndConcatenateToTheResponse() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(StreamedTimingsTTSPackage.self),
                              configuration: mockConfig())
    let handle = engine.stream(TTSRequest(text: "hello there friend", timingDetail: .phonemes))
    var chunks: [TTSStreamChunk] = []
    for try await chunk in handle.chunks { chunks.append(chunk) }
    let response = try await handle.completion.value

    #expect(chunks.count == 3)
    #expect(chunks[0].timings == nil)
    #expect(chunks[1].timings?.words == [words[0]])
    #expect(TTSTimings.concatenating(chunks.map(\.timings)) == response.timings)
    #expect(response.timings?.words == words)
    #expect(response.timings?.phonemeAlphabet == .ipa)
}
