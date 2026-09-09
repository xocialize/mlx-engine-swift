//
//  LiveTranscriptionConformance.swift
//  MLXServeConformance
//
//  The "LIV gate" (contract 1.39.0, companion N2) — the executable adjunct to the
//  `LiveTranscribing` opt-in, the way STR-1..7 is to `StreamEmitting`.
//
//  Offline (no MLX kernels, no weights — call from the package's own conformance tests):
//    LIV-1 advertisement ⇔ conformance coherence, and declaration ⇔ session coherence
//    LIV-3 `push` is non-blocking with the inference actor held (the audio-thread rule)
//    LIV-6 cancel semantics
//  Pure validators over chunks a live lane collected from a real GPU run:
//    LIV-2 declared discipline vs observed assembly
//    LIV-4 sequence integrity (index / isFinal / processedSeconds / committedThrough)
//    LIV-5 final parity vs `run(STTRequest)` on the same audio
//  Latency (audio time → chunk delivery) is a bench, not a gate.
//
//  LIV-3 and LIV-6 run offline because they need a session, not a transcript: a package can
//  satisfy both with a session over silence.
//

import Foundation
import MLXToolKit

public enum LiveTranscriptionConformance {

    public typealias Check = StreamingConformance.Check
    public typealias Report = StreamingConformance.Report

    // MARK: - LIV-1 — advertisement ⇔ conformance coherence (offline, type-level)

    /// Both directions, exactly as STR-1: an `stt` surface declaring
    /// `STTControls.liveDiscipline` requires the type to conform to `LiveTranscribing`, and a
    /// conforming type must declare on at least one surface or no consumer can ever discover it.
    public static func checkAdvertisement<P: ModelPackage>(_ type: P.Type) -> Report {
        let declared = P.manifest.surfaces
            .compactMap { $0.capability == .stt ? $0.sttControls?.liveDiscipline : nil }
        let conforms = P.self is any LiveTranscribing.Type
        var checks: [Check] = []
        switch (declared.isEmpty, conforms) {
        case (false, true):
            checks.append(Check(
                name: "LIV-1 advertisement coherence", passed: true,
                note: "declares liveDiscipline "
                    + declared.map(\.rawValue).joined(separator: "/")
                    + " and conforms to LiveTranscribing"))
        case (true, false):
            checks.append(Check(name: "LIV-1 advertisement coherence", passed: true,
                                note: "one-shot package: no live declaration, no conformance"))
        case (false, false):
            checks.append(Check(
                name: "LIV-1 advertisement coherence", passed: false,
                note: "an stt surface declares liveDiscipline but \(P.self) does not conform to "
                    + "LiveTranscribing — the descriptor is lying"))
        case (true, true):
            checks.append(Check(
                name: "LIV-1 advertisement coherence", passed: false,
                note: "\(P.self) conforms to LiveTranscribing but no stt surface declares "
                    + "liveDiscipline — consumers can never discover it, and "
                    + "MLXServeEngine.transcribeLive refuses it"))
        }
        // A package with several stt surfaces must not declare two disciplines: the engine
        // resolves ONE stt surface per package, so a second answer is unreachable and the
        // consumer's assembly rule would depend on which surface it happened to read.
        if Set(declared).count > 1 {
            checks.append(Check(
                name: "LIV-1 single discipline", passed: false,
                note: "stt surfaces declare conflicting disciplines "
                    + "\(declared.map(\.rawValue).sorted())"))
        }
        return Report(checks: checks)
    }

    /// The runtime half of LIV-1: the session a package hands back must report the discipline
    /// its descriptor declared. A mismatch silently corrupts every consumer's transcript, and it
    /// is invisible in a chunk — hence a gate, not an error.
    public static func checkSessionMatchesDeclaration<P: ModelPackage>(
        _ type: P.Type, session: any STTSession
    ) -> Report {
        let declared = P.manifest.surfaces
            .first { $0.capability == .stt }?.sttControls?.liveDiscipline
        var checks: [Check] = []
        checks.append(Check(
            name: "LIV-1 session ⇔ declaration", passed: declared == session.discipline,
            note: declared == session.discipline
                ? "both \(session.discipline.rawValue)"
                : "surface declares \(declared?.rawValue ?? "none"), session reports "
                    + "\(session.discipline.rawValue)"))
        checks.append(Check(
            name: "LIV-1 expected sample rate declared", passed: session.expectedSampleRate > 0,
            note: session.expectedSampleRate > 0
                ? "expectedSampleRate \(session.expectedSampleRate) Hz"
                : "expectedSampleRate must be positive — a caller configures its converter from "
                    + "it before the first buffer"))
        checks.append(Check(
            name: "LIV-1 buffer capacity declared", passed: session.maxBufferedSeconds > 0,
            note: session.maxBufferedSeconds > 0
                ? String(format: "maxBufferedSeconds %.3g", session.maxBufferedSeconds)
                : "maxBufferedSeconds must be positive — back-pressure is explicit, and a "
                    + "capacity of zero makes every push an overrun"))
        return Report(checks: checks)
    }

