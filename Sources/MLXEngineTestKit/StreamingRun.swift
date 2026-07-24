import Foundation
import MLXToolKit
import MLXServeCore
import MLXServeConformance

/// Timed streaming metrics for ONE package — the live half of the STR gate
/// (`MLXServeConformance.StreamingConformance` is the offline half), sibling of
/// `CancellationRun`/`ValidationRun`. Drives `engine.stream()` against a real GPU run and
/// captures the numbers that matter to a realtime consumer: **time-to-first-audio** (dispatch →
/// first chunk), inter-chunk cadence, chunk count, and the STR-4/5 live verdicts. Emit
/// `logLine` (grep `[STR]`) for headless capture; results feed the per-package Val evidence
/// like SPLIT/MAT/CAN lines.
///
/// Live GPU runs only work under the Xcode app harness, NOT the SPM CLI — the metallib
/// boundary (EngineeringDocs/CLAUDE.md).
public struct StreamingRun: Sendable {
    public var packageLabel = ""
    /// Wall time from `engine.stream` dispatch to the FIRST chunk arriving (includes prefill +
    /// reference conditioning on a cold clip — the honest app-perceived TTFA).
    public var timeToFirstChunkSeconds: Double = 0
    public var chunkCount = 0
    /// Mean wall gap between consecutive chunk arrivals (steady-state cadence).
    public var meanInterChunkSeconds: Double = 0
    /// Max wall gap — a stall detector (should stay under one chunk of audio time).
    public var maxInterChunkSeconds: Double = 0
    public var audioSeconds: Double = 0
    public var totalWallSeconds: Double = 0
    /// STR-4 sequence integrity verdict over the collected chunks.
    public var sequenceOK = false
    /// STR-5 aggregation parity verdict vs the completion response (max|Δ| in note).
    public var parityOK = false
    public var note = ""

    public init() {}

    /// Machine-readable capture line (grep `[STR]`).
    public var logLine: String {
        String(format: "[STR] pkg=%@ ttfa=%.0fms chunks=%d cadence=%.0f/%.0fms audio=%.1fs wall=%.1fs rtf=%.2f seq=%@ parity=%@ %@",
               packageLabel, timeToFirstChunkSeconds * 1000, chunkCount,
               meanInterChunkSeconds * 1000, maxInterChunkSeconds * 1000,
               audioSeconds, totalWallSeconds,
               audioSeconds > 0 ? totalWallSeconds / audioSeconds : 0,
               sequenceOK ? "yes" : "NO", parityOK ? "yes" : "NO", note)
    }
}

/// Drives one `engine.stream()` to completion and captures a `StreamingRun`.
@MainActor
public enum StreamingBench {

    /// - Parameters:
    ///   - engine: engine with the package registered AND prepared (a cold load inside the
    ///     window would absorb into TTFA; prepare first for the steady-state number, or don't
    ///     for the honest first-use number — say which in the evidence line).
    ///   - request: the TTS request to stream.
    public static func run(engine: MLXServeEngine,
                           request: TTSRequest,
                           package: PackageID? = nil) async throws -> StreamingRun {
        var result = StreamingRun()
        result.packageLabel = package?.description ?? request.capability.rawValue

        let start = Date()
        let handle = engine.stream(request, package: package)

        var chunks: [TTSStreamChunk] = []
        var arrivals: [Date] = []
        for try await chunk in handle.chunks {
            arrivals.append(Date())
            chunks.append(chunk)
        }
        let response = try await handle.completion.value
        result.totalWallSeconds = Date().timeIntervalSince(start)

        result.chunkCount = chunks.count
        if let first = arrivals.first {
            result.timeToFirstChunkSeconds = first.timeIntervalSince(start)
        }
        if arrivals.count > 1 {
            let gaps = zip(arrivals.dropFirst(), arrivals).map {
                $0.0.timeIntervalSince($0.1)
            }
            result.meanInterChunkSeconds = gaps.reduce(0, +) / Double(gaps.count)
            result.maxInterChunkSeconds = gaps.max() ?? 0
        }

        let rate = chunks.first?.sampleRate ?? 22_050
        let streamedSamples = chunks.reduce(0) { $0 + $1.samples.count }
        result.audioSeconds = Double(streamedSamples) / Double(rate)

        // STR-4/5 live verdicts via the conformance validators.
        let sequence = StreamingConformance.checkSequence(chunks)
        result.sequenceOK = sequence.passed

        let aggregated = pcmSamples(fromWAV16: response.audio.data)
        let parity = StreamingConformance.checkAggregationParity(
            chunks: chunks, aggregated: aggregated,
            tolerance: 1.0 / 32767.0)   // WAV16 round-trip quantization on the aggregated side
        result.parityOK = parity.passed
        result.note = (sequence.passed ? "" : sequence.summary + " ")
            + (parity.passed ? "" : parity.summary)
        return result
    }

    /// Decode 16-bit mono PCM WAV data to normalized floats (44-byte canonical header).
    private static func pcmSamples(fromWAV16 data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        let body = data.dropFirst(44)
        var samples = [Float]()
        samples.reserveCapacity(body.count / 2)
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16s = raw.bindMemory(to: Int16.self)
            for value in int16s {
                samples.append(Float(Int16(littleEndian: value)) / 32767.0)
            }
        }
        return samples
    }
}
