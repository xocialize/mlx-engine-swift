import XCTest
@testable import MLXServeConformance
import MLXToolKit

// The INF gate's declarative half (INF-1..2), proven against hand-built flag sets — the same
// harness-proof role the MAT mocks play for MaterializationConformance. MLX-free by construction:
// these flags are data, so the gate logic is testable without an MLXNN graph. The walk that
// produces them from a real `Module` tree is proven in MLXServeConformanceNNTests.

private func flag(_ path: String, _ type: String, training: Bool)
    -> InferenceModeConformance.ModuleTrainingFlag {
    .init(path: path, type: type, training: training)
}

/// A small graph in the correct posture: everything already in inference mode.
private let cleanGraph = [
    flag("<root>", "BiRefNet", training: false),
    flag("decoder", "BiRefNetDecoder", training: false),
    flag("decoder.bn_in", "BatchNorm", training: false),
    flag("decoder.conv", "Conv2d", training: false),
]

final class InferenceModeConformanceTests: XCTestCase {

    // MARK: - INF-1

    func testCleanModuleGraphPasses() {
        let report = InferenceModeConformance.check(flags: cleanGraph, posture: .moduleGraph)
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertTrue(report.summary.contains("4 module(s) inspected"), report.summary)
    }

    /// The motivating shape: a `train(false)` that never ran, so the whole tree is in training
    /// mode. The note must name the running-statistic layer, not just count modules.
    func testTrainingModeGraphFailsAndNamesTheSensitiveLayer() {
        let dirty = cleanGraph.map {
            flag($0.path, $0.type, training: true)
        }
        let report = InferenceModeConformance.check(flags: dirty, posture: .moduleGraph)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("4/4 module(s) still in TRAINING mode"),
                      report.summary)
        XCTAssertTrue(report.summary.contains("decoder.bn_in (BatchNorm)"), report.summary)
        XCTAssertTrue(report.summary.contains("training-mode-SENSITIVE"), report.summary)
        XCTAssertTrue(report.summary.contains("choke point"), report.summary)
    }

    /// A single inert module left behind still fails: `train(_:)` is recursive, so this proves the
    /// call never covered that subtree even though a `Linear` carries no numerical hazard.
    func testInertModuleInTrainingModeStillFails() {
        var flags = cleanGraph
        flags.append(flag("decoder.head", "Linear", training: true))
        let report = InferenceModeConformance.check(flags: flags, posture: .moduleGraph)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("none are training-mode-sensitive by type"),
                      report.summary)
        XCTAssertTrue(report.summary.contains("decoder.head (Linear)"), report.summary)
    }

    /// The vacuous pass this gate exists to prevent: running before `load()` inspects nothing.
    func testEmptyGraphUnderModuleGraphPostureFails() {
        let report = InferenceModeConformance.check(flags: [], posture: .moduleGraph)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("no modules observed"), report.summary)
        XCTAssertTrue(report.summary.contains("AFTER load()"), report.summary)
    }

    /// A large graph must not produce a failure string with one entry per module.
    func testFailureNoteElidesLongPathLists() {
        let many = (0 ..< 400).map { flag("block\($0).bn", "BatchNorm", training: true) }
        let report = InferenceModeConformance.check(flags: many, posture: .moduleGraph)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("+392 more"), report.summary)
        XCTAssertLessThan(report.summary.count, 1_200, "failure note should stay readable")
    }

    // MARK: - INF-2

    func testNotApplicableWithReasonPasses() {
        let report = InferenceModeConformance.check(
            flags: [],
            posture: .notApplicable(reason: "functional BatchNorm — DDColorOps.batchNorm reads "
                                          + "running_mean/running_var from the weight dict"))
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertTrue(report.summary.contains("not asserted"), report.summary)
        XCTAssertTrue(report.summary.contains("exempt — no module graph"), report.summary)
    }

    func testNotApplicableWithoutReasonFails() {
        let report = InferenceModeConformance.check(flags: [], posture: .notApplicable(reason: ""))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("requires a stated reason"), report.summary)
    }

    /// The exemption is falsifiable — that is the whole point of taking flags even when the
    /// package claims it has no graph.
    func testNotApplicableIsRefutedByAnObservedGraph() {
        let report = InferenceModeConformance.check(
            flags: cleanGraph, posture: .notApplicable(reason: "no modules here, honest"))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("observed 4 module(s)"), report.summary)
        XCTAssertTrue(report.summary.contains("declare .moduleGraph instead"), report.summary)
    }

    func testNotApplicableRefutedByTrainingModeGraphNamesThem() {
        let dirty = [flag("net.bn1", "BatchNorm", training: true)]
        let report = InferenceModeConformance.check(
            flags: dirty, posture: .notApplicable(reason: "claimed functional"))
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.summary.contains("net.bn1 (BatchNorm)"), report.summary)
        XCTAssertTrue(report.summary.contains("fix the load path"), report.summary)
    }

    // MARK: - Sensitivity classification

    func testTrainingSensitiveTypeRecognition() {
        for type in ["BatchNorm", "MLXNN.BatchNorm", "FusedBatchNorm2d",
                     "Dropout", "Dropout2d", "InstanceNorm1d"] {
            XCTAssertTrue(InferenceModeConformance.isTrainingSensitive(type: type), type)
        }
        // Norms that carry no running statistics and never read `training`.
        for type in ["LayerNorm", "RMSNorm", "GroupNorm", "Linear", "Conv2d"] {
            XCTAssertFalse(InferenceModeConformance.isTrainingSensitive(type: type), type)
        }
    }

    // MARK: - The inspectable seam

    /// The seam must be witnessable by an `@InferenceActor`-isolated type, because every
    /// conformant package is one (C13). This compiling at all is the assertion: a synchronous
    /// requirement would force a `nonisolated` witness, which could not reach the isolated stored
    /// property holding the model graph.
    func testIsolatedPackageCanWitnessTheSeam() async {
        @InferenceActor
        final class IsolatedStub: InferenceModeInspectable {
            private var loaded: [InferenceModeConformance.ModuleTrainingFlag] = []
            nonisolated init() {}
            func load(_ flags: [InferenceModeConformance.ModuleTrainingFlag]) { loaded = flags }
            // Isolated witness reaching isolated state — the shape a real package needs.
            func inferenceModeFlags() -> [InferenceModeConformance.ModuleTrainingFlag] { loaded }
        }

        let pkg = IsolatedStub()
        // Before load(): an empty graph must FAIL rather than pass vacuously.
        var report = await InferenceModeConformance.check(pkg)
        XCTAssertFalse(report.passed, report.summary)

        await pkg.load(cleanGraph)
        report = await InferenceModeConformance.check(pkg)
        XCTAssertTrue(report.passed, report.summary)
    }
}
