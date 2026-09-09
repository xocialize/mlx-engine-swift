//
//  LiveTranscriptionConformanceTests.swift
//  MLXServeConformanceTests
//
//  The LIV-1..6 gate exercised in both directions (contract 1.39.0, companion N2). A gate that
//  only ever sees conformant input proves nothing, so every check here is run against a package
//  built to fail it as well as one built to pass it.
//
//  The mock is deliberately shaped like a real live package — `push` copies and enqueues, a
//  driver task hops onto `@InferenceActor` per buffer — with a table lookup where MLX would be.
//  That is what makes LIV-3 meaningful offline.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeConformance

// MARK: - The mock live session

/// Faults a mock can be built with, so each gate check has something to catch.
struct LiveFaults: Sendable {
    /// Emit cumulative text while declaring `.incremental` (LIV-2's target failure).
    var cumulativeTextUnderIncrementalLabel = false
    /// Let `committedThrough` retreat (LIV-4).
    var retreatingWatermark = false
    /// Emit a final chunk from `cancel()` (LIV-6).
    var finalChunkOnCancel = false
    /// Block on the inference actor inside `push` (LIV-3's target failure).
    var blockingPush = false
    /// Drop the last word from the live transcript (LIV-5).
    var divergentFinalTranscript = false
    /// Report a discipline the descriptor did not declare (LIV-1's runtime half).
    var reportedDiscipline: STTStreamDiscipline?
}

/// One "word" per `chunkSeconds` of audio, deterministic, no weights.
enum MockASR {
    static let sampleRate = 16_000
    static let chunkSeconds = 1.0
    static var chunkSamples: Int { Int(Double(sampleRate) * chunkSeconds) }

    /// The single transcription rule BOTH paths use — which is what makes LIV-5 parity a real
    /// check on the mock rather than a tautology: the live path reaches it through pushes and
    /// the batch path through one call, and a bug in either shows up as a mismatch.
    static func wordCount(samples: Int, flushed: Bool) -> Int {
        let whole = samples / chunkSamples
        let rest = samples % chunkSamples
        return whole + ((flushed && rest * 2 >= chunkSamples) ? 1 : 0)
    }

    static func text(words: Int) -> String {
        (0..<words).map { "w\($0)" }.joined(separator: " ")
    }

    static func segments(words: Int, attributed: Bool) -> [STTSegment] {
        (0..<words).map {
            STTSegment(text: "w\($0)", start: Double($0) * chunkSeconds, duration: chunkSeconds,
                       speaker: attributed ? "Speaker \($0 % 2)" : nil)
        }
    }

    static func audio(samples: Int) -> Audio {
        Audio(data: Data(count: samples * MemoryLayout<Float>.size),
              sampleRate: sampleRate, channels: 1)
    }
}

final class MockLiveSession: STTSession, @unchecked Sendable {
    let discipline: STTStreamDiscipline
    let maxBufferedSeconds: Double
    let expectedSampleRate = MockASR.sampleRate
    let updates: AsyncThrowingStream<STTStreamChunk, Error>

    private enum Input: Sendable { case samples(Int), finish }

    private let faults: LiveFaults
    private let attributed: Bool
    private let inputs: AsyncStream<Input>
    private let inputContinuation: AsyncStream<Input>.Continuation
    private let outputs: AsyncThrowingStream<STTStreamChunk, Error>.Continuation

    private let lock = NSLock()
    private var bufferedSamples = 0
    private var totalSamples = 0
    private var emittedWords = 0
    private var chunkIndex = 0
    private var lastWatermark: TimeInterval = 0
    private var ended = false

    private var driver: Task<Void, Never>?

    init(discipline: STTStreamDiscipline, maxBufferedSeconds: Double = 8,
         attributed: Bool = false, faults: LiveFaults = LiveFaults()) {
        self.discipline = faults.reportedDiscipline ?? discipline
        self.maxBufferedSeconds = maxBufferedSeconds
        self.attributed = attributed
        self.faults = faults
        (inputs, inputContinuation) = AsyncStream<Input>.makeStream()
        (updates, outputs) = AsyncThrowingStream<STTStreamChunk, Error>.makeStream()
    }

