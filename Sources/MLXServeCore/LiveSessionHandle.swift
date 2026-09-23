//
//  LiveSessionHandle.swift
//  MLXServeCore
//
//  The caller-facing handle for one live transcription session (contract 1.39.0, companion N2).
//  The `TTSStreamHandle` sibling — same role, different lifecycle: a stream is one run with a
//  chunked delivery surface, a session is residency plus a series of tiny runs driven by audio
//  that has not arrived yet.
//

import Foundation
import MLXToolKit

/// Engine policy for live transcription sessions (contract 1.39.0).
public struct LiveSessionPolicy: Sendable {
    /// How long a session may go without a `push` before the engine ends it with
    /// `EngineError.liveSessionIdle`. A session holds residency for its whole lifetime, so a
    /// handle the caller dropped without finishing would otherwise pin a model forever — the
    /// abandoned-stream rule needs a timer here, because unlike a stream there is nothing the
    /// engine is waiting on to notice.
    ///
    /// Measured against `push`, not against speech: a live tap pushes silence too, so "no
    /// pushes" means the caller stopped feeding, not that the room went quiet. The default is
    /// deliberately long — a push-to-talk UI that holds a session open between utterances is
    /// legitimate — and generous is fine, because the point is bounding a leak, not trimming
    /// residency promptly. `<= 0` disables it.
    public var idleTimeout: TimeInterval
    /// How often the watchdog looks. Coarse on purpose: this is leak insurance, not scheduling.
    public var idleCheckInterval: TimeInterval

    public init(idleTimeout: TimeInterval = 300, idleCheckInterval: TimeInterval = 5) {
        self.idleTimeout = idleTimeout
        self.idleCheckInterval = idleCheckInterval
    }
}

/// Monotonic "when did the caller last feed us" clock, readable from an audio thread.
/// `DispatchTime`, not `Date`: a wall-clock jump must not read as an idle session.
final class LiveActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPush = DispatchTime.now()

    func touch() {
        lock.lock(); defer { lock.unlock() }
        lastPush = .now()
    }

    var idleSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let delta = DispatchTime.now().uptimeNanoseconds &- lastPush.uptimeNanoseconds
        return TimeInterval(delta) / 1_000_000_000
    }
}

/// Why a live session ended CLEANLY, with its `isFinal` chunk (contract 1.47.0).
///
/// Failures keep their own channel, the terminal throw of `updates`. This says which of the two
/// clean ends it was: both deliver the same final chunk, and a UI says different things about
/// them ("you stopped" against "the planned 40 minutes are up").
///
/// Switch with a `default` (C12's tolerance).
public enum LiveSessionEndReason: String, Sendable, Codable {
    /// The caller called `finish()`.
    case finishedByCaller
    /// The engine called `finish()` when the session's accepted audio reached
    /// `STTSessionRequest.plannedDuration`.
    case reachedPlannedDuration
}

/// The engine side of a planned session's end (contract 1.47.0), and the record of which clean
/// end a session had.
///
/// Why the plan is held at `push` and not at the pump: the pump only sees a chunk when the package
/// emits one, and a package may emit nothing through a silent stretch. By the time a chunk reported
/// `processedSeconds` past the plan, audio past it would already be buffered, and the model's
/// activation would already be growing past the reserve sized for the plan. Counting accepted
/// audio here means the model never receives a sample past the plan.
///
/// Lock-guarded, and it runs on the audio thread inside `push`: the only extra work is the
/// bookkeeping, plus one copy of the boundary buffer's head. An open-ended session (`plannedSeconds
/// == nil`) passes every push straight through without taking the lock.
final class LivePlanGate: @unchecked Sendable {
    /// The plan, in seconds of audio; nil = open-ended.
    let plannedSeconds: Double?
    private let lock = NSLock()
    /// Seconds of audio the session has ACCEPTED. Overrun, wrong-rate and post-end pushes do not
    /// spend the plan: none of them reached the model.
    private var acceptedSeconds: Double = 0
    /// Which clean end was triggered first: the caller's `finish()`, or the plan.
    private var trigger: LiveSessionEndReason?
    /// Set by the pump when `updates` ends with the final chunk.
    private var endedCleanly = false

    init(plannedSeconds: Double?) {
        self.plannedSeconds = plannedSeconds
    }

    /// Forward one push to `session`, holding it to the plan. `reachedPlan` is true for exactly
    /// one push, the one that reached the plan; its caller then finishes the session. The session
    /// is called with the lock held, which is safe because `push` is copy-only by contract
    /// (LIV-3), and it is what keeps two racing pushes from both spending the same remainder.
    func push(_ samples: [Float], sampleRate: Int,
              into session: any STTSession) -> (outcome: PushOutcome, reachedPlan: Bool) {
        guard let planned = plannedSeconds, sampleRate > 0 else {
            return (session.push(samples, sampleRate: sampleRate), false)
        }
        lock.lock(); defer { lock.unlock() }
        // Ended, by the plan or by the caller. The session would answer `.ended` to the latter
        // itself; answering here as well means nothing reaches the model once the plan has
        // closed the session, whatever the package does with a push after `finish()`.
        guard trigger == nil else { return (.ended, false) }
        // Remaining plan in whole samples AT THIS PUSH'S RATE. Rounding to a sample each time
        // keeps floating-point drift (~1e-12 s) from leaving a sub-sample sliver of plan open.
        // Kept in `Double`: a finite but absurd plan (a package that maps nothing is held to no
        // ceiling) would trap converting to `Int`, so it is compared before it is converted.
        let remaining = ((planned - acceptedSeconds) * Double(sampleRate)).rounded()
        guard remaining >= 1 else {
            trigger = .reachedPlannedDuration
            return (.ended, true)
        }
        let admitted = remaining > Double(samples.count) ? samples.count : Int(remaining)
        let outcome = session.push(admitted == samples.count ? samples
                                                             : Array(samples.prefix(admitted)),
                                   sampleRate: sampleRate)
        guard outcome == .accepted else { return (outcome, false) }
        acceptedSeconds += Double(admitted) / Double(sampleRate)
        guard Double(admitted) == remaining else { return (.accepted, false) }
        // This push reached the plan. It reads `.accepted`: its samples up to the plan were
        // transcribed. Any samples past the plan were dropped; every later push answers `.ended`.
        trigger = .reachedPlannedDuration
        return (.accepted, true)
    }

