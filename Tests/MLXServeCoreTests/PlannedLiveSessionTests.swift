//
//  PlannedLiveSessionTests.swift
//  MLXServeCoreTests
//
//  Contract 1.47.0 — a live session declares a planned duration (AB-A-0100), and the workload
//  plane of 1.41.0 / 1.42.0 reaches `transcribeLive`: refusal past the declared ceiling, a
//  reserve sized for the plan and held for the session's lifetime, and an engine-side end at
//  the plan. Offline, mock packages, no MLX.
//
//  Numbers follow `ActivationScalingEngineTests`: the VibeVoice shape scaled down 10^6 so the
//  arithmetic is exact. Scalar 2 000 B (the representative case, what the idle reserve charges),
//  line 1 000 + 5 B/s to a 600 s ceiling (4 000 B there), 1 B of weights.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

/// One "word" per second of consumed audio — the same rule on the live and batch paths, so a
/// transcript mismatch means the seam broke, not the model.
private enum PlanMock {
    static let rate = 16_000
    static func words(samples: Int, flushed: Bool) -> Int {
        let whole = samples / rate
        return whole + ((flushed && (samples % rate) * 2 >= rate) ? 1 : 0)
    }
    static func text(_ n: Int) -> String { (0..<n).map { "w\($0)" }.joined(separator: " ") }
    static func buffer(seconds: Double, rate: Int = rate) -> [Float] {
        [Float](repeating: 0, count: Int((seconds * Double(rate)).rounded()))
    }
    static func audio(seconds: Double) -> Audio {
        Audio(data: Data(count: Int(seconds * Double(rate)) * MemoryLayout<Float>.size),
              sampleRate: rate, channels: 1)
    }
}

/// A cumulative session that emits a chunk per consumed push and counts what it ACCEPTED — the
/// number a planned session must hold to the plan.
private final class PlanMockSession: STTSession, @unchecked Sendable {
    let discipline: STTStreamDiscipline = .cumulative
    let maxBufferedSeconds: Double = 8
    let expectedSampleRate = PlanMock.rate
    let updates: AsyncThrowingStream<STTStreamChunk, Error>

    private enum Input: Sendable { case samples(Int), finish }
    private let inputs: AsyncStream<Input>
    private let inputContinuation: AsyncStream<Input>.Continuation
    private let outputs: AsyncThrowingStream<STTStreamChunk, Error>.Continuation
    private let lock = NSLock()
    private var accepted = 0
    private var consumed = 0
    private var index = 0
    private var finished = false
    private var cancelled = false

    /// Samples `push` accepted over the session's life.
    var acceptedSamples: Int { lock.withLock { accepted } }

    init() {
        (inputs, inputContinuation) = AsyncStream<Input>.makeStream()
        (updates, outputs) = AsyncThrowingStream<STTStreamChunk, Error>.makeStream()
        Task { @InferenceActor [weak self] in
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
        if finished || cancelled { lock.unlock(); return .ended }
        accepted += samples.count
        lock.unlock()
        inputContinuation.yield(.samples(samples.count))
        return .accepted
    }

    func finish() {
        lock.lock()
        if finished || cancelled { lock.unlock(); return }
        finished = true
        lock.unlock()
        inputContinuation.yield(.finish)
        inputContinuation.finish()
    }

    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        inputContinuation.finish()
        outputs.finish(throwing: CancellationError())
    }

    private func consume(_ n: Int) {
        lock.lock()
        consumed += n
        let processed = Double(consumed) / Double(PlanMock.rate)
        let words = PlanMock.words(samples: consumed, flushed: false)
        let i = index
        index += 1
        let stop = cancelled
        lock.unlock()
        guard !stop else { return }
        outputs.yield(STTStreamChunk(text: PlanMock.text(words), processedSeconds: processed,
                                     committedThrough: processed, index: i, isFinal: false))
    }