    func start() {
        driver = Task { @InferenceActor [weak self] in
            guard let self else { return }
            for await item in self.inputs {
                switch item {
                case .samples(let count): self.consume(count)
                case .finish: self.flush(); return
                }
            }
        }
    }

    // ---------------------------------------------------------------- input (audio thread)

    func push(_ samples: [Float], sampleRate: Int) -> PushOutcome {
        if faults.blockingPush {
            // What a package does wrong: reach the model from the audio callback. Simulated by
            // waiting for the inference actor to become free, which is precisely what an
            // `await` inside `push` would cost.
            let gate = DispatchSemaphore(value: 0)
            Task { @InferenceActor in gate.signal() }
            _ = gate.wait(timeout: .now() + 2)
        }
        guard sampleRate == expectedSampleRate else { return .unsupportedSampleRate }
        lock.lock()
        if ended { lock.unlock(); return .ended }
        let capacity = Int(maxBufferedSeconds * Double(sampleRate))
        guard bufferedSamples + samples.count <= capacity else {
            lock.unlock()
            return .overrun
        }
        bufferedSamples += samples.count
        lock.unlock()
        inputContinuation.yield(.samples(samples.count))
        return .accepted
    }

    func finish() {
        lock.lock()
        let alreadyEnded = ended
        lock.unlock()
        guard !alreadyEnded else { return }
        inputContinuation.yield(.finish)
        inputContinuation.finish()
    }

    func cancel() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        lock.unlock()
        if faults.finalChunkOnCancel {
            lock.lock()
            let words = emittedWords
            lock.unlock()
            outputs.yield(makeChunk(words: words, previousWords: max(0, words - 1),
                                    processed: processedSeconds(), isFinal: true))
        }
        inputContinuation.finish()
        driver?.cancel()
        outputs.finish(throwing: CancellationError())
    }

    // ------------------------------------------------------------------ driver (@InferenceActor)

    private func consume(_ count: Int) {
        lock.lock()
        totalSamples += count
        bufferedSamples = max(0, bufferedSamples - count)
        let words = MockASR.wordCount(samples: totalSamples, flushed: false)
        let previous = emittedWords
        emittedWords = words
        let stop = ended
        lock.unlock()
        guard !stop, words > previous else { return }
        outputs.yield(makeChunk(words: words, previousWords: previous,
                                processed: processedSeconds(), isFinal: false))
    }

    private func flush() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        var words = MockASR.wordCount(samples: totalSamples, flushed: true)
        if faults.divergentFinalTranscript { words = max(0, words - 1) }
        let previous = emittedWords
        emittedWords = words
        lock.unlock()
        // The tail flush may add no word at all (the audio divided evenly). The final chunk is
        // still emitted — `isFinal` marks the end of the SESSION — and under `.incremental` it
        // carries no text, which is the honest thing and must not corrupt the assembly.
        outputs.yield(makeChunk(words: words, previousWords: previous,
                                processed: processedSeconds(), isFinal: true))
        outputs.finish()
    }

    private func processedSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Double(totalSamples) / Double(MockASR.sampleRate)
    }

    private func makeChunk(words: Int, previousWords: Int, processed: Double,
                           isFinal: Bool) -> STTStreamChunk {
        lock.lock()
        let index = chunkIndex
        chunkIndex += 1
        var watermark = processed
        if faults.retreatingWatermark, index > 0 { watermark = max(0, lastWatermark - 0.5) }
        lastWatermark = watermark
        lock.unlock()

        let text: String
        let segments: [STTSegment]
        switch discipline {
        case .cumulative:
            text = MockASR.text(words: words)
            segments = MockASR.segments(words: words, attributed: attributed)
        case .incremental:
            if faults.cumulativeTextUnderIncrementalLabel {
                text = MockASR.text(words: words)
                segments = MockASR.segments(words: words, attributed: attributed)
            } else {
                let fresh = MockASR.segments(words: words, attributed: attributed)
                    .suffix(from: min(max(0, previousWords), words))
                segments = Array(fresh)
                let joined = fresh.map(\.text).joined(separator: " ")
                // The package carries the separator: a leading space on every chunk but the
                // first, and nothing at all when the chunk adds no words.
                text = joined.isEmpty ? "" : ((index == 0 ? "" : " ") + joined)
            }
        }
        return STTStreamChunk(text: text, segments: segments, detectedLanguage: "en-US",
                              processedSeconds: processed, committedThrough: watermark,
                              index: index, isFinal: isFinal)
    }
}