    /// The caller's `finish()`: claims the end unless the plan already has.
    func noteCallerFinish() {
        lock.lock(); defer { lock.unlock() }
        if trigger == nil { trigger = .finishedByCaller }
    }

    /// The pump saw `updates` end with the final chunk.
    func noteEndedCleanly() {
        lock.lock(); defer { lock.unlock() }
        endedCleanly = true
    }

    /// `STTLiveHandle.endReason`: nil until a clean end, and for every other kind of end.
    var endReason: LiveSessionEndReason? {
        lock.lock(); defer { lock.unlock() }
        return endedCleanly ? trigger : nil
    }
}

/// Returned by `MLXServeEngine.transcribeLive(_:package:)`.
///
/// - `updates` is the live transcript stream. Every failure — the package's, governor
///   preemption (`EngineError.livePreempted`, non-requeueable), the idle watchdog
///   (`EngineError.liveSessionIdle`), the caller's own `cancel()` (`CancellationError`) —
///   surfaces as this stream's terminal throw. The single error channel, as for
///   `TTSStreamHandle`.
/// - **The session ends when the stream ends.** Dropping the handle without iterating, or
///   cancelling the iterating task, cancels the session and releases residency — the
///   abandoned-stream rule. `break`ing out of the loop while still holding the handle does NOT
///   end it; call `finish()` or `cancel()`.
/// - `push` is safe from an audio callback: it copies and returns. Check the outcome —
///   `.overrun` means samples were dropped, not delayed.
/// - A session opened with `STTSessionRequest.plannedDuration` (1.47.0) is finished by the
///   engine when its accepted audio reaches the plan: the push that reaches it is accepted up to
///   the plan, `updates` delivers the final chunk as for `finish()`, every later push answers
///   `.ended`, and `endReason` reads `.reachedPlannedDuration`.
public struct STTLiveHandle: Sendable {
    /// The live transcript. Assemble it per `discipline`.
    public let updates: AsyncThrowingStream<STTStreamChunk, Error>
    /// `.cumulative` = replace what you are holding; `.incremental` = append. Read from the
    /// session the package actually created (LIV-1 asserts it matches the declaration).
    public let discipline: STTStreamDiscipline
    /// Input capacity in seconds of audio; `push` returns `.overrun` past it.
    public let maxBufferedSeconds: Double
    /// The rate `push` wants. Configure the tap's converter from this before the first buffer:
    /// samples at any other rate are dropped with `.unsupportedSampleRate`.
    public let expectedSampleRate: Int

    /// Why the session ended, once it has ended CLEANLY (contract 1.47.0): `.finishedByCaller`
    /// or `.reachedPlannedDuration`. `nil` while the session is open, and when it ended by
    /// cancellation or a failure, which surface as `updates`' terminal throw. Set before `updates`
    /// finishes, so a consumer that reads it after its `for try await` loop sees it.
    public var endReason: LiveSessionEndReason? { readEndReason() }

    private let onPush: @Sendable ([Float], Int) -> PushOutcome
    private let onFinish: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private let readEndReason: @Sendable () -> LiveSessionEndReason?

    /// Hand over mono PCM in [-1, 1] at `sampleRate`. Copy-only and non-blocking: callable from
    /// an `AVAudioEngine` tap or a CoreAudio IOProc.
    @discardableResult
    public func push(_ samples: [Float], sampleRate: Int) -> PushOutcome {
        onPush(samples, sampleRate)
    }

    /// Stop feeding: the tail is flushed, one `isFinal` chunk is emitted, `updates` ends,
    /// residency is released. Idempotent.
    public func finish() { onFinish() }

    /// Abandon: `updates` ends with `CancellationError`, no final chunk, residency released.
    /// Idempotent.
    public func cancel() { onCancel() }

    public init(updates: AsyncThrowingStream<STTStreamChunk, Error>,
                discipline: STTStreamDiscipline,
                maxBufferedSeconds: Double,
                expectedSampleRate: Int,
                onPush: @escaping @Sendable ([Float], Int) -> PushOutcome,
                onFinish: @escaping @Sendable () -> Void,
                onCancel: @escaping @Sendable () -> Void,
                endReason: @escaping @Sendable () -> LiveSessionEndReason? = { nil }) {
        self.updates = updates
        self.discipline = discipline
        self.maxBufferedSeconds = maxBufferedSeconds
        self.expectedSampleRate = expectedSampleRate
        self.onPush = onPush
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.readEndReason = endReason
    }
}