    private func flush() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        let processed = Double(consumed) / Double(PlanMock.rate)
        let words = PlanMock.words(samples: consumed, flushed: true)
        let i = index
        index += 1
        lock.unlock()
        outputs.yield(STTStreamChunk(text: PlanMock.text(words), processedSeconds: processed,
                                     committedThrough: processed, index: i, isFinal: true))
        outputs.finish()
    }
}

private let planCeiling = 600.0
private let planScaling = ActivationScaling(axis: .audioSeconds, baseBytes: 1_000,
                                            bytesPerUnit: 5, measuredCeiling: planCeiling)

/// The shape mlx-audio will give VibeVoice: a session maps to its `plannedDuration` (and an
/// open-ended one to nil), so the engine can refuse, reserve, and end at the plan.
private struct PlannedConfiguration: PackageConfiguration, QuantConfigured, WorkloadDeclaring {
    var quant: Quant = .int4
    func workloadUnits(for request: any CapabilityRequest) -> Double? {
        (request as? STTSessionRequest)?.plannedDuration
    }
}

private func planManifest(name: String, repo: String, capability: Capability = .stt,
                          scaling: ActivationScaling?, peak: UInt64 = 2_000,
                          resident: UInt64 = 1) -> PackageManifest {
    let surface = capability == .stt
        ? STTContract.descriptor(name: name, summary: "m",
                                 controls: STTControls(liveDiscipline: .cumulative))
        : TTSContract.descriptor(name: name, summary: "m")
    return PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: repo, revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: resident,
                                        peakActivationBytes: peak, activationScaling: scaling)],
            requiredBackends: [.metalGPU]),
        surfaces: [surface])
}

/// A live package whose configuration maps the plan — VibeVoice after mlx-audio's change.
@InferenceActor
private final class PlannedLivePackage: ModelPackage, LiveTranscribing {
    typealias Configuration = PlannedConfiguration
    nonisolated static var manifest: PackageManifest {
        planManifest(name: "planned-stt", repo: "mock/planned", scaling: planScaling)
    }
    nonisolated init(configuration: PlannedConfiguration) {}
    private(set) var loaded = false
    /// Per instance — the suite runs in parallel.
    private(set) var lastSession: PlanMockSession?
    private(set) var lastRequest: STTSessionRequest?
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let stt = request as? STTRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        let samples = stt.audio.data.count / MemoryLayout<Float>.size
        return STTResponse(text: PlanMock.text(PlanMock.words(samples: samples, flushed: true)))
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        guard loaded else { throw PackageError.notLoaded }
        let session = PlanMockSession()
        lastSession = session
        lastRequest = request
        return session
    }
}

/// A live package with a scalar declaration and a configuration that maps nothing — every live
/// package shipping before its author adopts the plan.
@InferenceActor
private final class UnmappedLivePackage: ModelPackage, LiveTranscribing {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        planManifest(name: "unmapped-stt", repo: "mock/unmapped", scaling: nil)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    private var loaded = false
    private(set) var lastSession: PlanMockSession?
    func load() async throws { loaded = true }
    func unload() async { loaded = false }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "batch")
    }
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession {
        guard loaded else { throw PackageError.notLoaded }
        let session = PlanMockSession()
        lastSession = session
        return session
    }
}

/// A small idle co-resident (1 B weights, 100 B transient) for the headroom tests.
@InferenceActor
private final class TinyTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        planManifest(name: "tiny-tts", repo: "mock/tiny-tts", capability: .tts, scaling: nil,
                     peak: 100)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

/// A byte-scale budget with the R-MEM-1 real-pressure pass off (`physFootprint: nil`): against a
/// few-KB budget the test process's real footprint would read as pressure on every admission.
private func planEngine(budget: UInt64 = 10_000,
                        policy: LiveSessionPolicy = LiveSessionPolicy()) -> MLXServeEngine {
    MLXServeEngine(
        device: DeviceProfile(chipTier: .max,
                              macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                              backends: [.metalGPU], totalMemoryBytes: 64_000_000_000),
        governor: MemoryGovernor(budgetBytes: budget),
        liveSessions: policy,
        physFootprint: { nil })
}