    // MARK: - LIV-2 — declared discipline vs observed assembly (live validator)

    /// Does the stream behave the way the surface said it would?
    ///
    /// Deliberately asymmetric, because the two disciplines fail differently:
    /// - `.cumulative` — text the package declared **committed** must survive into the next
    ///   chunk. Where a chunk is fully committed (`committedThrough == processedSeconds`) that
    ///   means strict prefix stability; where it is partially committed it is checked against
    ///   the segments that end at or before the watermark.
    /// - `.incremental` — a chunk that re-delivers its predecessor's text is a **cumulative
    ///   stream wearing the wrong label**, and a consumer appending it duplicates the whole
    ///   transcript. That is the failure this looks for.
    ///
    /// Checks that could not be evaluated (no watermark, no segments) are reported as such:
    /// vacuously passed is not the same as passed.
    public static func checkDiscipline(_ chunks: [STTStreamChunk],
                                       declared: STTStreamDiscipline) -> Report {
        guard chunks.count > 1 else {
            return Report(checks: [Check(
                name: "LIV-2 declared discipline (\(declared.rawValue))", passed: true,
                note: "fewer than two chunks — nothing to compare")])
        }
        var checks: [Check] = []
        switch declared {
        case .cumulative:
            var strictPairs = 0
            var violations: [Int] = []
            var segmentPairs = 0
            var segmentViolations: [Int] = []
            for (a, b) in zip(chunks, chunks.dropFirst()) {
                if let mark = a.committedThrough, mark >= a.processedSeconds {
                    strictPairs += 1
                    if !b.text.hasPrefix(a.text) { violations.append(b.index) }
                } else if let mark = a.committedThrough, !a.segments.isEmpty {
                    let settled = a.segments.filter { $0.start + $0.duration <= mark }
                    guard !settled.isEmpty else { continue }
                    segmentPairs += 1
                    if !b.segments.starts(with: settled) { segmentViolations.append(b.index) }
                }
            }
            checks.append(Check(
                name: "LIV-2 cumulative: committed text is stable", passed: violations.isEmpty,
                note: violations.isEmpty
                    ? (strictPairs > 0
                        ? "\(strictPairs) fully-committed pair(s) prefix-stable"
                        : "no fully-committed pair to check (committedThrough nil or trailing "
                            + "processedSeconds) — VACUOUS")
                    : "chunk(s) \(violations) dropped or rewrote text their predecessor "
                        + "declared committed"))
            if segmentPairs > 0 || !segmentViolations.isEmpty {
                checks.append(Check(
                    name: "LIV-2 cumulative: committed segments are stable",
                    passed: segmentViolations.isEmpty,
                    note: segmentViolations.isEmpty
                        ? "\(segmentPairs) partially-committed pair(s) kept their settled segments"
                        : "chunk(s) \(segmentViolations) rewrote segments behind the watermark"))
            }
        case .incremental:
            // A two-word predecessor is the threshold: shorter texts repeat by coincidence
            // ("the ", "and"), longer ones do not.
            var repeats: [Int] = []
            for (a, b) in zip(chunks, chunks.dropFirst())
            where a.text.split(separator: " ").count >= 2 && b.text.hasPrefix(a.text) {
                repeats.append(b.index)
            }
            checks.append(Check(
                name: "LIV-2 incremental: chunks do not repeat their predecessor",
                passed: repeats.isEmpty,
                note: repeats.isEmpty
                    ? "no chunk re-delivered the text before it"
                    : "chunk(s) \(repeats) begin with their predecessor's full text — this looks "
                        + "like a CUMULATIVE stream declared .incremental, which duplicates the "
                        + "transcript for every consumer that appends"))
            let starts = chunks.flatMap { $0.segments.map(\.start) }
            let ordered = starts == starts.sorted()
            if !starts.isEmpty {
                checks.append(Check(
                    name: "LIV-2 incremental: segment starts advance", passed: ordered,
                    note: ordered ? "\(starts.count) segment start(s) non-decreasing"
                                  : "segment starts go backwards across chunks — appended "
                                      + "segments must extend the timeline, not re-cover it"))
            }
        }
        return Report(checks: checks)
    }

