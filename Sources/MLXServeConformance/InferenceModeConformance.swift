import Foundation
import MLXToolKit

/// Inference-mode contract check — the "INF gate", the executable adjunct to **C14** the same way
/// `MaterializationConformance` (MAT-1..5) is to the `WeightSourcing` convention and
/// `CancellationConformance` (CAN-1..3) is to C13's cancellation half.
///
/// ## Why this exists
///
/// `MLXNN.Module.training` defaults to **`true`**. In that state `BatchNorm.callAsFunction`
/// normalizes by the CURRENT BATCH's statistics and *overwrites* the checkpoint's
/// `running_mean` / `running_var` on every forward (mlx-swift `Source/MLXNN/Normalization.swift`:
/// `if self.training, let runningMean, let runningVar`) — so inference silently runs on per-input
/// statistics, the trained statistics are never read, and repeated calls on one loaded instance
/// drift. `Dropout` is the same class of hazard and is **not** identity-safe: it short-circuits
/// only when `p == 0` **or** `!training` (`Source/MLXNN/Dropout.swift`), so a port that faithfully
/// carries its upstream `p` randomly zeroes activations at inference.
///
/// Neither failure is visible to eyeball validation. In mlx-birefnet-swift (found 2026-07-25) the
/// matte still looked like a matte while the PROD fast tier over-segmented by 68 % (foreground
/// fraction 0.42 vs the PyTorch oracle's 0.25), and end-to-end logits cosine against the oracle was
/// **0.264**. One `model.train(false)` at the pipeline construction choke point took it to
/// **0.99999**. Nothing in C0–C13 asked, and the offline gates never run a kernel, so it shipped.
///
/// ## What the gate asserts
///
/// **Presence of inference mode on the LOADED graph is the criterion — never output plausibility.**
/// A port can look fine purely because its weights happen to make batch statistics close to the
/// running statistics; that is luck, not conformance. Equally, the *presence of `.train(false)` in
/// source* is not the criterion: the call may sit on a path this configuration doesn't take, or a
/// later-constructed submodule may be added after it runs. The gate reads flags off the real graph.
///
/// - **INF-1 inference mode** — every `Module` reachable from the package's loaded graph reports
///   `training == false`. Any module in training mode fails, including inert ones (a `Linear` in
///   training mode carries no numerical hazard by itself, but it proves `train(false)` never ran
///   over that subtree — which is the regression signal).
/// - **INF-2 posture declaration** — a package with no module graph (a functional port whose norms
///   read `running_mean`/`running_var` straight out of the weight dict, or a non-MLX package)
///   declares `.notApplicable(reason:)`. The exemption is falsifiable: it fails if the walk
///   actually observed modules.
///
/// INF-1 needs the **loaded** graph, so unlike MAT and CAN-1 this gate is not weight-free — it runs
/// in the package's live gate lane (post-`load()`), the same place STR-4..7 run. The bench sibling
/// is `MLXEngineTestKit.InferenceModeRun` (**INF-3 idempotence**, the `[INF]` line): two successive
/// `run()` calls on one loaded instance must produce identical output. INF-3 is the check that
/// catches the failure *class* rather than the known mechanism — it fails for BatchNorm statistic
/// drift, for live `Dropout`, and for anything training-mode-sensitive we have not met yet.
///
/// ## Use
///
/// A package reaches its own models — nobody else can — so it conforms to
/// ``InferenceModeInspectable`` in one line, using the MLXNN walk from the
/// `MLXServeConformanceNN` product:
///
/// ```swift
/// import MLXServeConformance
/// import MLXServeConformanceNN
///
/// extension MyPackage: InferenceModeInspectable {
///     // Isolated like the rest of the package — the requirement is `async` so this can reach
///     // the stored graph. Multi-component packages pass the labelled overload:
///     // `flags(of: ["gpt": gpt, "campplus": campplus])`.
///     public func inferenceModeFlags() -> [InferenceModeConformance.ModuleTrainingFlag] {
///         InferenceModeConformance.flags(of: pipeline?.model)
///     }
/// }
/// ```
///
/// then, in its gate lane after `load()`:
///
/// ```swift
/// try await pkg.load()
/// let report = await InferenceModeConformance.check(pkg, posture: .moduleGraph)
/// XCTAssertTrue(report.passed, report.summary)
/// ```
///
/// A functional port declares the exemption and needs neither MLXNN nor a loaded model:
///
/// ```swift
/// let report = InferenceModeConformance.check(
///     flags: [],
///     posture: .notApplicable(reason: "BatchNorm is functional — DDColorOps.batchNorm reads "
///                                   + "running_mean/running_var from the weight dict; no "
///                                   + "MLXNN.Module and no `training` branch anywhere"))
/// ```
public enum InferenceModeConformance {

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

