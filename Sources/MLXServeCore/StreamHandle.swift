//
//  StreamHandle.swift
//  MLXServeCore
//
//  The caller-facing handle for one streaming TTS synthesis (contract 1.25.0, ENGINE-NEEDS N2).
//

import Foundation
import MLXToolKit

/// Returned by `MLXServeEngine.stream(_:package:bufferingPolicy:)`.
///
/// - `chunks` is the live PCM stream. **It must be consumed** — an abandoned stream (a handle
///   dropped without iterating, or the iterating task cancelled) deliberately cancels the
///   underlying run so no orphan GPU work continues. Admission failures, run errors, the
///   caller's own cancellation, and governor preemption (`EngineError.streamPreempted`,
///   retryable) all surface as this stream's terminal throw — the single error channel.
/// - **Stopping early**: `break`ing out of the `for try await` loop while holding the handle
///   does NOT stop the run (the stream stays alive). Call `cancel()` — or cancel the task
///   doing the iteration — to stop synthesis; the stream then terminates with
///   `CancellationError`.
/// - `completion` resolves to the aggregated canonical response (always `.wav`), completing
///   after the last chunk; it fails with the same error the stream threw. Callers that only
///   want the final artifact should use `run()` instead.
public struct TTSStreamHandle: Sendable {
    public let chunks: AsyncThrowingStream<TTSStreamChunk, Error>
    public let completion: Task<TTSResponse, Error>
    private let onCancel: @Sendable () -> Void

    /// Cancel the underlying run (the user lane — surfaces `CancellationError` on the stream).
    public func cancel() { onCancel() }

    public init(chunks: AsyncThrowingStream<TTSStreamChunk, Error>,
                completion: Task<TTSResponse, Error>,
                onCancel: @escaping @Sendable () -> Void) {
        self.chunks = chunks
        self.completion = completion
        self.onCancel = onCancel
    }
}
