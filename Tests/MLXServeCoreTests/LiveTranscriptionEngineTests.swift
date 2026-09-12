//
//  LiveTranscriptionEngineTests.swift
//  MLXServeCoreTests
//
//  Offline coverage for the 1.39.0 live-STT seam (`transcribeLive`) — the engine half of
//  companion N2. Residency, refusals, the abandoned-handle rule, the idle watchdog, and the
//  governor's victim ordering, all with mock packages and no MLX.
//
//  The property under test throughout: a session holds RESIDENCY but not `@InferenceActor`.
//  Everything the seam has to get right follows from that asymmetry.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

/// One "word" per second of pushed audio, deterministic, no weights — the same rule on both
/// paths, so a live-vs-batch mismatch means the SEAM broke, not the model.
private enum Mock {
    static let rate = 16_000
    static func words(samples: Int, flushed: Bool) -> Int {
        let whole = samples / rate
        return whole + ((flushed && (samples % rate) * 2 >= rate) ? 1 : 0)
    }
    static func text(_ n: Int) -> String { (0..<n).map { "w\($0)" }.joined(separator: " ") }
    static func audio(seconds: Double) -> Audio {
        Audio(data: Data(count: Int(seconds * Double(rate)) * MemoryLayout<Float>.size),
              sampleRate: rate, channels: 1)
    }
    static func buffer(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }
}

private final class EngineMockSession: STTSession, @unchecked Sendable {
    let discipline: STTStreamDiscipline = .cumulative
    let maxBufferedSeconds: Double
    let expectedSampleRate = Mock.rate
    let updates: AsyncThrowingStream<STTStreamChunk, Error>

    private enum Input: Sendable { case samples(Int), finish }
    private let inputs: AsyncStream<Input>
    private let inputContinuation: AsyncStream<Input>.Continuation
    private let outputs: AsyncThrowingStream<STTStreamChunk, Error>.Continuation
    private let lock = NSLock()
    private var total = 0
    private var emitted = 0
    private var index = 0
    private var ended = false
    private var driver: Task<Void, Never>?
    /// Flips when the session lets go of its model reference — what an evicting engine needs.
    let releasedModel = Flag()

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    init(maxBufferedSeconds: Double = 8) {
        self.maxBufferedSeconds = maxBufferedSeconds
        (inputs, inputContinuation) = AsyncStream<Input>.makeStream()
        (updates, outputs) = AsyncThrowingStream<STTStreamChunk, Error>.makeStream()
        driver = Task { @InferenceActor [weak self] in
            guard let self else { return }
            for await item in self.inputs {
                switch item {
                case .samples(let n): self.consume(n)
                case .finish: self.flush(); return
                }
            }
        }
    }

    func push(_ samples: [Float], sampleRate: Int) -> PushOutcome {
        guard sampleRate == expectedSampleRate else { return .unsupportedSampleRate }
        lock.lock()
        if ended { lock.unlock(); return .ended }
        lock.unlock()
        inputContinuation.yield(.samples(samples.count))
        return .accepted
    }

    func finish() {
        lock.lock(); let done = ended; lock.unlock()
        guard !done else { return }
        inputContinuation.yield(.finish)
        inputContinuation.finish()
    }

    func cancel() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        lock.unlock()
        inputContinuation.finish()
        releasedModel.set()
        outputs.finish(throwing: CancellationError())
    }

    private func consume(_ n: Int) {
        lock.lock()
        total += n
        let words = Mock.words(samples: total, flushed: false)
        let previous = emitted
        emitted = words
        let processed = Double(total) / Double(Mock.rate)
        let i = index
        if words > previous { index += 1 }
        let stop = ended
        lock.unlock()
        guard !stop, words > previous else { return }
        outputs.yield(STTStreamChunk(text: Mock.text(words), processedSeconds: processed,
                                     committedThrough: processed, index: i, isFinal: false))
    }

    private func flush() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        let words = Mock.words(samples: total, flushed: true)
        let processed = Double(total) / Double(Mock.rate)
        let i = index
        index += 1
        lock.unlock()
        outputs.yield(STTStreamChunk(text: Mock.text(words), processedSeconds: processed,
                                     committedThrough: processed, index: i, isFinal: true))
        releasedModel.set()
        outputs.finish()
    }
}

private func liveManifest(_ surfaces: [ToolDescriptor], footprint: UInt64 = 1,
                          repo: String = "mock/live") -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: repo, revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: footprint)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