    // MARK: - The observation

    /// One module observed in a package's loaded graph: where it sits, what it is, and whether it
    /// is still in training mode. Produced by `InferenceModeConformance.flags(of:)` in the
    /// `MLXServeConformanceNN` product (which owns the MLXNN dependency), or by hand for a package
    /// whose graph is not an `MLXNN.Module` tree.
    public struct ModuleTrainingFlag: Sendable, Equatable {
        /// Dotted path from the graph root, e.g. `decoder.gdt_convs_2.bn_in`. Components loaded
        /// separately are prefixed with their role (`campplus.…`).
        public let path: String
        /// The module's Swift type name, e.g. `BatchNorm`. Used to rank the failure note — it does
        /// NOT relax the check.
        public let type: String
        public let training: Bool

        public init(path: String, type: String, training: Bool) {
            self.path = path
            self.type = type
            self.training = training
        }
    }

    /// Type-name fragments whose behavior forks on `Module.training`, matched as substrings so
    /// both `MLXNN.BatchNorm` and a port's own `FusedBatchNorm` subclass are recognized.
    ///
    /// This set exists to make a failure *actionable* — "2 of these are running-statistic layers"
    /// reads very differently from a bare count. It is deliberately NOT an allowlist: INF-1 fails
    /// on any module in training mode, sensitive or not. Layers that carry no running statistics
    /// and never read `training` (`LayerNorm`, `RMSNorm`, `GroupNorm`) are correctly absent.
    public static let trainingSensitiveTypes: Set<String> = [
        "BatchNorm",     // running_mean/running_var — overwritten AND read-around in training mode
        "InstanceNorm",  // MLXNN's carries no running stats, but ports subclass the name
        "Dropout",       // covers Dropout / Dropout2d / Dropout3d — identity ONLY at p == 0
    ]

    /// Is this type name training-mode-sensitive?
    public static func isTrainingSensitive(type: String) -> Bool {
        trainingSensitiveTypes.contains { type.contains($0) }
    }

    // MARK: - The declaration

    /// The package's declared inference-mode posture. As with the CAN gate's `CheckpointPosture`,
    /// the declaration made in the package's own conformance suite IS the document of record.
    public enum Posture: Sendable {
        /// The package holds an `MLXNN.Module` graph. INF-1 asserts every module in it is in
        /// inference mode; an empty graph fails rather than passing vacuously.
        case moduleGraph
        /// No module graph to put in inference mode — a functional port (running statistics read
        /// directly from the weight dict, no `training` branch) or a non-MLX package. State why;
        /// the exemption fails if the walk observed modules anyway.
        case notApplicable(reason: String)
    }

    // MARK: - INF-1 / INF-2

    /// Run the gate over an already-observed set of flags.
    ///
    /// - Parameters:
    ///   - flags: every module in the package's **loaded** graph. Empty is meaningful: under
    ///     `.moduleGraph` it is a failure (nothing was inspected — typically the check ran before
    ///     `load()`, or the inspectable seam reads a property that is still `nil`); under
    ///     `.notApplicable` it is the expected shape.
    ///   - posture: the package's declaration.
    public static func check(flags: [ModuleTrainingFlag], posture: Posture) -> Report {
        var checks: [Check] = []
        let training = flags.filter(\.training)
        let sensitive = training.filter { isTrainingSensitive(type: $0.type) }

        switch posture {
        case .moduleGraph:
            // INF-1 — the assertion.
            if flags.isEmpty {
                checks.append(Check(name: "INF-1 inference mode", passed: false,
                                    note: "no modules observed — .moduleGraph was declared but the "
                                        + "walk returned an empty graph. Run this AFTER load(), and "
                                        + "check the inspectable seam reaches the loaded model "
                                        + "(a still-nil property returns no flags and would pass "
                                        + "vacuously if this were not a failure)"))
            } else if training.isEmpty {
                checks.append(Check(name: "INF-1 inference mode", passed: true,
                                    note: "\(flags.count) module(s) inspected, all report "
                                        + "training == false"))
            } else {
                checks.append(Check(name: "INF-1 inference mode", passed: false,
                                    note: failureNote(total: flags.count, training: training,
                                                      sensitive: sensitive)))
            }

            // INF-2 — under .moduleGraph the declaration is self-evidently satisfied by INF-1
            // having something to inspect; it stays in the report so the two postures produce
            // comparably shaped output.
            checks.append(Check(name: "INF-2 posture declaration", passed: true,
                                note: "module-graph posture — \(flags.count) module(s) in scope"))

        case .notApplicable(let reason):
            // INF-1 has nothing to assert; say so rather than emitting a green tick for an
            // inspection that never happened.
            checks.append(Check(name: "INF-1 inference mode", passed: true,
                                note: "not asserted — exempt by INF-2 (no module graph)"))

            if reason.isEmpty {
                checks.append(Check(name: "INF-2 posture declaration", passed: false,
                                    note: "the not-applicable exemption requires a stated reason "
                                        + "(name the mechanism, e.g. \"BatchNorm is functional — "
                                        + "reads running_mean/running_var from the weight dict\")"))
            } else if !flags.isEmpty {
                checks.append(Check(name: "INF-2 posture declaration", passed: false,
                                    note: "exemption claimed (\(reason)) but the walk observed "
                                        + "\(flags.count) module(s)"
                                        + (training.isEmpty
                                            ? " — declare .moduleGraph instead"
                                            : ", \(training.count) of them in training mode "
                                              + "— declare .moduleGraph and fix the load path: "
                                              + pathList(training))))
            } else {
                checks.append(Check(name: "INF-2 posture declaration", passed: true,
                                    note: "exempt — no module graph: \(reason)"))
            }
        }
        return Report(checks: checks)
    }

