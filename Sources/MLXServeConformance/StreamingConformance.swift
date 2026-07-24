//
//  StreamingConformance.swift
//  MLXServeConformance
//
//  The "STR gate" (contract 1.25.0, ENGINE-NEEDS N2) — the executable adjunct to the
//  `StreamEmitting` convention, the way CAN-1..3 is to cancellation and MAT-1..5 is to
//  `WeightSourcing`.
//
//  Offline (no MLX kernels, no weights — call from the package's own conformance tests):
//    STR-1 advertisement⇔conformance coherence
//    STR-2 pre-cancelled runStream propagation (zero chunks + CancellationError unchanged)
//    STR-3 stream-posture declaration
//  Live validators (pure functions over chunks a CLI lane collected from a real GPU run):
//    STR-4 chunk-sequence integrity
//    STR-5 aggregation parity vs the returned response
//  STR-6 (task-context emission canary — `withEmissionCanary`) and STR-7 (mid-stream cancel)
//  run in the package's live CLI lane; STR-7 reuses `checkSequence` on the truncated chunks.
//  Latency (TTFA / cadence) is a bench (`MLXEngineTestKit.StreamingBench`), not a gate.
//

import Foundation
import MLXToolKit

public enum StreamingConformance {

    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let note: String
    }

    public struct Report: Sendable {
        public let checks: [Check]
        public var passed: Bool { checks.allSatisfy(\.passed) }
        public var summary: String {
            checks.map { "\($0.passed ? "✅" : "❌") \($0.name) — \($0.note)" }
                .joined(separator: "\n")
        }
    }

    /// A `StreamEmitting` package's declared chunking posture (the STR-3 document of record —
    /// the streaming sibling of CAN-3's cadence declaration; reference, don't duplicate, the
    /// CAN-3 cadence for the same loop).
    public struct StreamPosture: Sendable {
        /// Nominal frames per emitted chunk (the steady cadence; a smaller first chunk is fine).
        public let chunkFrames: Int
        /// Left-context frames re-decoded (and trimmed) per chunk for exactness (0 = stateful).
        public let leftContextFrames: Int
        /// The constant sample rate every chunk carries.
        public let sampleRate: Int
        /// Whether the package reports `RunProgress` per emitted chunk.
        public let reportsRunProgress: Bool

        public init(chunkFrames: Int, leftContextFrames: Int, sampleRate: Int,
                    reportsRunProgress: Bool) {
            self.chunkFrames = chunkFrames
            self.leftContextFrames = leftContextFrames
            self.sampleRate = sampleRate
            self.reportsRunProgress = reportsRunProgress
        }
    }

    // MARK: - STR-1 — advertisement ⇔ conformance coherence (offline, type-level)

    /// Both directions: a manifest surface declaring `streaming != nil` requires the package
    /// type to conform to `StreamEmitting`, and a conforming type must advertise on at least
    /// one surface — silent drift between descriptor and implementation fails here.
    public static func checkAdvertisement<P: ModelPackage>(_ type: P.Type) -> Report {
        let advertised = P.manifest.surfaces.contains { $0.streaming != nil }
        let conforms = P.self is any StreamEmitting.Type
        let check: Check
        switch (advertised, conforms) {
        case (true, true):
            check = Check(name: "STR-1 advertisement coherence", passed: true,
                          note: "surface advertises streaming and the package conforms to "
                              + "StreamEmitting")
        case (false, false):
            check = Check(name: "STR-1 advertisement coherence", passed: true,
                          note: "batch-only package: no streaming advertisement, no conformance")
        case (true, false):
            check = Check(name: "STR-1 advertisement coherence", passed: false,
                          note: "a surface declares streaming but \(P.self) does not conform "
                              + "to StreamEmitting — the descriptor is lying")
        case (false, true):
            check = Check(name: "STR-1 advertisement coherence", passed: false,
                          note: "\(P.self) conforms to StreamEmitting but no surface declares "
                              + "streaming — consumers can never discover it")
        }
        return Report(checks: [check])
    }

    // MARK: - STR-2 — pre-cancelled runStream propagation (offline)

    /// The CAN-1 gate transposed to `runStream`: drive it inside an ALREADY-cancelled task with
    /// a collecting `emit`. Asserts the `CancellationError` surfaces unchanged AND zero chunks
    /// were emitted (a chunk under pre-set cancellation means no entry checkpoint precedes the
    /// first emit). Offline-safe: the entry checkpoint throws before weights are touched.
    public static func checkPreCancelledStream(
        package: any StreamEmitting,
        request: any CapabilityRequest
    ) async -> Report {
        let collector = ChunkCollector()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task<any CapabilityResponse, any Error> { @InferenceActor in
            for await _ in stream {}
            return try await package.runStream(request) { chunk in
                collector.append(chunk)
            }
        }
        task.cancel()
        continuation.finish()
        let outcome = await task.result
        let emitted = collector.snapshot()

        var checks: [Check] = []
        switch outcome {
        case .failure(is CancellationError):
            checks.append(Check(name: "STR-2 pre-cancelled runStream", passed: true,
                                note: "CancellationError surfaced unchanged"))
        case .failure(let error):
            checks.append(Check(name: "STR-2 pre-cancelled runStream", passed: false,
                                note: "pre-cancelled runStream threw "
                                    + "\(type(of: error)).\(error) instead of CancellationError"))
        case .success:
            checks.append(Check(name: "STR-2 pre-cancelled runStream", passed: false,
                                note: "pre-cancelled runStream completed normally — "
                                    + "cancellation ignored"))
        }
        checks.append(Check(
            name: "STR-2 zero chunks under pre-set cancellation", passed: emitted.isEmpty,
            note: emitted.isEmpty
                ? "no chunks emitted before the entry checkpoint"
                : "\(emitted.count) chunk(s) emitted despite pre-set cancellation — the entry "
                    + "checkpoint must precede the first emit"))
        return Report(checks: checks)
    }

    // MARK: - STR-3 — stream-posture declaration (offline)

    /// A package whose surface advertises `.audioChunk` declares its posture; the check asserts
    /// internal coherence. The declaration in the package's conformance suite is the document
    /// of record.
    public static func checkPosture<P: ModelPackage>(_ type: P.Type,
                                                     posture: StreamPosture?) -> Report {
        let advertised = P.manifest.surfaces.contains { $0.streaming != nil }
        var checks: [Check] = []
        if !advertised {
            checks.append(Check(name: "STR-3 posture declaration", passed: posture == nil,
                                note: posture == nil
                                    ? "batch-only package — no posture expected"
                                    : "posture declared but no surface advertises streaming"))
            return Report(checks: checks)
        }
        guard let posture else {
            checks.append(Check(name: "STR-3 posture declaration", passed: false,
                                note: "surface advertises streaming but no posture declared"))
            return Report(checks: checks)
        }
        let coherent = posture.chunkFrames > 0 && posture.leftContextFrames >= 0
            && posture.sampleRate > 0
        checks.append(Check(
            name: "STR-3 posture declaration", passed: coherent,
            note: coherent
                ? "chunkFrames=\(posture.chunkFrames) leftContext=\(posture.leftContextFrames) "
                    + "rate=\(posture.sampleRate) runProgress=\(posture.reportsRunProgress)"
                : "incoherent posture (chunkFrames/sampleRate must be positive, "
                    + "leftContextFrames non-negative)"))
        return Report(checks: checks)
    }

    // MARK: - STR-4 — chunk-sequence integrity (live validator)

    /// Pure validator over chunks collected from a real run: `index` 0-based, strictly
    /// monotonic, no gaps; `isFinal` on exactly the last chunk (`expectTruncated: true` for a
    /// cancelled run, where no final marker is expected); constant `sampleRate`.
    public static func checkSequence(_ chunks: [TTSStreamChunk],
                                     expectTruncated: Bool = false) -> Report {
        var checks: [Check] = []
        guard !chunks.isEmpty else {
            return Report(checks: [Check(name: "STR-4 sequence integrity",
                                         passed: expectTruncated,
                                         note: expectTruncated
                                             ? "cancelled before first chunk — vacuously ordered"
                                             : "no chunks emitted")])
        }
        let indices = chunks.map(\.index)
        let ordered = indices == Array(0..<chunks.count)
        checks.append(Check(name: "STR-4 index ordering", passed: ordered,
                            note: ordered ? "0-based, strictly monotonic, no gaps"
                                          : "indices \(indices)"))
        let rates = Set(chunks.map(\.sampleRate))
        checks.append(Check(name: "STR-4 constant sampleRate", passed: rates.count == 1,
                            note: "rates \(rates.sorted())"))
        let finals = chunks.enumerated().filter { $0.element.isFinal }.map(\.offset)
        let finalOK = expectTruncated ? finals.isEmpty : finals == [chunks.count - 1]
        checks.append(Check(
            name: "STR-4 isFinal placement", passed: finalOK,
            note: expectTruncated
                ? (finals.isEmpty ? "truncated stream carries no final marker"
                                  : "final marker at \(finals) on a truncated stream")
                : (finalOK ? "exactly once, on the last chunk" : "final markers at \(finals))")))
        return Report(checks: checks)
    }

    // MARK: - STR-5 — aggregation parity (live validator)

    /// Concatenated chunk samples must equal the aggregated response's PCM. `tolerance` 0 for
    /// causal decoders (bit-exact); document any non-zero escape in the package's suite.
    public static func checkAggregationParity(chunks: [TTSStreamChunk],
                                              aggregated: [Float],
                                              tolerance: Float = 0) -> Report {
        let streamed = chunks.flatMap(\.samples)
        guard streamed.count == aggregated.count else {
            return Report(checks: [Check(
                name: "STR-5 aggregation parity", passed: false,
                note: "length mismatch: streamed \(streamed.count) vs aggregated "
                    + "\(aggregated.count) samples")])
        }
        var maxDelta: Float = 0
        for i in 0..<streamed.count {
            maxDelta = max(maxDelta, abs(streamed[i] - aggregated[i]))
        }
        let pass = maxDelta <= tolerance
        return Report(checks: [Check(
            name: "STR-5 aggregation parity", passed: pass,
            note: String(format: "max|Δ| %.3g over %d samples (tolerance %.3g)",
                         maxDelta, streamed.count, tolerance))])
    }

    // MARK: - STR-6 — task-context emission canary (live lane utility)

    /// Binds a task-local canary around `body` (the package's `runStream` call); every `emit`
    /// must observe it via `emissionCanaryVisible`. Emission from a detached task — where
    /// `RunProgress.$sink` and this canary are both invisible — fails here instead of silently
    /// dropping progress in production.
    @TaskLocal private static var emissionCanary = false

    public static var emissionCanaryVisible: Bool { emissionCanary }

    public static func withEmissionCanary<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $emissionCanary.withValue(true) { try await body() }
    }

    // MARK: - Helpers

    /// Thread-safe chunk collector for the offline checks (emit is @Sendable).
    private final class ChunkCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [TTSStreamChunk] = []
        func append(_ chunk: TTSStreamChunk) {
            lock.lock(); defer { lock.unlock() }
            chunks.append(chunk)
        }
        func snapshot() -> [TTSStreamChunk] {
            lock.lock(); defer { lock.unlock() }
            return chunks
        }
    }
}