@InferenceActor
private final class LiveSTTPackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(
            name: "live-stt", summary: "m",
            controls: STTControls(supportsContextBiasing: true, liveDiscipline: .cumulative))],
            footprint: 60)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    private(set) var loaded = false
    /// The last session handed out — so a test can assert the model reference was released.
    /// Per INSTANCE, not static: the suite runs in parallel and a shared static would let one
    /// test read another's session.
    private(set) var lastSession: EngineMockSession?
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let stt = request as? STTRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        let samples = stt.audio.data.count / MemoryLayout<Float>.size
        return STTResponse(text: Mock.text(Mock.words(samples: samples, flushed: true)))
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        guard loaded else { throw PackageError.notLoaded }
        let session = EngineMockSession()
        lastSession = session
        return session
    }
}

/// Declares no live discipline — every STT package shipping before 1.39.0.
@InferenceActor
private final class OneShotSTTPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(name: "oneshot-stt", summary: "m")],
                     repo: "mock/oneshot")
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "batch")
    }
}

/// Conforms to `LiveTranscribing` but declares nothing — LIV-1's undiscoverable quadrant, which
/// the engine refuses rather than quietly honoring.
@InferenceActor
private final class UndeclaredLivePackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([STTContract.descriptor(name: "hidden-stt", summary: "m")],
                     repo: "mock/hidden")
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "batch")
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        EngineMockSession()
    }
}

/// A long-running batch LLM used to test the governor's victim ordering.
@InferenceActor
private final class SlowLLMPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([ToolDescriptor(name: "slow-llm", capability: .llm, summary: "m")],
                     footprint: 60, repo: "mock/slow-llm")
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        for _ in 0..<400 {
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return LLMResponse(text: "done")
    }
}

/// An instant TTS package — the third contender whose admission forces a choice of victim.
@InferenceActor
private final class FastTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        liveManifest([TTSContract.descriptor(name: "fast-tts", summary: "m")],
                     footprint: 60, repo: "mock/fast-tts")
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

private func cfg(_ repo: String = "mock/live") -> StandardConfiguration {
    StandardConfiguration(weightsRepo: repo)
}

private func liveEngine(budget: UInt64 = 10_000,
                        policy: LiveSessionPolicy = LiveSessionPolicy(),
                        preemption: PreemptionPolicy = PreemptionPolicy()) -> MLXServeEngine {
    MLXServeEngine(
        device: DeviceProfile(chipTier: .max,
                              macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                              backends: [.metalGPU], totalMemoryBytes: 64_000_000_000),
        governor: MemoryGovernor(budgetBytes: budget),
        preemption: preemption,
        liveSessions: policy,
        physFootprint: { nil })
}

/// Feed `seconds` of audio in 0.25 s slices, then finish, collecting every chunk.
private func drive(_ handle: STTLiveHandle, seconds: Double) async throws -> [STTStreamChunk] {
    let collected = Task { () -> [STTStreamChunk] in
        var chunks: [STTStreamChunk] = []
        for try await chunk in handle.updates { chunks.append(chunk) }
        return chunks
    }
    let slice = Mock.buffer(seconds: 0.25)
    for _ in 0..<Int(seconds / 0.25) {
        #expect(handle.push(slice, sampleRate: Mock.rate) == .accepted)
        await Task.yield()
    }
    handle.finish()
    return try await collected.value
}

// MARK: - The happy path

@Test func transcribeLiveDeliversChunksAndAFinalTranscript() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest(language: "en-US"))

    #expect(handle.discipline == .cumulative)
    #expect(handle.maxBufferedSeconds == 8)

    let chunks = try await drive(handle, seconds: 4)
    #expect(chunks.count >= 2)
    #expect(chunks.last?.isFinal == true)
    #expect(chunks.map(\.index) == Array(0..<chunks.count))
    #expect(STTStreamDiscipline.cumulative.assemble(chunks) == Mock.text(4))
}

/// LIV-5 through the engine: the seam must not be the thing that makes the two paths differ.
@Test func liveFinalTranscriptMatchesTheBatchPath() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())

    let handle = try await engine.transcribeLive(STTSessionRequest())
    let chunks = try await drive(handle, seconds: 5)
    let batch = try await engine.run(STTRequest(audio: Mock.audio(seconds: 5)))

    #expect(STTStreamDiscipline.cumulative.assemble(chunks) == (batch as? STTResponse)?.text)
}

@Test func aFinishedSessionReleasesResidencyBookkeeping() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest())
    var open = await engine.openLiveSessionCount
    #expect(open == 1)

    _ = try await drive(handle, seconds: 2)
    open = await engine.openLiveSessionCount
    #expect(open == 0)
    // The package stays RESIDENT — a dictation UI's next session should not pay a cold load.
    let snapshot = await engine.memory
    #expect(snapshot.residentBytes == 60)
}

