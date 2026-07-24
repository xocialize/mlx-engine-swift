//
//  Streaming.swift
//  MLXToolKit
//
//  The streaming-output opt-in (contract 1.25.0, ENGINE-NEEDS N2) — the token-streaming
//  question `RunPhase` deliberately deferred (1.18.0), answered for audio first.
//

import Foundation

/// Opt-in mid-run streaming synthesis, `as?`-detected by the engine (the
/// `SelfMaterializing`/`QuantConfigured` convention). First realization: GepardPackage
/// (causal NanoCodec decode every K frames).
///
/// ## The emit-closure shape (why not a package-returned AsyncStream)
///
/// The package calls `emit` **synchronously from its run loop**, on the run's task. That keeps
/// the engine-bound `RunProgress.$sink` task-local visible for per-chunk progress reports and
/// keeps `Task.checkCancellation()` cadence natural — emissions from detached tasks or delegate
/// threads silently lose both (the WeightMaterializer task-context lesson, made structural
/// here; the STR-6 gate makes it testable). It also gives the engine one deterministic
/// completion point: when `runStream` returns, emission is over — the engine finishes the
/// consumer stream, releases run bookkeeping, and resolves the aggregated response.
///
/// ## Contract
///
/// - Same rules as `run(_:)`: entry checkpoint FIRST, cooperative mid-run cancellation at the
///   declared cadence, `CancellationError` rethrown unchanged.
/// - Chunks: `index` starts at 0, strictly monotonic, no gaps; exactly one chunk has
///   `isFinal == true` and it is the last; `sampleRate` constant across the run.
/// - Returns the SAME aggregated canonical response `run(_:)` would have produced (TTS: the
///   full `.wav`) — the caller's completion handle and the batch parity gate (STR-5) both
///   rely on it.
@InferenceActor
public protocol StreamEmitting: ModelPackage {
    func runStream(_ request: any CapabilityRequest,
                   emit: @escaping @Sendable (TTSStreamChunk) -> Void)
        async throws -> any CapabilityResponse
}