@discardableResult
private func registerPlanned(_ engine: MLXServeEngine) async throws -> PackageID {
    try await engine.register(PackageRegistration.of(PlannedLivePackage.self),
                              configuration: PlannedConfiguration())
}

@discardableResult
private func registerTiny(_ engine: MLXServeEngine) async throws -> PackageID {
    try await engine.register(PackageRegistration.of(TinyTTSPackage.self),
                              configuration: StandardConfiguration(weightsRepo: "mock/tiny-tts"))
}

/// Collect every chunk of `handle.updates` on a task, so a test can push while it drains.
private func collect(_ handle: STTLiveHandle) -> Task<[STTStreamChunk], Error> {
    Task {
        var chunks: [STTStreamChunk] = []
        for try await chunk in handle.updates { chunks.append(chunk) }
        return chunks
    }
}

/// Push `seconds` of audio in `slice`-second buffers WITHOUT calling finish, returning each
/// push's outcome.
private func feed(_ handle: STTLiveHandle, seconds: Double,
                  slice: Double = 0.25) async -> [PushOutcome] {
    var outcomes: [PushOutcome] = []
    for _ in 0..<Int((seconds / slice).rounded()) {
        outcomes.append(handle.push(PlanMock.buffer(seconds: slice), sampleRate: PlanMock.rate))
        await Task.yield()
    }
    return outcomes
}

// MARK: - Refusal past the ceiling (the shared preflight)

// A plan maps to units exactly as a file does, so the existing preflight refuses it BEFORE
// admission: nothing is loaded for a session nobody measured.
@Test func aPlanPastTheCeilingIsRefusedBeforeAnythingLoads() async throws {
    let engine = planEngine()
    let id = try await registerPlanned(engine)
    do {
        _ = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 1_200))
        Issue.record("expected workloadExceedsDeclaredCeiling")
    } catch {
        guard case .workloadExceedsDeclaredCeiling(let package, let axis, let requested,
                                                   let ceiling) = error as? EngineError
        else { Issue.record("unexpected \(error)"); return }
        #expect(package == id)
        #expect(axis == .audioSeconds)
        #expect(requested == 1_200)
        #expect(ceiling == planCeiling)
    }
    let resident = await engine.residentPackages
    #expect(resident[id] == nil)
}

// The ceiling itself is inside the envelope — the declaration was measured there.
@Test func aPlanAtTheCeilingIsAdmitted() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: planCeiling))
    handle.cancel()
}

// A host asks the question admission will ask, before opening: the package's own mapping.
@Test func aHostCanAskWhatAPlanWillReserveBeforeOpening() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let units = try await engine.workloadUnits(for: STTSessionRequest(plannedDuration: 300))
    #expect(units == 300)
    let advisory = try await engine.machineFitAdvisory(.stt, workload: try #require(units))
    #expect(advisory.workload?.perRunReserveBytes == 2_500)   // 1 000 + 5 × 300 > the scalar
    let openEnded = try await engine.workloadUnits(for: STTSessionRequest())
    #expect(openEnded == nil)
}

// MARK: - A reserve sized for the plan, held for the session

// The gap the ask measured: the session rode the idle scalar however long it ran. Planned, it is
// admitted against max(scalar, line at the plan) and holds that until it ends; then the reserve
// returns to the scalar.
@Test func aPlannedSessionHoldsThePlansReserveForItsLifetime() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 600))
    let chunks = collect(handle)
    var reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 4_000)   // 1 000 + 5 × 600, above the 2 000 scalar

    _ = await feed(handle, seconds: 1)
    reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 4_000, "held for the session, not for one buffer")

    handle.finish()
    _ = try await chunks.value
    reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 2_000, "the idle reserve is the scalar again once the session ends")
}

// Below the scalar the session reserves the scalar — `max`, never the bare projection.
@Test func aShortPlanStillReservesTheScalar() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 60))
    let reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 2_000)   // projection 1 300 < scalar 2 000
    handle.cancel()
}