// MARK: - Refusals

@Test func aOneShotPackageIsRefusedBeforeAnythingLoads() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(OneShotSTTPackage.self),
                              configuration: cfg("mock/oneshot"))
    await #expect(throws: EngineError.liveTranscriptionUnsupported("oneshot-stt")) {
        _ = try await engine.transcribeLive(STTSessionRequest())
    }
    // Refused BEFORE admission: nothing was made resident.
    let snapshot = await engine.memory
    #expect(snapshot.residentBytes == 0)
}

@Test func conformingWithoutDeclaringIsAlsoRefused() async throws {
    // LIV-1's fourth quadrant, enforced at runtime as well as in the gate: a consumer that
    // cannot DISCOVER the surface must not be able to reach it by accident either.
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(UndeclaredLivePackage.self),
                              configuration: cfg("mock/hidden"))
    await #expect(throws: EngineError.liveTranscriptionUnsupported("hidden-stt")) {
        _ = try await engine.transcribeLive(STTSessionRequest())
    }
}

@Test func anUndeclaredContextIsRefusedOnTheLivePathToo() async throws {
    // One enforcement site for both entry points: `checkDeclaredControls` runs here exactly as
    // it does on `run()`, so the two cannot drift.
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(OneShotSTTPackage.self),
                              configuration: cfg("mock/oneshot"))
    do {
        _ = try await engine.transcribeLive(STTSessionRequest(context: ["MLXEngine"]))
        Issue.record("expected the undeclared context to be refused")
    } catch {
        guard case .unsupportedRequestFeature(let detail) = error as? PackageError else {
            Issue.record("expected unsupportedRequestFeature, got \(error)")
            return
        }
        #expect(detail.contains("context"))
    }
}

@Test func aDeclaredContextIsAcceptedOnTheLivePath() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest(context: ["MLXEngine"]))
    handle.cancel()
}

@Test func runRefusesASessionRequestWithASignpost() async throws {
    // `STTSessionRequest` is a `CapabilityRequest` so ONE pre-flight covers both doors; the
    // cost is that it type-checks here, and the cost is paid with a message rather than a
    // confusing `unsupportedCapability(.stt)` from a package that plainly supports `.stt`.
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    do {
        _ = try await engine.run(STTSessionRequest())
        Issue.record("expected run() to refuse a session request")
    } catch {
        guard case .unsupportedRequestFeature(let detail) = error as? PackageError else {
            Issue.record("expected unsupportedRequestFeature, got \(error)")
            return
        }
        #expect(detail.contains("transcribeLive"))
    }
}

// MARK: - Lifetime

@Test func abandoningTheHandleEndsTheSession() async throws {
    // The abandoned-stream rule: a dropped handle must not leave a model pinned.
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    do {
        let handle = try await engine.transcribeLive(STTSessionRequest())
        _ = handle.push(Mock.buffer(seconds: 1), sampleRate: Mock.rate)
    }   // handle (and its stream) go out of scope here
    for _ in 0..<200 where await engine.openLiveSessionCount > 0 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let open = await engine.openLiveSessionCount
    #expect(open == 0)
    let package = try await engine.prepare(.stt) as? LiveSTTPackage
    #expect(await package?.lastSession?.releasedModel.isSet == true)
}

@Test func cancelEndsUpdatesWithCancellationError() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest())
    let drain = Task { () -> (any Error)? in
        do {
            for try await _ in handle.updates {}
            return nil
        } catch { return error }
    }
    _ = handle.push(Mock.buffer(seconds: 1), sampleRate: Mock.rate)
    handle.cancel()
    let outcome = await drain.value
    #expect(outcome is CancellationError)
    let open = await engine.openLiveSessionCount
    #expect(open == 0)
}

@Test func theIdleWatchdogEndsADroppedSession() async throws {
    // A session holds residency for its whole lifetime, so "the caller stopped feeding" cannot
    // be waited out indefinitely. Measured against `push`, not against speech.
    let engine = liveEngine(policy: LiveSessionPolicy(idleTimeout: 0.15,
                                                      idleCheckInterval: 0.05))
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest())
    let drain = Task { () -> (any Error)? in
        do {
            for try await _ in handle.updates {}
            return nil
        } catch { return error }
    }
    let outcome = await drain.value
    #expect(outcome as? EngineError == .liveSessionIdle("live-stt"))
    let open = await engine.openLiveSessionCount
    #expect(open == 0)
}

