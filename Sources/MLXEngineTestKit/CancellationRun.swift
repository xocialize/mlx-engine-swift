import Foundation
import MLXToolKit
import MLXServeCore

/// Timed cancel-latency metrics for ONE package — the live half of the CAN gate
/// (`MLXServeConformance.CancellationConformance` is the offline half), sibling of
/// `MaterializationRun`/`ValidationRun`. Cancel at T seconds into a REAL run, measure
/// time-to-throw (one MLX eval is the substrate floor — LTX measured 1.08 s steady-state,
/// 16–21 s inside a compile-heavy first step), and prove the clean cancel→re-run recovery.
/// This bench replaces bespoke per-app harnesses (LTX's `LTX_CANCEL_TEST` /
/// `LTX_CANCEL_AFTER` / `LTX_CANCEL_RERUN` levers). Emit `logLine` (grep `[CAN]`) for
/// headless capture; results feed the per-package Val evidence like SPLIT/MAT lines.
///
/// Live GPU runs only work under the Xcode app harness (`MLXEngine Testing` or the area app),
/// NOT the SPM CLI — the metallib boundary (EngineeringDocs/CLAUDE.md).
public struct CancellationRun: Sendable {
    public var packageLabel = ""
    public var cancelAfterSeconds: Double = 0
    /// Wall time from `cancel()` to the run surfacing its outcome — the cancel latency.
    public var timeToThrowSeconds: Double = 0
    /// The cancelled run surfaced `CancellationError` (the pass condition; user-cancel lane).
    public var surfacedCancellation = false
    /// The run returned success instead of throwing: it either finished before T (re-probe
    /// with a smaller `cancelAfterSeconds` or a longer request) or ignored the cancel
    /// (a CAN-1 failure at run scale). Never a pass by itself.
    public var ranToCompletion = false
    /// Human-readable outcome (error type, or the response type on completion).
    public var outcomeNote = ""
    /// Last V2 `RunPhaseReport` observed before the cancel — names which phase absorbed the
    /// latency (denoise step vs compile-heavy first step vs decode chunk). `nil` = the package
    /// reported no progress (itself a smell for a long-run package).
    public var phaseAtCancel: String?
    public var rerunSucceeded = false
    public var rerunSeconds: Double = 0

    public init() {}

    /// Machine-readable capture line (grep `[CAN]`).
    public var logLine: String {
        String(format: "[CAN] pkg=%@ cancelAfter=%.1fs latency=%.2fs cancelled=%@ phase=%@ completed=%@ rerun=%@ rerunSecs=%.1f note=%@",
               packageLabel, cancelAfterSeconds, timeToThrowSeconds,
               surfacedCancellation ? "yes" : "NO",
               phaseAtCancel ?? "-",
               ranToCompletion ? "YES" : "no",
               rerunSucceeded ? "yes" : "NO",
               rerunSeconds, outcomeNote)
    }
}

/// Drives one engine run, cancels it at T, and captures a `CancellationRun`. Generic over
/// packages — any capability, any request. The run exercises the SANCTIONED user-cancel seam
/// (cancel the `Task` wrapping `engine.run()`, run-lifecycle V3), so what it measures is
/// exactly what an app's Cancel button gets.
@MainActor
public enum CancellationBench {

    /// - Parameters:
    ///   - engine: engine with the package registered AND prepared (a cold `load()` inside the
    ///     window would absorb the cancel latency into load time; prepare first, or set
    ///     `cancelAfterSeconds` past the expected load).
    ///   - request: a request long enough that T seconds lands mid-run (steps/frames/tokens
    ///     sized well past the cancel point).
    ///   - cancelAfterSeconds: when to cancel, measured from `engine.run` dispatch.
    ///   - rerun: prove the clean cancel→re-run recovery by running the same request to
    ///     completion afterwards (the measured post-cancel pattern; LRU keeps the weights hot).
    public static func run(engine: MLXServeEngine,
                           request: any CapabilityRequest,
                           package: PackageID? = nil,
                           cancelAfterSeconds: Double,
                           rerun: Bool = true) async throws -> CancellationRun {
        var result = CancellationRun()
        result.packageLabel = package?.description ?? request.capability.rawValue
        result.cancelAfterSeconds = cancelAfterSeconds
        let capability = request.capability
        let monitor = engine.runProgress

        let task = Task { try await engine.run(request, package: package) }

        // Wait out the window, sampling the V2 progress plane for the phase-at-cancel.
        let deadline = Date().addingTimeInterval(cancelAfterSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let report = monitor.report(for: capability, package: package?.description) {
                result.phaseAtCancel = describe(report)
            }
        }

        let cancelAt = Date()
        task.cancel()
        let outcome = await task.result
        result.timeToThrowSeconds = Date().timeIntervalSince(cancelAt)

        switch outcome {
        case .success(let response):
            result.ranToCompletion = true
            result.outcomeNote = "completed with \(type(of: response))"
        case .failure(let error):
            result.surfacedCancellation = error is CancellationError
            result.outcomeNote = result.surfacedCancellation
                ? "CancellationError" : "threw \(type(of: error)): \(error)"
        }

        if rerun {
            let rerunStart = Date()
            do {
                _ = try await engine.run(request, package: package)
                result.rerunSucceeded = true
            } catch {
                result.rerunSucceeded = false
                result.outcomeNote += " · rerun threw \(type(of: error)): \(error)"
            }
            result.rerunSeconds = Date().timeIntervalSince(rerunStart)
        }
        return result
    }

    private static func describe(_ report: RunPhaseReport) -> String {
        var s = report.phase.rawValue
        if let step = report.step {
            s += " \(step)" + (report.totalSteps.map { "/\($0)" } ?? "")
        }
        if let stage = report.stage {
            s += " (stage \(stage)" + (report.totalStages.map { "/\($0)" } ?? "") + ")"
        }
        return s
    }
}