    /// Convenience over ``InferenceModeInspectable``. Call after `load()`.
    public static func check(_ inspectable: any InferenceModeInspectable,
                             posture: Posture = .moduleGraph) async -> Report {
        check(flags: await inspectable.inferenceModeFlags(), posture: posture)
    }

    // MARK: - Notes

    private static func failureNote(total: Int,
                                    training: [ModuleTrainingFlag],
                                    sensitive: [ModuleTrainingFlag]) -> String {
        var note = "\(training.count)/\(total) module(s) still in TRAINING mode"
        if sensitive.isEmpty {
            // Always name them. "None are sensitive by type" is a severity statement, not a
            // reason to withhold the paths — the reader still has to find the subtree.
            note += " — none are training-mode-sensitive by type, but their presence proves "
                + "train(false) never ran over this subtree: " + pathList(training)
        } else {
            note += ", \(sensitive.count) of them training-mode-SENSITIVE: "
                + pathList(sensitive)
            note += " — these read/overwrite running statistics or drop activations at inference"
            let inert = training.filter { !isTrainingSensitive(type: $0.type) }
            if !inert.isEmpty {
                note += ". Also in training mode: " + pathList(inert)
            }
        }
        note += ". Fix: call `model.train(false)` at the single construction choke point every "
            + "load path funnels through (not per call site — a later-added constructor silently "
            + "misses a per-site fix)"
        return note
    }

    /// Up to `limit` paths with their types, then an elision count — a 900-module graph must not
    /// produce a 900-entry failure string.
    private static func pathList(_ flags: [ModuleTrainingFlag], limit: Int = 8) -> String {
        let shown = flags.prefix(limit).map { "\($0.path) (\($0.type))" }.joined(separator: ", ")
        let rest = flags.count - min(limit, flags.count)
        return rest > 0 ? "\(shown), +\(rest) more" : shown
    }
}

/// Test-facing introspection seam: a package exposes its **loaded** model graph's training flags so
/// the INF gate can assert inference mode on the real thing.
///
/// The package writes this — it is the only thing that knows where its models live (and heavier
/// packages hold several: a DiT plus a text encoder plus a VAE). Conformance is one line via
/// `InferenceModeConformance.flags(of:)` from the `MLXServeConformanceNN` product; a package with
/// no `MLXNN.Module` graph returns `[]` and declares `.notApplicable`.
///
/// Return `[]` before `load()`. INF-1 treats an empty graph under `.moduleGraph` as a failure
/// precisely so "I ran the gate before loading" cannot read as a pass.
///
/// The requirement is `async` so that an `@InferenceActor`-isolated package — which every
/// conformant package is (C13) — can witness it with an isolated method and reach its own stored
/// model. A synchronous requirement would force a `nonisolated` witness that cannot touch the
/// isolated properties holding the graph.
public protocol InferenceModeInspectable: AnyObject, Sendable {
    func inferenceModeFlags() async -> [InferenceModeConformance.ModuleTrainingFlag]
}