@Test func aFedSessionOutlivesTheIdleTimeout() async throws {
    // The watchdog must not shoot a session that is being used. The session is fed for longer
    // than the idle timeout, with gaps well inside it. ⚠️ The gaps are what the hosted CI runner
    // stretches: with a 0.2 s timeout and 50 ms sleeps, one sleep overshooting by 150 ms shot a
    // session that was being used (ci run 34673758942, a docs-only push). The timeout is now
    // 1 s against 100 ms gaps — a single gap has to overshoot by 0.9 s to fail this wrongly,
    // and the session is still fed for 1.2 s, past the timeout, so the claim keeps its teeth.
    let engine = liveEngine(policy: LiveSessionPolicy(idleTimeout: 1.0, idleCheckInterval: 0.05))
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest())
    for _ in 0..<12 {
        #expect(handle.push(Mock.buffer(seconds: 0.25), sampleRate: Mock.rate) == .accepted)
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let open = await engine.openLiveSessionCount
    #expect(open == 1)
    handle.cancel()
}

@Test func evictingThePackageEndsItsSessionDistinguishably() async throws {
    let engine = liveEngine()
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    let handle = try await engine.transcribeLive(STTSessionRequest())
    let package = try await engine.prepare(.stt) as? LiveSTTPackage
    let session = await package?.lastSession
    let drain = Task { () -> (any Error)? in
        do {
            for try await _ in handle.updates {}
            return nil
        } catch { return error }
    }
    _ = handle.push(Mock.buffer(seconds: 1), sampleRate: Mock.rate)
    await engine.evict(package: "live-stt")

    #expect(await drain.value as? EngineError == .livePreempted("live-stt"))
    let snapshot = await engine.memory
    #expect(snapshot.residentBytes == 0)
    #expect(session?.releasedModel.isSet == true)
}

// MARK: - Governor interaction

@Test func aPackageWithAnOpenSessionIsNotAnIdleLRUVictim() async throws {
    // Between buffers there is no run in flight, so without the live-session set this package
    // would look IDLE and get unloaded out from under a microphone. (The counterfactual — an
    // idle resident IS taken — is `evictsLRUWhenFull` in MLXGovernorTests.)
    let engine = liveEngine(budget: 100)   // fits exactly one 60-byte working set
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    try await engine.register(PackageRegistration.of(SlowLLMPackage.self),
                              configuration: cfg("mock/slow-llm"))
    let handle = try await engine.transcribeLive(STTSessionRequest())
    _ = handle.push(Mock.buffer(seconds: 1), sampleRate: Mock.rate)

    // `prepare` is always `.idleOnly`: it may evict idle residents and nothing else. The live
    // package is over budget alongside the contender, and it still survives — the engine
    // tolerates over-budget co-residency rather than taking a model someone is talking into.
    _ = try await engine.prepare(.llm)

    let open = await engine.openLiveSessionCount
    #expect(open == 1)
    let snapshot = await engine.memory
    #expect(snapshot.residents[.stt] == 60)
    handle.cancel()
}

@Test func theGovernorSacrificesABatchRunBeforeALiveSession() async throws {
    // Victim ordering, stated as a test: a preempted run REQUEUES and loses nothing, a
    // preempted session loses audio nobody can replay. So the batch run goes first, and the
    // session only goes if that was not enough.
    let engine = liveEngine(budget: 130)   // room for two 60-byte working sets, not three
    try await engine.register(PackageRegistration.of(LiveSTTPackage.self), configuration: cfg())
    try await engine.register(PackageRegistration.of(SlowLLMPackage.self),
                              configuration: cfg("mock/slow-llm"))
    try await engine.register(PackageRegistration.of(FastTTSPackage.self),
                              configuration: cfg("mock/fast-tts"))

    let handle = try await engine.transcribeLive(STTSessionRequest())
    _ = handle.push(Mock.buffer(seconds: 1), sampleRate: Mock.rate)

    let slow = Task { try await engine.run(LLMRequest(prompt: "hi")) }
    while await engine.memory.residents[.llm] == nil {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }

    // The contender's FIRST attempt is `.preempting`. Headroom for it exists only by taking
    // one of the two residents; the run is the one that gets taken.
    _ = try await engine.run(TTSRequest(text: "hi"), package: "fast-tts")

    let open = await engine.openLiveSessionCount
    #expect(open == 1, "the live session must outrank an in-flight batch run as a victim")
    let residents = await engine.memory.residents
    #expect(residents[.stt] == 60)

    slow.cancel()
    _ = try? await slow.value
    handle.cancel()
}