// MARK: - Mock packages, one per LIV-1 quadrant

private func liveManifest(_ surfaces: [ToolDescriptor]) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/live", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

/// Declares `.cumulative` AND conforms — the Nemotron shape.
@InferenceActor
final class CumulativeLivePackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(
            name: "mock-cumulative", summary: "m",
            controls: STTControls(liveDiscipline: .cumulative))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try batchTranscribe(request)
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        let session = MockLiveSession(discipline: .cumulative)
        session.start()
        return session
    }
}

/// Declares `.incremental` AND conforms — the VibeVoice-ASR-Streaming shape.
@InferenceActor
final class IncrementalLivePackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(
            name: "mock-incremental", summary: "m",
            controls: STTControls(attributesSpeakers: true, liveDiscipline: .incremental))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try batchTranscribe(request, attributed: true)
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        let session = MockLiveSession(discipline: .incremental, attributed: true)
        session.start()
        return session
    }
}

/// Declares a discipline but does not conform — the descriptor is lying.
@InferenceActor
final class DeclaresWithoutConformingPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(
            name: "mock-liar", summary: "m",
            controls: STTControls(liveDiscipline: .cumulative))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try batchTranscribe(request)
    }
}

/// Conforms but declares nothing — undiscoverable, and `transcribeLive` refuses it.
@InferenceActor
final class ConformsWithoutDeclaringPackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(name: "mock-hidden", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try batchTranscribe(request)
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        let session = MockLiveSession(discipline: .cumulative)
        session.start()
        return session
    }
}

/// Neither — every STT package shipping before 1.39.0.
@InferenceActor
final class OneShotOnlyPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(name: "mock-oneshot", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try batchTranscribe(request)
    }
}

/// Two `stt` surfaces disagreeing about the discipline — unreachable and consumer-hostile.
@InferenceActor
final class ConflictingDisciplinePackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([
            STTContract.descriptor(name: "mock-a", summary: "m",
                                   controls: STTControls(liveDiscipline: .cumulative)),
            STTContract.descriptor(name: "mock-b", summary: "m",
                                   controls: STTControls(liveDiscipline: .incremental)),
        ])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try batchTranscribe(request)
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        let session = MockLiveSession(discipline: .cumulative)
        session.start()
        return session
    }
}

private func batchTranscribe(_ request: any CapabilityRequest,
                             attributed: Bool = false) throws -> any CapabilityResponse {
    guard let stt = request as? STTRequest else {
        throw PackageError.unsupportedCapability(request.capability)
    }
    let samples = stt.audio.data.count / MemoryLayout<Float>.size
    let words = MockASR.wordCount(samples: samples, flushed: true)
    return STTResponse(text: MockASR.text(words: words),
                       segments: MockASR.segments(words: words, attributed: attributed),
                       detectedLanguage: "en-US")
}

// MARK: - Drivers

/// Feed a session `seconds` of audio in `bufferSeconds` slices and collect every chunk.
@discardableResult
func driveSession(_ session: any STTSession, seconds: Double,
                  bufferSeconds: Double = 0.25) async throws -> [STTStreamChunk] {
    let collected = Task { () -> [STTStreamChunk] in
        var chunks: [STTStreamChunk] = []
        for try await chunk in session.updates { chunks.append(chunk) }
        return chunks
    }
    let buffer = [Float](repeating: 0, count: Int(bufferSeconds * Double(MockASR.sampleRate)))
    var fed = 0.0
    while fed + bufferSeconds <= seconds + 1e-9 {
        #expect(session.push(buffer, sampleRate: MockASR.sampleRate) == .accepted)
        fed += bufferSeconds
        await Task.yield()
    }
    session.finish()
    return try await collected.value
}