// Every admission during the session sees the plan's reserve: a contender that fits beside the
// idle scalar does not fit beside a 600 s plan.
@Test func admissionDuringAPlannedSessionAccountsForItsReserve() async throws {
    let engine = planEngine(budget: 4_500)
    try await registerPlanned(engine)
    let contender = planManifest(name: "c", repo: "mock/c", capability: .tts, scaling: nil,
                                 peak: 100, resident: 600).requirements

    let openEnded = try await engine.transcribeLive(STTSessionRequest())
    var verdict = await engine.admissibility(for: contender)
    #expect(verdict.fitsAvailable)          // 1 + 600 + max(100, 2 000) = 2 601 ≤ 4 500
    openEnded.cancel()
    for _ in 0..<200 where await engine.openLiveSessionCount > 0 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    let planned = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 600))
    verdict = await engine.admissibility(for: contender)
    #expect(!verdict.fitsAvailable)         // 1 + 600 + max(100, 4 000) = 4 601 > 4 500
    planned.cancel()
}

// A plan whose reserve cannot fit the budget even alone is refused before anything is evicted or
// loaded — by the BUDGET, not the ceiling (600 s is inside the envelope). The same package still
// opens a session whose plan fits.
@Test func aPlanWhoseReserveCannotFitAloneIsRefusedWithoutEvicting() async throws {
    let engine = planEngine(budget: 3_000)
    let id = try await registerPlanned(engine)
    let tiny = try await registerTiny(engine)
    _ = try await engine.prepare(.tts, package: tiny)
    do {
        _ = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 600))
        Issue.record("expected workloadExceedsMemoryBudget")
    } catch {
        guard case .workloadExceedsMemoryBudget(let package, let axis, let requested,
                                                let required, let budget) = error as? EngineError
        else { Issue.record("unexpected \(error)"); return }
        #expect(package == id)
        #expect(axis == .audioSeconds)
        #expect(requested == 600)
        #expect(required == 4_001)          // 1 B of weights + the 4 000 B reserve at the plan
        #expect(budget == 3_000)
    }
    var resident = await engine.residentPackages
    #expect(resident[tiny] != nil, "nothing is evicted for a session that cannot fit anyway")
    #expect(resident[id] == nil, "nothing is loaded for a session that cannot fit anyway")

    let fits = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 100))
    resident = await engine.residentPackages
    #expect(resident[id] != nil)
    fits.cancel()
}

// A fresh admission makes headroom for the plan's reserve, not the scalar: the idle co-resident
// that fits beside the scalar is evicted to fit the plan.
@Test func aPlannedSessionEvictsAnIdleCoResidentToFitItsReserve() async throws {
    // Budget 4 001: the tiny TTS (1 + 100) is resident. The plan needs 1 + 4 000 → with the tiny
    // package that is 2 + 4 000 = 4 002, so it goes; alone the session fits exactly.
    let engine = planEngine(budget: 4_001)
    let id = try await registerPlanned(engine)
    let tiny = try await registerTiny(engine)
    _ = try await engine.prepare(.tts, package: tiny)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 600))
    let resident = await engine.residentPackages
    #expect(resident[id] != nil)
    #expect(resident[tiny] == nil, "the idle co-resident should make room for the plan")
    handle.cancel()
}

// The same on a package that is ALREADY resident (the path a dictation UI's second session takes):
// a resident package is not a free pass past the budget.
@Test func aPlannedSessionOnAResidentPackageMakesHeadroomToo() async throws {
    let engine = planEngine(budget: 4_001)
    let id = try await registerPlanned(engine)
    let tiny = try await registerTiny(engine)
    _ = try await engine.prepare(.stt, package: id)
    _ = try await engine.prepare(.tts, package: tiny)   // 2 + max(2 000, 100) = 2 002: both fit
    var resident = await engine.residentPackages
    #expect(resident[id] != nil && resident[tiny] != nil)

    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 600))
    resident = await engine.residentPackages
    #expect(resident[id] != nil)
    #expect(resident[tiny] == nil, "a resident package still makes headroom for a larger reserve")
    let reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 4_000)
    handle.cancel()
}

