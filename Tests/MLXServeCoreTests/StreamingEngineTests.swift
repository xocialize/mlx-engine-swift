//
//  StreamingEngineTests.swift
//  MLXServeCoreTests
//
//  Offline coverage for the 1.25.0 streaming seam (`stream()`/`streamAttempt`) with mock
//  packages — chunk delivery, completion resolution, the streamingUnsupported gate, the
//  single-error-channel admission path, and the abandoned-stream → run-cancel guarantee.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

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

/// Emits `chunkCount` chunks of 4 ramp samples each, then returns the aggregated response.
@InferenceActor
private final class MockStreamingTTSPackage: ModelPackage, StreamEmitting {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockTTSManifest(streaming: .audioChunk) }

    static let chunkCount = 3
    static let rate = 22_050

    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }

    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try Task.checkCancellation()
        guard loaded else { throw PackageError.notLoaded }
        return TTSResponse(audio: Audio(format: .wav, data: Data(count: 44),
                                        sampleRate: Self.rate, channels: 1))
    }

    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse {
        try Task.checkCancellation()
        guard loaded else { throw PackageError.notLoaded }
        var all: [Float] = []
        for index in 0..<Self.chunkCount {
            try Task.checkCancellation()
            let samples = (0..<4).map { Float(index * 4 + $0) / 100 }
            all += samples
            emit(TTSStreamChunk(samples: samples, sampleRate: Self.rate, index: index,
                                isFinal: index == Self.chunkCount - 1))
        }
        return TTSResponse(audio: Audio(format: .wav, data: wav16(all, rate: Self.rate),
                                        sampleRate: Self.rate, channels: 1))
    }

    private nonisolated func wav16(_ samples: [Float], rate: Int) -> Data {
        var data = Data(count: 44)   // header contents irrelevant to these tests
        for sample in samples {
            var le = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Batch-only TTS package (no StreamEmitting conformance).
@InferenceActor
private final class MockBatchTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockTTSManifest(streaming: nil) }
    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

/// Emits one chunk, then loops with cancellation checkpoints until cancelled — for the
/// abandoned-stream test. Records whether it observed the cancellation.
@InferenceActor
private final class MockHangingStreamPackage: ModelPackage, StreamEmitting {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockTTSManifest(streaming: .audioChunk) }

    nonisolated(unsafe) static var observedCancellation = false

    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }

    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse {
        try Task.checkCancellation()
        emit(TTSStreamChunk(samples: [0.1], sampleRate: 22_050, index: 0, isFinal: false))
        do {
            for _ in 0..<200 {   // ~10 s ceiling; the test cancels long before
                try await Task.sleep(nanoseconds: 50_000_000)
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            Self.observedCancellation = true
            throw CancellationError()
        }
        throw PackageError.unsupportedCapability(.tts)   // never reached
    }
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }
private func request() -> TTSRequest { TTSRequest(text: "hello") }

// MARK: - Tests

@Test func streamDeliversOrderedChunksAndCompletion() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockStreamingTTSPackage.self),
                              configuration: mockConfig())

    let handle = await engine.stream(request())
    var chunks: [TTSStreamChunk] = []
    for try await chunk in handle.chunks { chunks.append(chunk) }

    #expect(chunks.map(\.index) == [0, 1, 2])
    #expect(chunks.map(\.isFinal) == [false, false, true])
    #expect(Set(chunks.map(\.sampleRate)) == [22_050])

    let response = try await handle.completion.value
    // Aggregated response carries all streamed samples (44-byte header + 12 × 2 bytes).
    #expect(response.audio.data.count == 44 + 12 * 2)
}

@Test func streamOnBatchOnlyPackageThrowsStreamingUnsupported() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockBatchTTSPackage.self),
                              configuration: mockConfig())

    let handle = await engine.stream(request())
    do {
        for try await _ in handle.chunks { Issue.record("no chunks expected") }
        Issue.record("expected streamingUnsupported")
    } catch let error as EngineError {
        #expect(error == .streamingUnsupported("mock-tts"))
    }
    // The completion task fails with the same error (single error channel).
    do {
        _ = try await handle.completion.value
        Issue.record("expected completion failure")
    } catch let error as EngineError {
        #expect(error == .streamingUnsupported("mock-tts"))
    }
}

@Test func streamWithoutRegistrationSurfacesNoPackageThroughStream() async {
    let engine = MLXServeEngine()
    let handle = await engine.stream(request())
    do {
        for try await _ in handle.chunks {}
        Issue.record("expected noPackage")
    } catch let error as EngineError {
        #expect(error == .noPackage(.tts))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func handleCancelStopsTheRun() async throws {
    MockHangingStreamPackage.observedCancellation = false
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockHangingStreamPackage.self),
                              configuration: mockConfig())

    let handle = await engine.stream(request())
    // Consume the first chunk, then cancel via the handle (the app's Stop button).
    do {
        for try await chunk in handle.chunks {
            #expect(chunk.index == 0)
            handle.cancel()
        }
        Issue.record("expected the stream to terminate with CancellationError")
    } catch {
        #expect(error is CancellationError)
    }
    // The completion resolves with the cancellation (never hangs).
    do {
        _ = try await handle.completion.value
        Issue.record("expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(MockHangingStreamPackage.observedCancellation)
}

@Test func cancellingTheIteratingTaskCancelsTheRun() async throws {
    MockHangingStreamPackage.observedCancellation = false
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockHangingStreamPackage.self),
                              configuration: mockConfig())

    let handle = await engine.stream(request())
    // Iterate in a child task; cancel it after the first chunk arrives (the app pattern:
    // a playback task the user tears down). Task cancel during next() → .cancelled
    // termination → onTermination cancels the run.
    let gotFirst = AsyncStream.makeStream(of: Void.self)
    let consumer = Task {
        for try await chunk in handle.chunks {
            if chunk.index == 0 { gotFirst.continuation.finish() }
        }
    }
    for await _ in gotFirst.stream {}
    consumer.cancel()
    _ = await consumer.result

    do {
        _ = try await handle.completion.value
        Issue.record("expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(MockHangingStreamPackage.observedCancellation)
}