// MARK: - LIV-1

@Test func liv1AcceptsADeclaredAndConformingPackage() {
    let report = LiveTranscriptionConformance.checkAdvertisement(CumulativeLivePackage.self)
    #expect(report.passed, "\(report.summary)")
}

@Test func liv1AcceptsAOneShotPackageUnchanged() {
    // The pre-1.39 fleet must stay conformant without touching anything.
    let report = LiveTranscriptionConformance.checkAdvertisement(OneShotOnlyPackage.self)
    #expect(report.passed, "\(report.summary)")
}

@Test func liv1CatchesADescriptorThatLies() {
    let report = LiveTranscriptionConformance.checkAdvertisement(
        DeclaresWithoutConformingPackage.self)
    #expect(!report.passed)
    #expect(report.summary.contains("does not conform"))
}

@Test func liv1CatchesAnUndiscoverableConformance() {
    let report = LiveTranscriptionConformance.checkAdvertisement(
        ConformsWithoutDeclaringPackage.self)
    #expect(!report.passed)
    #expect(report.summary.contains("no stt surface declares"))
}

@Test func liv1CatchesConflictingDisciplineDeclarations() {
    let report = LiveTranscriptionConformance.checkAdvertisement(
        ConflictingDisciplinePackage.self)
    #expect(!report.passed)
    #expect(report.summary.contains("conflicting disciplines"))
}

@Test func liv1CatchesASessionThatContradictsTheDeclaration() {
    // The failure a chunk cannot show: the descriptor says replace, the session says append.
    let honest = MockLiveSession(discipline: .cumulative)
    #expect(LiveTranscriptionConformance
        .checkSessionMatchesDeclaration(CumulativeLivePackage.self, session: honest).passed)

    let lying = MockLiveSession(discipline: .cumulative,
                                faults: LiveFaults(reportedDiscipline: .incremental))
    let report = LiveTranscriptionConformance
        .checkSessionMatchesDeclaration(CumulativeLivePackage.self, session: lying)
    #expect(!report.passed)
    #expect(report.summary.contains("session reports incremental"))
}

@Test func liv1RequiresAPositiveBufferCapacity() {
    let noCapacity = MockLiveSession(discipline: .cumulative, maxBufferedSeconds: 0)
    let report = LiveTranscriptionConformance
        .checkSessionMatchesDeclaration(CumulativeLivePackage.self, session: noCapacity)
    #expect(!report.passed)
    #expect(report.summary.contains("maxBufferedSeconds must be positive"))
}

// MARK: - LIV-2

@Test func liv2AcceptsAGenuinelyCumulativeStream() async throws {
    let session = MockLiveSession(discipline: .cumulative)
    session.start()
    let chunks = try await driveSession(session, seconds: 4)
    let report = LiveTranscriptionConformance.checkDiscipline(chunks, declared: .cumulative)
    #expect(report.passed, "\(report.summary)")
    #expect(STTStreamDiscipline.cumulative.assemble(chunks) == MockASR.text(words: 4))
}

@Test func liv2AcceptsAGenuinelyIncrementalStream() async throws {
    let session = MockLiveSession(discipline: .incremental, attributed: true)
    session.start()
    let chunks = try await driveSession(session, seconds: 4)
    let report = LiveTranscriptionConformance.checkDiscipline(chunks, declared: .incremental)
    #expect(report.passed, "\(report.summary)")
    #expect(STTStreamDiscipline.incremental.assemble(chunks) == MockASR.text(words: 4))
}

@Test func liv2CatchesACumulativeStreamWearingTheIncrementalLabel() async throws {
    // The exact failure the declaration exists to prevent: a consumer appending these chunks
    // ends up with "w0 w0 w1 w0 w1 w2 …".
    let session = MockLiveSession(
        discipline: .incremental,
        faults: LiveFaults(cumulativeTextUnderIncrementalLabel: true))
    session.start()
    let chunks = try await driveSession(session, seconds: 4)
    let report = LiveTranscriptionConformance.checkDiscipline(chunks, declared: .incremental)
    #expect(!report.passed)
    #expect(report.summary.contains("declared .incremental"))
    // And the damage it would have done, stated:
    #expect(STTStreamDiscipline.incremental.assemble(chunks) != MockASR.text(words: 4))
}

