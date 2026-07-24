//
//  StreamingConformanceTests.swift
//  MLXServeConformanceTests
//
//  Self-tests for the STR gate (contract 1.25.0): STR-1 coherence both directions, STR-2
//  pre-cancelled runStream, STR-3 posture, and the STR-4/5 live validators on synthetic chunks.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeConformance

// MARK: - Mocks

private func mockTTSManifest(streaming: StreamGranularity?) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/mock-tts", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]
        ),
        surfaces: [TTSContract.descriptor(name: "mock-tts", summary: "mock",
                                          streaming: streaming)]
    )
}

@InferenceActor
private final class CoherentStreamer: ModelPackage, StreamEmitting {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockTTSManifest(streaming: .audioChunk)
    }
    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try Task.checkCancellation()
        guard loaded else { throw PackageError.notLoaded }
        return TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse {
        try Task.checkCancellation()   // entry checkpoint FIRST (STR-2's pass condition)
        guard loaded else { throw PackageError.notLoaded }
        emit(TTSStreamChunk(samples: [0], sampleRate: 22_050, index: 0, isFinal: true))
        return TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
}

/// Conforms but never advertises (STR-1 failure, direction 2).
@InferenceActor
private final class UnadvertisedStreamer: ModelPackage, StreamEmitting {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockTTSManifest(streaming: nil)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
}

/// Advertises but doesn't conform (STR-1 failure, direction 1).
@InferenceActor
private final class LyingBatchPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockTTSManifest(streaming: .audioChunk)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
}

/// Emits BEFORE its entry checkpoint (STR-2 zero-chunk failure).
@InferenceActor
private final class EagerEmitter: ModelPackage, StreamEmitting {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockTTSManifest(streaming: .audioChunk)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse {
        emit(TTSStreamChunk(samples: [0], sampleRate: 22_050, index: 0, isFinal: false))
        try Task.checkCancellation()   // too late
        return TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
}

// MARK: - STR-1

@Test func str1PassesForCoherentStreamer() {
    #expect(StreamingConformance.checkAdvertisement(CoherentStreamer.self).passed)
}

@Test func str1PassesForHonestBatchPackage() {
    // A plain batch package that neither advertises nor conforms.
    #expect(StreamingConformance.checkAdvertisement(HonestBatch.self).passed)
}

@InferenceActor
private final class HonestBatch: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockTTSManifest(streaming: nil)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data()))
    }
}

@Test func str1FailsWhenAdvertisedWithoutConformance() {
    #expect(!StreamingConformance.checkAdvertisement(LyingBatchPackage.self).passed)
}

@Test func str1FailsWhenConformingWithoutAdvertisement() {
    #expect(!StreamingConformance.checkAdvertisement(UnadvertisedStreamer.self).passed)
}

// MARK: - STR-2

@Test func str2PassesForEntryCheckpointedStream() async {
    let pkg = CoherentStreamer(configuration: StandardConfiguration(weightsRepo: "mock/mock"))
    let report = await StreamingConformance.checkPreCancelledStream(
        package: pkg, request: TTSRequest(text: "hi"))
    #expect(report.passed, "\(report.summary)")
}

@Test func str2FailsWhenChunkEmittedBeforeCheckpoint() async {
    let pkg = EagerEmitter(configuration: StandardConfiguration(weightsRepo: "mock/mock"))
    let report = await StreamingConformance.checkPreCancelledStream(
        package: pkg, request: TTSRequest(text: "hi"))
    #expect(!report.passed)
}

// MARK: - STR-3

@Test func str3RequiresPostureWhenAdvertised() {
    #expect(!StreamingConformance.checkPosture(CoherentStreamer.self, posture: nil).passed)
    let posture = StreamingConformance.StreamPosture(
        chunkFrames: 12, leftContextFrames: 32, sampleRate: 22_050, reportsRunProgress: true)
    #expect(StreamingConformance.checkPosture(CoherentStreamer.self, posture: posture).passed)
}

// MARK: - STR-4 / STR-5 validators

private func chunk(_ index: Int, samples: [Float], final: Bool = false,
                   rate: Int = 22_050) -> TTSStreamChunk {
    TTSStreamChunk(samples: samples, sampleRate: rate, index: index, isFinal: final)
}

@Test func str4AcceptsWellFormedSequence() {
    let chunks = [chunk(0, samples: [0.1]), chunk(1, samples: [0.2]),
                  chunk(2, samples: [0.3], final: true)]
    #expect(StreamingConformance.checkSequence(chunks).passed)
}

@Test func str4RejectsGapsAndMisplacedFinal() {
    #expect(!StreamingConformance.checkSequence(
        [chunk(0, samples: [0.1]), chunk(2, samples: [0.2], final: true)]).passed)
    #expect(!StreamingConformance.checkSequence(
        [chunk(0, samples: [0.1], final: true), chunk(1, samples: [0.2])]).passed)
}

@Test func str4TruncatedStreamHasNoFinalMarker() {
    let truncated = [chunk(0, samples: [0.1]), chunk(1, samples: [0.2])]
    #expect(StreamingConformance.checkSequence(truncated, expectTruncated: true).passed)
    #expect(!StreamingConformance.checkSequence(truncated).passed)
}

@Test func str5ParityExactAndTolerant() {
    let chunks = [chunk(0, samples: [0.1, 0.2]), chunk(1, samples: [0.3], final: true)]
    #expect(StreamingConformance.checkAggregationParity(
        chunks: chunks, aggregated: [0.1, 0.2, 0.3]).passed)
    #expect(!StreamingConformance.checkAggregationParity(
        chunks: chunks, aggregated: [0.1, 0.2, 0.5]).passed)
    #expect(StreamingConformance.checkAggregationParity(
        chunks: chunks, aggregated: [0.1, 0.2, 0.300004], tolerance: 1e-4).passed)
    #expect(!StreamingConformance.checkAggregationParity(
        chunks: chunks, aggregated: [0.1, 0.2]).passed)   // length mismatch
}