// MARK: - The end at the plan

// The caller never calls finish(): the engine does, at the plan. The transcript up to the plan is
// kept, pushes past it answer `.ended`, and the handle says why the session ended.
@Test func theEngineFinishesTheSessionAtThePlan() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 2))
    let chunks = collect(handle)

    let outcomes = await feed(handle, seconds: 3)       // 12 × 0.25 s, a second past the plan
    let delivered = try await chunks.value

    #expect(outcomes.prefix(8).allSatisfy { $0 == .accepted })
    #expect(outcomes.dropFirst(8).allSatisfy { $0 == .ended })
    #expect(delivered.last?.isFinal == true)
    #expect(delivered.filter(\.isFinal).count == 1)
    #expect(delivered.map(\.index) == Array(0..<delivered.count))
    #expect(delivered.last?.processedSeconds == 2)
    #expect(STTStreamDiscipline.cumulative.assemble(delivered) == PlanMock.text(2))
    #expect(handle.endReason == .reachedPlannedDuration)

    let package = try await engine.prepare(.stt) as? PlannedLivePackage
    #expect(await package?.lastSession?.acceptedSamples == 2 * PlanMock.rate)
    #expect(await package?.lastRequest?.plannedDuration == 2)
    let open = await engine.openLiveSessionCount
    #expect(open == 0)

    // LIV-5 through a planned end: the kept transcript is what the batch path says about the
    // same two seconds.
    let batch = try await engine.run(STTRequest(audio: PlanMock.audio(seconds: 2)))
    #expect(STTStreamDiscipline.cumulative.assemble(delivered) == (batch as? STTResponse)?.text)
}

// The push that crosses the plan is accepted up to it — the model receives exactly the plan —
// and reads `.accepted`, because its samples up to the plan were transcribed.
@Test func aPushThatCrossesThePlanIsAcceptedUpToThePlan() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 1.1))
    let chunks = collect(handle)

    #expect(handle.push(PlanMock.buffer(seconds: 1), sampleRate: PlanMock.rate) == .accepted)
    #expect(handle.push(PlanMock.buffer(seconds: 0.25), sampleRate: PlanMock.rate) == .accepted)
    #expect(handle.push(PlanMock.buffer(seconds: 0.25), sampleRate: PlanMock.rate) == .ended)
    let delivered = try await chunks.value

    let package = try await engine.prepare(.stt) as? PlannedLivePackage
    #expect(await package?.lastSession?.acceptedSamples == 17_600)   // 1.1 s × 16 kHz
    #expect(delivered.last?.isFinal == true)
    #expect(delivered.last?.processedSeconds == 1.1)
    #expect(handle.endReason == .reachedPlannedDuration)
}

// Audio the session did not accept never reached the model, so it does not spend the plan.
@Test func onlyAcceptedAudioSpendsThePlan() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 1))
    let chunks = collect(handle)

    // Wrong rate: dropped by the session, and the plan is untouched.
    #expect(handle.push(PlanMock.buffer(seconds: 0.5, rate: 48_000), sampleRate: 48_000)
            == .unsupportedSampleRate)
    let outcomes = await feed(handle, seconds: 1.5)
    _ = try await chunks.value

    #expect(outcomes.prefix(4).allSatisfy { $0 == .accepted })
    #expect(outcomes.dropFirst(4).allSatisfy { $0 == .ended })
    let package = try await engine.prepare(.stt) as? PlannedLivePackage
    #expect(await package?.lastSession?.acceptedSamples == PlanMock.rate)
}