@Test func liv2SaysSoWhenItCouldNotCheckAnything() {
    // "Vacuously passed" is not "passed", and a gate that hides the difference is decoration.
    let unwatermarked = (0..<3).map {
        STTStreamChunk(text: "w\($0)", processedSeconds: Double($0), committedThrough: nil,
                       index: $0, isFinal: $0 == 2)
    }
    let report = LiveTranscriptionConformance.checkDiscipline(unwatermarked,
                                                             declared: .cumulative)
    #expect(report.passed)
    #expect(report.summary.contains("VACUOUS"))
}

// MARK: - LIV-3

@Test func liv3AcceptsACopyOnlyPush() async {
    let session = MockLiveSession(discipline: .cumulative)
    session.start()
    let report = await LiveTranscriptionConformance.checkPushIsNonBlocking(session: session)
    #expect(report.passed, "\(report.summary)")
    session.cancel()
}

@Test func liv3CatchesAPushThatWaitsOnTheInferenceActor() async {
    // The known failure: MLX (or anything else on `@InferenceActor`) reached from the audio
    // callback. On a real tap this is a dropout, not a slow function.
    let session = MockLiveSession(discipline: .cumulative,
                                  faults: LiveFaults(blockingPush: true))
    session.start()
    let report = await LiveTranscriptionConformance.checkPushIsNonBlocking(
        session: session, pushes: 2, holdSeconds: 0.4, budgetSeconds: 0.05)
    #expect(!report.passed)
    #expect(report.summary.contains("awaiting the actor"))
    session.cancel()
}

// MARK: - LIV-4

@Test func liv4AcceptsAWellFormedSequence() async throws {
    let session = MockLiveSession(discipline: .cumulative)
    session.start()
    let chunks = try await driveSession(session, seconds: 3)
    let report = LiveTranscriptionConformance.checkSequence(chunks)
    #expect(report.passed, "\(report.summary)")
    #expect(chunks.last?.isFinal == true)
}

@Test func liv4CatchesARetreatingWatermark() async throws {
    let session = MockLiveSession(discipline: .cumulative,
                                  faults: LiveFaults(retreatingWatermark: true))
    session.start()
    let chunks = try await driveSession(session, seconds: 3)
    let report = LiveTranscriptionConformance.checkSequence(chunks)
    #expect(!report.passed)
    #expect(report.summary.contains("watermark retreats"))
}

@Test func liv4CatchesAMixedWatermarkPresence() {
    // A caption UI decides ONCE whether it can render a provisional tail; a stream that changes
    // its mind mid-session makes that decision unmakeable.
    let mixed = [
        STTStreamChunk(text: "a", processedSeconds: 1, committedThrough: 1, index: 0,
                       isFinal: false),
        STTStreamChunk(text: "b", processedSeconds: 2, committedThrough: nil, index: 1,
                       isFinal: true),
    ]
    let report = LiveTranscriptionConformance.checkSequence(mixed)
    #expect(!report.passed)
    #expect(report.summary.contains("decide once"))
}

@Test func liv4RejectsAFinalChunkOnATruncatedSession() {
    let truncated = [STTStreamChunk(text: "a", processedSeconds: 1, index: 0, isFinal: true)]
    #expect(!LiveTranscriptionConformance.checkSequence(truncated, expectTruncated: true).passed)
    #expect(LiveTranscriptionConformance.checkSequence([], expectTruncated: true).passed)
}

// MARK: - LIV-5

@Test func liv5PassesWhenTheLiveAndBatchPathsAgree() async throws {
    let package = CumulativeLivePackage(configuration: StandardConfiguration(weightsRepo: "m"))
    let session = try await package.startLiveTranscription(STTSessionRequest())
    let chunks = try await driveSession(session, seconds: 5)
    let batch = try await package.run(STTRequest(audio: MockASR.audio(samples: 5 * 16_000)))
    let report = LiveTranscriptionConformance.checkFinalParity(
        chunks: chunks, discipline: .cumulative,
        batchTranscript: (batch as! STTResponse).text)
    #expect(report.passed, "\(report.summary)")
}

