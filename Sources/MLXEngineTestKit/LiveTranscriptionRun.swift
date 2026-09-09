import Foundation
import MLXToolKit
import MLXServeCore
import MLXServeConformance

/// Timed live-transcription metrics for ONE package — the live half of the LIV gate
/// (`MLXServeConformance.LiveTranscriptionConformance` is the offline half), sibling of
/// `StreamingRun`/`CancellationRun`. Drives `engine.transcribeLive()` against a real GPU session
/// and captures what a dictation UI actually feels: **time-to-first-chunk**, chunk cadence, and
/// **commitment lag** — how far behind the audio the settled text runs, which is the number a
/// caption UI's provisional tail is made of and which no other plane exposes.
///
/// Latency is a BENCH, not a gate (AB-D-0069). The pass/fail verdicts carried here are the LIV
/// validators run over the same session, so one drive produces both.
///
/// Live GPU runs only work under the Xcode app harness or a package's own SPM gate executable,
/// NOT `swift test` — the metallib boundary (EngineeringDocs/CLAUDE.md).
public struct LiveTranscriptionRun: Sendable {
    public var packageLabel = ""
    /// Wall time from the first `push` to the FIRST chunk arriving.
    public var timeToFirstChunkSeconds: Double = 0
    public var chunkCount = 0
    /// Mean wall gap between consecutive chunk arrivals (steady-state cadence).
    public var meanInterChunkSeconds: Double = 0
    /// Max wall gap — a stall detector.
    public var maxInterChunkSeconds: Double = 0
    /// Mean `processedSeconds − committedThrough` over the session: the provisional window a
    /// caption UI has to render as unsettled. 0 for a package that commits everything it
    /// decodes; nil when the package publishes no watermark.
    public var meanCommitLagSeconds: Double?
    /// Seconds of audio the session reported consuming.
    public var audioSeconds: Double = 0
    public var totalWallSeconds: Double = 0
    /// How often `push` answered `.overrun` — a feeder outrunning the model. Non-zero is not a
    /// failure by itself; it is a failure if the feeder then DROPPED the audio.
    public var overruns = 0
    /// LIV-4 sequence integrity verdict over the collected chunks.
    public var sequenceOK = false
    /// LIV-2 declared-discipline verdict.
    public var disciplineOK = false
    /// LIV-5 final-parity verdict vs `run(STTRequest)` on the same audio.
    public var parityOK = false
    public var note = ""

    public init() {}

    /// Machine-readable capture line (grep `[LIV]`).
    public var logLine: String {
        String(format: "[LIV] pkg=%@ ttfc=%.0fms chunks=%d cadence=%.0f/%.0fms commitlag=%@ "
                     + "audio=%.1fs wall=%.1fs rtf=%.2f overruns=%d seq=%@ disc=%@ parity=%@ %@",
               packageLabel, timeToFirstChunkSeconds * 1000, chunkCount,
               meanInterChunkSeconds * 1000, maxInterChunkSeconds * 1000,
               meanCommitLagSeconds.map { String(format: "%.0fms", $0 * 1000) } ?? "none",
               audioSeconds, totalWallSeconds,
               audioSeconds > 0 ? totalWallSeconds / audioSeconds : 0,
               overruns,
               sequenceOK ? "yes" : "NO", disciplineOK ? "yes" : "NO",
               parityOK ? "yes" : "NO", note)
    }
}

/// Drives one `engine.transcribeLive()` session to completion and captures a
/// `LiveTranscriptionRun`.
@MainActor
public enum LiveTranscriptionBench {

    /// - Parameters:
    ///   - engine: engine with the package registered AND prepared (a cold load inside the
    ///     window would absorb into time-to-first-chunk).
    ///   - samples: mono PCM at the session's `expectedSampleRate` — the whole clip.
    ///   - bufferSeconds: feed granularity; 0.1 is the shape a microphone tap delivers.
    ///   - realTime: pace the feed to wall-clock audio time (what a microphone does) instead of
    ///     pushing as fast as back-pressure allows. `false` measures compute; `true` measures
    ///     the latency a speaker would feel.
    ///   - batchTranscript: what `run(STTRequest)` returns for the same audio — supply it and
    ///     LIV-5 is evaluated. Omit and `parityOK` stays false with a note saying so.
    public static func run(engine: MLXServeEngine,
                           request: STTSessionRequest = STTSessionRequest(),
                           package: PackageID? = nil,
                           samples: [Float],
                           bufferSeconds: Double = 0.1,
                           realTime: Bool = false,
                           batchTranscript: String? = nil) async throws -> LiveTranscriptionRun {
        var result = LiveTranscriptionRun()
        result.packageLabel = package?.description ?? "stt"

        let handle = try await engine.transcribeLive(request, package: package)
        let rate = handle.expectedSampleRate
        let bufferCount = max(1, Int(bufferSeconds * Double(rate)))

        let collector = Task { () -> ([STTStreamChunk], [Date]) in
            var chunks: [STTStreamChunk] = []
            var arrivals: [Date] = []
            for try await chunk in handle.updates {
                chunks.append(chunk)
                arrivals.append(Date())
            }
            return (chunks, arrivals)
        }

        let start = Date()
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + bufferCount, samples.count)
            switch handle.push(Array(samples[cursor..<end]), sampleRate: rate) {
            case .accepted:
                cursor = end
                if realTime {
                    try await Task.sleep(nanoseconds: UInt64(bufferSeconds * 1_000_000_000))
                } else {
                    await Task.yield()
                }
            case .overrun:
                // Back off and retry the SAME buffer: a file feed can wait where a microphone
                // cannot, and dropping here would corrupt LIV-5 rather than measure anything.
                result.overruns += 1
                try await Task.sleep(nanoseconds: 20_000_000)
            default:
                result.note = "session ended before the feed did"
                cursor = samples.count
            }
        }
        handle.finish()

        let (chunks, arrivals) = try await collector.value
        result.totalWallSeconds = Date().timeIntervalSince(start)
        result.chunkCount = chunks.count
        result.audioSeconds = chunks.last?.processedSeconds ?? 0

        if let first = arrivals.first {
            result.timeToFirstChunkSeconds = first.timeIntervalSince(start)
        }
        let gaps = zip(arrivals, arrivals.dropFirst()).map { $1.timeIntervalSince($0) }
        if !gaps.isEmpty {
            result.meanInterChunkSeconds = gaps.reduce(0, +) / Double(gaps.count)
            result.maxInterChunkSeconds = gaps.max() ?? 0
        }
        let lags = chunks.compactMap { chunk in
            chunk.committedThrough.map { chunk.processedSeconds - $0 }
        }
        result.meanCommitLagSeconds = lags.isEmpty ? nil : lags.reduce(0, +) / Double(lags.count)

        result.sequenceOK = LiveTranscriptionConformance.checkSequence(chunks).passed
        result.disciplineOK = LiveTranscriptionConformance
            .checkDiscipline(chunks, declared: handle.discipline).passed
        if let batchTranscript {
            let parity = LiveTranscriptionConformance.checkFinalParity(
                chunks: chunks, discipline: handle.discipline,
                batchTranscript: batchTranscript)
            result.parityOK = parity.passed
            if !parity.passed, result.note.isEmpty {
                result.note = parity.checks.first?.note ?? ""
            }
        } else if result.note.isEmpty {
            result.note = "LIV-5 not evaluated (no batch transcript supplied)"
        }
        return result
    }
}