// The caller finishing first is the ordinary end, and the handle says so.
@Test func aCallerFinishBeforeThePlanReadsFinishedByCaller() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 10))
    let chunks = collect(handle)
    _ = await feed(handle, seconds: 1)
    #expect(handle.endReason == nil, "nothing to report while the session is open")
    handle.finish()
    let delivered = try await chunks.value
    #expect(delivered.last?.isFinal == true)
    #expect(delivered.last?.processedSeconds == 1)
    #expect(handle.endReason == .finishedByCaller)
}

// A cancelled session has no clean end to report — the throw is the reason.
@Test func aCancelledPlannedSessionHasNoEndReason() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 10))
    let drain = Task { () -> (any Error)? in
        do {
            for try await _ in handle.updates {}
            return nil
        } catch { return error }
    }
    _ = handle.push(PlanMock.buffer(seconds: 0.5), sampleRate: PlanMock.rate)
    handle.cancel()
    #expect(await drain.value is CancellationError)
    #expect(handle.endReason == nil)
}

// The end applies to every package: one whose configuration maps nothing is admitted on its idle
// reserve, is not held to any ceiling, and still ends at the plan.
@Test func aPackageThatDoesNotMapThePlanStillEndsAtIt() async throws {
    let engine = planEngine()
    let id = try await engine.register(PackageRegistration.of(UnmappedLivePackage.self),
                                       configuration: StandardConfiguration(weightsRepo: "mock/u"))
    // No mapping → no ceiling to refuse against, however long the plan — even one whose sample
    // count does not fit an `Int`, which the gate must not trap on.
    let long = try await engine.transcribeLive(
        STTSessionRequest(plannedDuration: .greatestFiniteMagnitude), package: id)
    #expect(long.push(PlanMock.buffer(seconds: 0.25), sampleRate: PlanMock.rate) == .accepted)
    long.cancel()
    for _ in 0..<200 where await engine.openLiveSessionCount > 0 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    let handle = try await engine.transcribeLive(STTSessionRequest(plannedDuration: 1),
                                                 package: id)
    let reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 2_000)                // the scalar: there is no line to project
    let chunks = collect(handle)
    let outcomes = await feed(handle, seconds: 2)
    let delivered = try await chunks.value
    #expect(outcomes.prefix(4).allSatisfy { $0 == .accepted })
    #expect(outcomes.dropFirst(4).allSatisfy { $0 == .ended })
    #expect(delivered.last?.processedSeconds == 1)
    #expect(handle.endReason == .reachedPlannedDuration)
}

// MARK: - nil is 1.46.0

// An open-ended session is untouched by the whole plane: the idle scalar, no ceiling, no end but
// the caller's.
@Test func anOpenEndedSessionIsUnchanged() async throws {
    let engine = planEngine()
    try await registerPlanned(engine)
    let handle = try await engine.transcribeLive(STTSessionRequest())
    let reserve = await engine.memory.transientReserveBytes
    #expect(reserve == 2_000)
    let chunks = collect(handle)
    let outcomes = await feed(handle, seconds: 3)
    #expect(outcomes.allSatisfy { $0 == .accepted })
    handle.finish()
    let delivered = try await chunks.value
    #expect(delivered.last?.processedSeconds == 3)
    #expect(handle.endReason == .finishedByCaller)
}

// MARK: - Validation

// A plan that is not a positive, finite number of seconds is a caller bug, refused before
// admission — not a NaN-second ceiling refusal, and not a session that ends at its first push.
@Test func anInvalidPlanIsRefusedBeforeAdmission() async throws {
    let engine = planEngine()
    let id = try await registerPlanned(engine)
    for plan in [0, -1, TimeInterval.nan, .infinity] {
        do {
            _ = try await engine.transcribeLive(STTSessionRequest(plannedDuration: plan))
            Issue.record("expected plan \(plan) to be refused")
        } catch {
            guard case .unsupportedRequestFeature(let detail) = error as? PackageError else {
                Issue.record("expected unsupportedRequestFeature for \(plan), got \(error)")
                continue
            }
            #expect(detail.contains("plannedDuration"))
        }
    }
    let resident = await engine.residentPackages
    #expect(resident[id] == nil)
}