@Test func liv5PassesForTheIncrementalDisciplineToo() async throws {
    let package = IncrementalLivePackage(configuration: StandardConfiguration(weightsRepo: "m"))
    let session = try await package.startLiveTranscription(STTSessionRequest())
    let chunks = try await driveSession(session, seconds: 5)
    let batch = try await package.run(STTRequest(audio: MockASR.audio(samples: 5 * 16_000)))
    let report = LiveTranscriptionConformance.checkFinalParity(
        chunks: chunks, discipline: .incremental,
        batchTranscript: (batch as! STTResponse).text)
    #expect(report.passed, "\(report.summary)")
}

@Test func liv5CatchesALivePathThatHasDivergedFromTheBatchPath() async throws {
    // The STR-5 analogue: same model, same audio, different answer. Nothing else in the gate
    // sees this — the stream is perfectly well-formed.
    let session = MockLiveSession(discipline: .cumulative,
                                  faults: LiveFaults(divergentFinalTranscript: true))
    session.start()
    let chunks = try await driveSession(session, seconds: 5)
    #expect(LiveTranscriptionConformance.checkSequence(chunks).passed)
    let report = LiveTranscriptionConformance.checkFinalParity(
        chunks: chunks, discipline: .cumulative,
        batchTranscript: MockASR.text(words: 5))
    #expect(!report.passed)
    #expect(report.summary.contains("word error rate"))
}

@Test func liv5ToleranceIsAWordErrorRate() {
    let chunks = [STTStreamChunk(text: "w0 w1 w2 w9", processedSeconds: 4, index: 0,
                                 isFinal: true)]
    let strict = LiveTranscriptionConformance.checkFinalParity(
        chunks: chunks, discipline: .cumulative, batchTranscript: "w0 w1 w2 w3")
    #expect(!strict.passed)                       // one substitution in four words = 0.25
    let lenient = LiveTranscriptionConformance.checkFinalParity(
        chunks: chunks, discipline: .cumulative, batchTranscript: "w0 w1 w2 w3", tolerance: 0.25)
    #expect(lenient.passed)
}

@Test func liv5NormalizesWhitespaceButNotCaseOrPunctuation() {
    // Punctuation and capitalization are output the contract promises; folding them away here
    // would hide a real divergence between the two paths.
    let spaced = [STTStreamChunk(text: "  hello   there\n", processedSeconds: 1, index: 0,
                                 isFinal: true)]
    #expect(LiveTranscriptionConformance.checkFinalParity(
        chunks: spaced, discipline: .cumulative, batchTranscript: "hello there").passed)
    let cased = [STTStreamChunk(text: "hello there", processedSeconds: 1, index: 0,
                                isFinal: true)]
    #expect(!LiveTranscriptionConformance.checkFinalParity(
        chunks: cased, discipline: .cumulative, batchTranscript: "Hello there.").passed)
}

// MARK: - LIV-6

@Test func liv6AcceptsACleanCancel() async {
    let session = MockLiveSession(discipline: .cumulative)
    session.start()
    let feed = [[Float]](repeating: [Float](repeating: 0, count: 8_000), count: 4)
    let report = await LiveTranscriptionConformance.checkCancelSemantics(session: session,
                                                                        feed: feed)
    #expect(report.passed, "\(report.summary)")
}

@Test func liv6CatchesAFinalChunkOnCancel() async {
    // `finish()` means "flush and commit"; `cancel()` means "throw it away". A final chunk on
    // the cancel path tells a consumer it has a transcript it should keep.
    let session = MockLiveSession(discipline: .cumulative,
                                  faults: LiveFaults(finalChunkOnCancel: true))
    session.start()
    let feed = [[Float]](repeating: [Float](repeating: 0, count: 8_000), count: 4)
    let report = await LiveTranscriptionConformance.checkCancelSemantics(session: session,
                                                                        feed: feed)
    #expect(!report.passed)
    #expect(report.summary.contains("final chunk(s) on a cancelled session"))
}