    // MARK: - LIV-3 — `push` is non-blocking and MLX-free (offline)

    /// The audio-thread rule, made testable — STR-6's canary transposed to the input side, and
    /// the check that prevents the known failure.
    ///
    /// The compiler already forces `push` to be `nonisolated` (it is a protocol requirement), so
    /// what is left to prove is that the implementation does not *hop* to `@InferenceActor` and
    /// does not do work there. This holds the inference actor busy for `holdSeconds` and pushes
    /// from outside it: an implementation that awaits the actor — which anything touching MLX
    /// must — blocks for the hold, and a copy-only one returns immediately.
    ///
    /// Offline-safe: the hold is a sleep, and the pushes are silence.
    public static func checkPushIsNonBlocking(
        session: any STTSession,
        samples: [Float]? = nil,
        sampleRate: Int? = nil,
        pushes: Int = 8,
        holdSeconds: Double = 0.5,
        budgetSeconds: Double = 0.05
    ) async -> Report {
        // Default to the rate the session ASKED for: pushing at a rate it rejects would measure
        // the refusal path and pass vacuously.
        let sampleRate = sampleRate ?? session.expectedSampleRate
        let buffer = samples ?? [Float](repeating: 0, count: max(1, sampleRate / 10))
        let holdNanos = UInt64(holdSeconds * 1_000_000_000)
        let released = AsyncStream<Void>.makeStream()
        // Occupy the engine's serialization domain for the whole measurement window.
        //
        // `Thread.sleep`, NOT `Task.sleep`: an `await` inside an actor-isolated function
        // RELEASES the actor, so a sleeping hog would leave it free and this check would pass
        // vacuously. A synchronous block is also the faithful model — MLX work holds the actor
        // by computing, not by awaiting.
        let hog = Task { @InferenceActor in
            occupyInferenceActor(forNanoseconds: holdNanos,
                                 announcing: released.continuation)
        }
        var iterator = released.stream.makeAsyncIterator()
        _ = await iterator.next()   // the hog is on the actor before we start the clock

        let start = DispatchTime.now()
        var outcomes: [PushOutcome] = []
        for _ in 0..<pushes { outcomes.append(session.push(buffer, sampleRate: sampleRate)) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds)
            / 1_000_000_000
        await hog.value

        var checks: [Check] = []
        checks.append(Check(
            name: "LIV-3 push does not block on the inference actor", passed: elapsed < budgetSeconds,
            note: String(
                format: "%d push(es) took %.4f s with @InferenceActor held for %.2f s "
                    + "(budget %.3f s)", pushes, elapsed, holdSeconds, budgetSeconds)
                + (elapsed < budgetSeconds ? "" :
                    " — push is awaiting the actor, so it cannot be called from an audio callback")))
        // A session that answers `.ended`/`.overrun` to every push is not exercising the path
        // the check is about; say so rather than passing on a no-op.
        let accepted = outcomes.filter { $0 == .accepted }.count
        checks.append(Check(
            name: "LIV-3 pushes were actually accepted", passed: accepted > 0,
            note: accepted > 0
                ? "\(accepted)/\(pushes) accepted"
                : "no push was accepted (\(outcomes.first.map(String.init(describing:)) ?? "—")) "
                    + "— the timing above measured a rejection path, not the input path"))
        return Report(checks: checks)
    }

    // MARK: - LIV-4 — sequence integrity (live validator)

