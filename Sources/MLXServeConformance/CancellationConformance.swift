import Foundation
import MLXToolKit

/// Offline cancellation-honoring contract check — the "CAN gate", the executable adjunct to the
/// C13 cancellation convention the same way `MaterializationConformance` (MAT-1..5) is to the
/// `WeightSourcing` convention. No MLX kernels, no weights: the run checks drive the package's
/// real `run()` under a *pre-set* cancellation so the entry checkpoint fires before any weights
/// would be touched, and the cadence check verifies a *declaration*.
///
/// The gate encodes the FINAL run-lifecycle semantics (program V1–V3, engine 0.26.0): a package
/// rethrows `CancellationError` unchanged from its cooperative checkpoints; the ENGINE
/// disambiguates the two lanes — a user cancel (the app cancelling the `Task` wrapping
/// `engine.run()`) surfaces the `CancellationError` to the caller (classify `.cancelled`, not
/// failed), a governor preemption is recognized as the engine's own doing and REQUEUED. The
/// package's whole obligation is: checkpoint often, unwind cleanly, never launder the error.
///
/// Call from the package's own conformance tests (the per-package suite convention):
/// ```swift
/// let pkg = MyPackage(configuration: MyConfiguration())   // stub/smallest config; init is cheap (C13)
/// let report = await CancellationConformance.checkRun(package: pkg,
///                                                     request: MySmallestRequest())
/// XCTAssertTrue(report.passed, report.summary)
///
/// let cadence = CancellationConformance.checkCadence(
///     manifest: MyPackage.manifest,
///     posture: .cadence([.init(phase: .denoise, unit: .step, reportsRunProgress: true),
///                        .init(phase: .decode, unit: .chunk, reportsRunProgress: true)]))
/// XCTAssertTrue(cadence.passed, cadence.summary)
/// ```
/// The live counterpart — a timed mid-run cancel-latency probe against a real GPU run — is
/// `MLXEngineTestKit.CancellationBench` (the `[CAN]` bench, Xcode-app harness only).
public enum CancellationConformance {

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

    // MARK: - CAN-1 / CAN-2 — pre-cancelled run() propagation + classification

    /// Drives the package's `run()` inside a task that is ALREADY cancelled when `run()` begins.
    /// Offline-safe for any package: the required entry checkpoint (`try Task.checkCancellation()`
    /// as the first act of `run()`) throws before validation or weights are touched, so a stub
    /// configuration suffices. This form needs no run duration, so packages with inherently
    /// sub-second runs take the same check — their exemption lives in CAN-3, not here.
    ///
    /// - **CAN-1 entry-checkpoint propagation** — the pre-cancelled `run()` refuses to proceed:
    ///   it surfaces `CancellationError` (or a cancelled-marked response, below). The signature
    ///   failure is `PackageError.notLoaded`: the run went on to its normal validation instead of
    ///   checking cancellation first.
    /// - **CAN-2 cancellation classification** — the surfaced outcome is the canonical
    ///   cancelled-not-failed shape: the `CancellationError` rethrown UNCHANGED (never wrapped in
    ///   a package failure enum — the engine's lane disambiguation and the caller's `.cancelled`
    ///   classification both key on the type), or, for a package that absorbs cancellation into a
    ///   partial response, a response the capability's own shape marks cancelled
    ///   (`FinishReason.cancelled` where the shape has one) — prove that path by passing
    ///   `classifiesCancelled` (e.g. `{ ($0 as? LLMResponse)?.finishReason == .cancelled }`).
    public static func checkRun(
        package: any ModelPackage,
        request: any CapabilityRequest,
        classifiesCancelled: (@Sendable (any CapabilityResponse) -> Bool)? = nil
    ) async -> Report {
        // Hold the run behind a gate, cancel the task, THEN release — deterministic: `run()`
        // never begins before the cancellation is set. (A cancelled task ends the stream
        // iteration immediately, so the release also can't deadlock.)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task<any CapabilityResponse, any Error> { @InferenceActor in
            for await _ in stream {}
            return try await package.run(request)
        }
        task.cancel()
        continuation.finish()
        let outcome = await task.result

