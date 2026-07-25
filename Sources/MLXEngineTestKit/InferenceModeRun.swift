import Foundation
import MLXToolKit
import MLXServeCore

/// **INF-3 idempotence** — the live half of the INF gate (C14), sibling of `CancellationRun` /
/// `MaterializationRun` / `StreamingRun`. `MLXServeConformance.InferenceModeConformance`
/// (INF-1..2) is the declarative half.
///
/// Two identical `run()` calls against ONE loaded package instance must produce identical output.
/// This is the check that catches the failure *class* rather than the known mechanism: a
/// `BatchNorm` left in training mode overwrites `running_mean`/`running_var` on every forward, so
/// the second run reads statistics the first one moved — the outputs diverge. A live `Dropout`
/// diverges for a different reason (fresh `MLXRandom.bernoulli` per call). Both land here without
/// the bench knowing anything about norms, which is why INF-3 is worth running even on a package
/// that passes INF-1 today.
///
/// A divergence is not *proof* of training mode — a package with genuine per-call nondeterminism
/// (an unseeded sampler, a random latent) diverges legitimately. Pass a fixed seed in the request
/// where the capability has one; where it does not, read a failure as "investigate", not "guilty".
/// Convergence, on the other hand, is strong evidence: it is exactly what the BiRefNet bug could
/// not produce.
///
/// Live GPU runs only work under the Xcode app harness (`MLXEngine Testing` or the area app), NOT
/// the SPM CLI — the metallib boundary (EngineeringDocs/CLAUDE.md). Emit `logLine` (grep `[INF]`)
/// for headless capture; results feed the per-package Val evidence like the SPLIT/MAT/CAN lines.
public struct InferenceModeRun: Sendable {
    public var packageLabel = ""
    /// Both runs completed and their digests matched — the pass condition.
    public var identical = false
    /// Digest of run 1 / run 2, hex-truncated for the log line.
    public var firstDigest = ""
    public var secondDigest = ""
    /// Bytes compared per run. `0` means the digest closure returned nil for at least one run —
    /// nothing was actually compared, which is never a pass.
    public var digestedBytes = 0
    public var firstRunSeconds: Double = 0
    public var secondRunSeconds: Double = 0
    /// Human-readable outcome (mismatch detail, or the error a run threw).
    public var note = ""

    public init() {}

    /// Machine-readable capture line (grep `[INF]`).
    public var logLine: String {
        String(format: "[INF] pkg=%@ identical=%@ bytes=%d d1=%@ d2=%@ secs=%.2f/%.2f note=%@",
               packageLabel,
               identical ? "yes" : "NO",
               digestedBytes,
               firstDigest.isEmpty ? "-" : firstDigest,
               secondDigest.isEmpty ? "-" : secondDigest,
               firstRunSeconds, secondRunSeconds, note)
    }
}

/// Runs one request twice against the same prepared package and compares the results.
@MainActor
public enum InferenceModeBench {

    /// - Parameters:
    ///   - engine: engine with the package registered AND **prepared**. Preparing first is what
    ///     makes this a same-instance test — an eviction between the two runs would reload the
    ///     checkpoint and hide exactly the drift being probed.
    ///   - request: keep it small; INF-3 cares about determinism, not throughput. Fix any seed the
    ///     capability exposes.
    ///   - digest: extracts the comparable bytes from a response. There is no generic accessor —
    ///     `CapabilityResponse` is a marker protocol — so the caller names the payload, e.g.
    ///     `{ ($0 as? MattingResponse)?.matte.data }`. Returning `nil` fails the run rather than
    ///     passing on an empty comparison.
    public static func run(engine: MLXServeEngine,
                           request: any CapabilityRequest,
                           package: PackageID? = nil,
                           digest: @Sendable (any CapabilityResponse) -> Data?) async -> InferenceModeRun {
        var result = InferenceModeRun()
        result.packageLabel = package?.description ?? request.capability.rawValue

        func once() async -> (Data?, Double, String?) {
            let start = Date()
            do {
                let response = try await engine.run(request, package: package)
                return (digest(response), Date().timeIntervalSince(start), nil)
            } catch {
                return (nil, Date().timeIntervalSince(start),
                        "threw \(type(of: error)): \(error)")
            }
        }

        let (first, firstSeconds, firstError) = await once()
        let (second, secondSeconds, secondError) = await once()
        result.firstRunSeconds = firstSeconds
        result.secondRunSeconds = secondSeconds

        if let firstError {
            result.note = "run 1 \(firstError)"
            return result
        }
        if let secondError {
            result.note = "run 2 \(secondError)"
            return result
        }
        guard let first, let second else {
            result.note = "digest returned nil for "
                + (first == nil ? "run 1" : "run 2")
                + " — nothing compared; give the bench a payload accessor for this capability"
            return result
        }

        result.firstDigest = shortDigest(first)
        result.secondDigest = shortDigest(second)
        result.digestedBytes = first.count
        result.identical = first == second

        if result.identical {
            result.note = "byte-identical across two runs on one loaded instance"
        } else if first.count != second.count {
            result.note = "output SIZE changed between runs (\(first.count) → \(second.count) B)"
        } else {
            let differing = zip(first, second).reduce(into: 0) { $0 += ($1.0 == $1.1 ? 0 : 1) }
            result.note = "\(differing)/\(first.count) bytes differ between two runs on ONE loaded "
                + "instance — the model mutated itself. Check INF-1 (a BatchNorm left in training "
                + "mode rewrites running_mean/running_var every forward); if INF-1 is green, look "
                + "for an unseeded sampler before concluding a defect"
        }
        return result
    }

    /// Order-independent, allocation-light content fingerprint. Not cryptographic — it exists to
    /// put a short comparable token in the `[INF]` line; equality is decided on the full bytes.
    private static func shortDigest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
