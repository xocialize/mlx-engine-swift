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

    private let onPush: @Sendable ([Float], Int) -> PushOutcome
    private let onFinish: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void

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
                onCancel: @escaping @Sendable () -> Void) {
        self.updates = updates
        self.discipline = discipline
        self.maxBufferedSeconds = maxBufferedSeconds
        self.expectedSampleRate = expectedSampleRate
        self.onPush = onPush
        self.onFinish = onFinish
        self.onCancel = onCancel
    }
}