    /// Pure validator over the chunks of one session. `expectTruncated: true` for a cancelled
    /// session, where no final chunk is expected.
    public static func checkSequence(_ chunks: [STTStreamChunk],
                                     expectTruncated: Bool = false) -> Report {
        guard !chunks.isEmpty else {
            return Report(checks: [Check(
                name: "LIV-4 sequence integrity", passed: expectTruncated,
                note: expectTruncated ? "cancelled before the first chunk — vacuously ordered"
                                      : "no chunks emitted")])
        }
        var checks: [Check] = []
        let indices = chunks.map(\.index)
        let ordered = indices == Array(0..<chunks.count)
        checks.append(Check(name: "LIV-4 index ordering", passed: ordered,
                            note: ordered ? "0-based, strictly monotonic, no gaps"
                                          : "indices \(indices)"))

        let finals = chunks.enumerated().filter { $0.element.isFinal }.map(\.offset)
        let finalOK = expectTruncated ? finals.isEmpty : finals == [chunks.count - 1]
        checks.append(Check(
            name: "LIV-4 isFinal placement", passed: finalOK,
            note: expectTruncated
                ? (finals.isEmpty ? "cancelled session carries no final chunk"
                                  : "final marker at \(finals) on a cancelled session — "
                                      + "cancel() must not emit one")
                : (finalOK ? "exactly once, on the last chunk" : "final markers at \(finals)")))

        let processed = chunks.map(\.processedSeconds)
        let processedOK = zip(processed, processed.dropFirst()).allSatisfy { $0 <= $1 }
        checks.append(Check(
            name: "LIV-4 processedSeconds non-decreasing", passed: processedOK,
            note: processedOK ? String(format: "0 → %.3f s", processed.last ?? 0)
                              : "processedSeconds goes backwards: \(processed)"))

        // Watermark nil-ness is constant for the session: a package that commits, commits from
        // chunk 0, so a consumer decides once how to render rather than per chunk.
        let commitStates = Set(chunks.map { $0.committedThrough == nil })
        checks.append(Check(
            name: "LIV-4 committedThrough presence is constant", passed: commitStates.count == 1,
            note: commitStates.count == 1
                ? (chunks[0].committedThrough == nil ? "no commitment guarantee, all chunks"
                                                     : "watermarked, all chunks")
                : "some chunks carry committedThrough and some do not — a consumer cannot decide "
                    + "once how to render"))

        let marks = chunks.compactMap(\.committedThrough)
        if !marks.isEmpty {
            let monotonic = zip(marks, marks.dropFirst()).allSatisfy { $0 <= $1 }
            checks.append(Check(
                name: "LIV-4 committedThrough non-decreasing", passed: monotonic,
                note: monotonic ? String(format: "0 → %.3f s", marks.last ?? 0)
                                : "the commitment watermark retreats: \(marks)"))
            let bounded = chunks.allSatisfy {
                guard let mark = $0.committedThrough else { return true }
                return mark <= $0.processedSeconds + 1e-9
            }
            checks.append(Check(
                name: "LIV-4 committedThrough ≤ processedSeconds", passed: bounded,
                note: bounded ? "watermark never runs ahead of the audio consumed"
                              : "a chunk commits text past the audio it has processed"))
        }
        return Report(checks: checks)
    }

    // MARK: - LIV-5 — final parity vs the batch path (live validator)

    /// The STR-5 analogue, and the check that promotes this plane: the transcript a session
    /// delivers must equal what `run(STTRequest)` returns for the same audio.
    ///
    /// Word-level edit distance over whitespace-collapsed text, normalized by the reference
    /// length; `tolerance` 0 demands an exact match. A live path is the *same* model over the
    /// *same* samples, so 0 is the honest default — document any escape in the package's suite,
    /// with the reason (a genuinely different chunking of the audio's tail is one; "it drifts"
    /// is not).
    public static func checkFinalParity(chunks: [STTStreamChunk],
                                        discipline: STTStreamDiscipline,
                                        batchTranscript: String,
                                        tolerance: Double = 0) -> Report {
        let live = normalized(discipline.assemble(chunks))
        let batch = normalized(batchTranscript)
        if live == batch {
            return Report(checks: [Check(
                name: "LIV-5 final parity", passed: true,
                note: "live transcript identical to run(STTRequest) "
                    + "(\(batch.split(separator: " ").count) words)")])
        }
        let reference = batch.split(separator: " ").map(String.init)
        let hypothesis = live.split(separator: " ").map(String.init)
        let distance = wordEditDistance(reference, hypothesis)
        let rate = reference.isEmpty ? (hypothesis.isEmpty ? 0 : 1)
                                     : Double(distance) / Double(reference.count)
        return Report(checks: [Check(
            name: "LIV-5 final parity", passed: rate <= tolerance,
            note: String(format: "word error rate %.4f (%d edits over %d reference words, "
                                 + "tolerance %.4f)", rate, distance, reference.count, tolerance))])
    }