        var checks: [Check] = []
        switch outcome {
        case .failure(is CancellationError):
            checks.append(Check(name: "CAN-1 entry-checkpoint propagation", passed: true,
                                note: "pre-cancelled run() surfaced CancellationError"))
            checks.append(Check(name: "CAN-2 cancellation classification", passed: true,
                                note: "CancellationError rethrown unchanged — engine/caller "
                                    + "classify cancelled, not failed"))
        case .failure(let error):
            let laundered = "\(type(of: error)).\(error)"
            if (error as? PackageError) == .notLoaded {
                checks.append(Check(name: "CAN-1 entry-checkpoint propagation", passed: false,
                                    note: "run() reached PackageError.notLoaded despite pre-set "
                                        + "cancellation — no entry checkpoint; make "
                                        + "`try Task.checkCancellation()` the first act of run()"))
                checks.append(Check(name: "CAN-2 cancellation classification", passed: false,
                                    note: "no cancellation outcome to classify (see CAN-1)"))
            } else {
                checks.append(Check(name: "CAN-1 entry-checkpoint propagation", passed: false,
                                    note: "cancelled run() threw \(laundered) instead of "
                                        + "CancellationError"))
                checks.append(Check(name: "CAN-2 cancellation classification", passed: false,
                                    note: "cancellation laundered into \(laundered) — rethrow "
                                        + "the CancellationError unchanged; the engine's lane "
                                        + "disambiguation and the caller's .cancelled state "
                                        + "both key on the type"))
            }
        case .success(let response):
            if let classifiesCancelled, classifiesCancelled(response) {
                checks.append(Check(name: "CAN-1 entry-checkpoint propagation", passed: true,
                                    note: "run() absorbed the cancellation into a "
                                        + "cancelled-marked partial response"))
                checks.append(Check(name: "CAN-2 cancellation classification", passed: true,
                                    note: "returned response carries the capability's "
                                        + "cancelled marker"))
            } else {
                checks.append(Check(name: "CAN-1 entry-checkpoint propagation", passed: false,
                                    note: "pre-cancelled run() completed normally "
                                        + "(\(type(of: response))) — cancellation ignored"))
                checks.append(Check(name: "CAN-2 cancellation classification", passed: false,
                                    note: classifiesCancelled == nil
                                        ? "no cancellation outcome to classify (see CAN-1)"
                                        : "returned response is not classified cancelled by "
                                            + "the capability's marker"))
            }
        }
        return Report(checks: checks)
    }

    // MARK: - CAN-3 — checkpoint-cadence declaration

    /// The unit a cooperative checkpoint recurs on within a phase — the governed vocabulary the
    /// declaration draws from (per the LTX-proven placements: per denoise step, per VAE-decode
    /// chunk, per generated token, per decoded frame, per encoder layer).
    public enum CadenceUnit: String, Sendable, Codable {
        case step, chunk, token, frame, layer
    }

    /// One declared checkpoint cadence: "in `phase`, `run()` checks cancellation once per
    /// `unit`". Set `reportsRunProgress` when the package reports `RunProgress` per that same
    /// unit (V2, contract 1.18) — a package that reports `.denoise` step i/N necessarily has a
    /// per-step yield point, so the progress plane is accepted as *observable evidence* of the
    /// cadence rather than a bare claim.
    public struct CheckpointCadence: Sendable {
        public let phase: RunPhase
        public let unit: CadenceUnit
        public let reportsRunProgress: Bool
        public init(phase: RunPhase, unit: CadenceUnit, reportsRunProgress: Bool = false) {
            self.phase = phase
            self.unit = unit
            self.reportsRunProgress = reportsRunProgress
        }
    }

    /// The package's declared cancellation posture. The declaration made in the package's own
    /// conformance suite IS the document of record for its checkpoint cadence (the same way the
    /// MAT declarations live on the configuration) — mirror it in the package README if desired,
    /// but the gate reads this value.
    public enum CheckpointPosture: Sendable {
        /// Long-run posture: the checkpoints `run()` actually implements, phase by phase.
        case cadence([CheckpointCadence])
        /// Exemption for packages whose runs are inherently sub-second (one MLX eval, nothing
        /// to preempt): state why. Not credible on a manifest that implies long runs.
        case subSecondRuns(reason: String)
    }

    /// Capabilities whose runs are long by nature (video/audio generation — the Qwen3-TTS Talker
    /// loop is the motivating miss). Packages backing any of these must declare a cadence.
    public static let longRunCapabilities: Set<Capability> = [
        .textToVideo, .videoEdit, .videoUpscale, .frameInterpolate, .characterAnimation,
        .talkingHead, .tts, .soundEffect, .imageTo3D, .meshRig,
        // stt transcribes arbitrarily long audio via the cache-aware chunk loop — genuinely
        // long-run, so a cadence declaration is required (contract 1.20.0).
        .stt,
        // videoAnalysis samples frames, runs a ViT over thousands of visual tokens, then
        // autoregresses an answer — measured at ~8 s for a 16-frame clip on an M5 Max. It was
        // absent here only because the capability had no provider until Mage-VL; the omission
        // was never exercised rather than deliberate. imageAnalysis stays out: a single image is
        // one short prefill plus a short generation.
        .videoAnalysis,
    ]

    /// Declared transient peak at or above this implies a long run regardless of capability
    /// (multi-GB activation ⇒ heavyweight iterative compute worth preempting).
    public static let longRunActivationBytes: UInt64 = 2_000_000_000

    /// Does the manifest's declared envelope imply long runs? True when any surface capability
    /// is in `longRunCapabilities`, or any quant footprint declares `peakActivationBytes ≥
    /// longRunActivationBytes`.
    public static func longRunImplied(by manifest: PackageManifest) -> Bool {
        !longRunCapabilities.isDisjoint(with: manifest.capabilities)
            || manifest.requirements.footprints.contains {
                $0.peakActivationBytes >= longRunActivationBytes
            }
    }

    /// **CAN-3 checkpoint cadence** — a package whose manifest implies long runs documents its
    /// checkpoint cadence from the governed vocabulary. A short-run package may declare
    /// `.subSecondRuns(reason:)` instead; that exemption fails on a long-run-implied manifest
    /// (waivable only via the conformance checklist's documented-waiver convention).
    public static func checkCadence(manifest: PackageManifest,
                                    posture: CheckpointPosture) -> Report {
        let longRun = longRunImplied(by: manifest)
        let envelope: String = {
            let caps = manifest.capabilities.filter(longRunCapabilities.contains)
                .map(\.rawValue)
            let activation = manifest.requirements.footprints
                .map(\.peakActivationBytes).max() ?? 0
            var parts: [String] = []
            if !caps.isEmpty { parts.append("capabilities \(caps.joined(separator: "+"))") }
            if activation >= longRunActivationBytes {
                parts.append(String(format: "peak activation %.1f GB",
                                    Double(activation) / 1_000_000_000))
            }
            return parts.isEmpty ? "short-run envelope" : parts.joined(separator: ", ")
        }()

        let check: Check
        switch posture {
        case .cadence(let cadences) where cadences.isEmpty:
            check = Check(name: "CAN-3 checkpoint cadence", passed: false,
                          note: "empty cadence declaration — name the phases and units run() "
                              + "checkpoints on, or declare .subSecondRuns(reason:)")
        case .cadence(let cadences):
            let listed = cadences.map {
                "\($0.phase.rawValue)/\($0.unit.rawValue)"
                    + ($0.reportsRunProgress ? " (RunProgress-evidenced)" : " (declared)")
            }
            check = Check(name: "CAN-3 checkpoint cadence", passed: true,
                          note: listed.joined(separator: ", "))
        case .subSecondRuns(let reason) where longRun:
            check = Check(name: "CAN-3 checkpoint cadence", passed: false,
                          note: "sub-second exemption claimed but the manifest implies long "
                              + "runs (\(envelope)) — declare a checkpoint cadence"
                              + (reason.isEmpty ? "" : " (claimed: \(reason))"))
        case .subSecondRuns(let reason):
            check = Check(name: "CAN-3 checkpoint cadence",
                          passed: !reason.isEmpty,
                          note: reason.isEmpty
                              ? "sub-second exemption requires a stated reason"
                              : "exempt — sub-second runs: \(reason)")
        }
        return Report(checks: [check])
    }
}