    /// Hold `@InferenceActor` synchronously for the measurement window. Deliberately NOT async:
    /// `Thread.sleep` is unavailable from an async context precisely because it blocks, and
    /// blocking is the whole point here — an actor is only "busy" while it is not suspended.
    @InferenceActor
    private static func occupyInferenceActor(forNanoseconds nanos: UInt64,
                                             announcing signal: AsyncStream<Void>.Continuation) {
        signal.yield()
        Thread.sleep(forTimeInterval: TimeInterval(nanos) / 1_000_000_000)
    }

    /// Whitespace-collapsed and trimmed. Nothing else: case and punctuation are output the
    /// contract promises ("the model's native punctuation and capitalization"), so folding them
    /// away here would hide a real divergence between the two paths.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func wordEditDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            current[0] = i
            for j in 1...hypothesis.count {
                let substitution = previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }

    // MARK: - LIV-6 — cancel semantics (offline)

    /// `cancel()` mid-session ends `updates` with `CancellationError`, emits no final chunk, and
    /// releases the model. Runs offline over silence: what is under test is the session's
    /// lifecycle, not its transcription.
    ///
    /// `cancelAfter` chunks are awaited before cancelling — pass 0 to cancel immediately, which
    /// is the abandoned-before-anything-decoded case.
    public static func checkCancelSemantics(
        session: any STTSession,
        feed: [[Float]],
        sampleRate: Int? = nil,
        cancelAfter: Int = 0
    ) async -> Report {
        let sampleRate = sampleRate ?? session.expectedSampleRate
        let collector = Collector()
        let drain = Task {
            do {
                for try await chunk in session.updates {
                    collector.append(chunk)
                    if collector.count > cancelAfter { session.cancel() }
                }
                return nil as (any Error)?
            } catch {
                return error
            }
        }
        for buffer in feed { _ = session.push(buffer, sampleRate: sampleRate) }
        if cancelAfter == 0 { session.cancel() }
        let outcome = await drain.value
        let chunks = collector.snapshot()

        var checks: [Check] = []
        switch outcome {
        case is CancellationError:
            checks.append(Check(name: "LIV-6 cancel ends updates", passed: true,
                                note: "CancellationError after \(chunks.count) chunk(s)"))
        case .some(let error):
            checks.append(Check(name: "LIV-6 cancel ends updates", passed: false,
                                note: "updates ended with \(type(of: error)).\(error) — cancel() "
                                    + "must surface CancellationError"))
        case nil:
            checks.append(Check(name: "LIV-6 cancel ends updates", passed: false,
                                note: "updates completed normally — a cancelled session must not "
                                    + "finish cleanly"))
        }
        let finals = chunks.filter(\.isFinal).count
        checks.append(Check(name: "LIV-6 no final chunk", passed: finals == 0,
                            note: finals == 0 ? "cancelled session emitted no final chunk"
                                              : "\(finals) final chunk(s) on a cancelled session"))
        // Idempotence: the second cancel must not trap, throw, or resurrect the stream.
        session.cancel()
        session.finish()
        checks.append(Check(name: "LIV-6 cancel/finish idempotent", passed: true,
                            note: "cancel() then finish() after termination is a no-op"))
        let after = session.push([0, 0, 0], sampleRate: sampleRate)
        checks.append(Check(name: "LIV-6 push after cancel reports .ended", passed: after == .ended,
                            note: after == .ended
                                ? "post-cancel push answers .ended"
                                : "post-cancel push answered \(after) — samples were dropped and "
                                    + "the outcome does not say so"))
        return Report(checks: checks)
    }

    // MARK: - Helpers

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [STTStreamChunk] = []
        func append(_ chunk: STTStreamChunk) {
            lock.lock(); defer { lock.unlock() }
            chunks.append(chunk)
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return chunks.count
        }
        func snapshot() -> [STTStreamChunk] {
            lock.lock(); defer { lock.unlock() }
            return chunks
        }
    }
}
