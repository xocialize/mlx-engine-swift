import XCTest
import MLX
import MLXNN
import MLXServeConformance
import MLXServeConformanceNN

// The INF walk proven against real `MLXNN.Module` graphs. No weights and no kernels: `train(_:)`
// and `namedModules()` touch module structure and flags, never array contents, so nothing evals.

// MARK: - A miniature port-shaped graph

/// Stands in for the shape that actually failed — a conv block whose BatchNorm is nested two
/// levels down, so a fix applied only at the root would still have to be recursive to reach it.
private final class ConvBlock: Module {
    @ModuleInfo(key: "conv") var conv: Conv2d
    @ModuleInfo(key: "bn") var bn: BatchNorm

    init(_ channels: Int) {
        self._conv.wrappedValue = Conv2d(inputChannels: channels, outputChannels: channels,
                                         kernelSize: 3)
        self._bn.wrappedValue = BatchNorm(featureCount: channels)
        super.init()
    }
}

private final class TinyNet: Module {
    @ModuleInfo(key: "stem") var stem: ConvBlock
    @ModuleInfo(key: "head") var head: Linear
    @ModuleInfo(key: "norm") var norm: LayerNorm
    @ModuleInfo(key: "drop") var drop: Dropout

    override init() {
        self._stem.wrappedValue = ConvBlock(8)
        self._head.wrappedValue = Linear(8, 4)
        self._norm.wrappedValue = LayerNorm(dimensions: 8)
        self._drop.wrappedValue = Dropout(p: 0.1)
        super.init()
    }
}

final class InferenceModeWalkTests: XCTestCase {

    /// Building the graph is where MLX first touches the GPU: `Linear`/`Conv2d` seed their weights
    /// through `MLXRandom`, which asks for the default GPU stream. In a process that can't load
    /// MLX's bundled metallib that call hits mlx-swift's DEFAULT error handler and aborts the
    /// whole xctest process — every later suite included. Probe it once, under `withError`, so
    /// such a runner skips this class instead of taking the run down with it.
    ///
    /// The metallib is missing exactly when the package was built by the deprecated `native`
    /// build system, which does not compile Cmlx's `.metal` sources into a colocated resource
    /// bundle. `swift test` (default `swiftbuild`) and Xcode both produce it, so this suite runs
    /// for real in normal development and in CI.
    override func setUpWithError() throws {
        guard (try? MLX.withError { _ = Linear(2, 2) }) != nil else {
            throw XCTSkip("MLX Metal device unavailable in this test runner process")
        }
    }

    // MARK: - The walk

    func testWalkVisitsRootAndEveryDescendant() {
        let flags = InferenceModeConformance.flags(of: TinyNet())
        let paths = Set(flags.map(\.path))
        XCTAssertTrue(paths.contains("<root>"), "root must be reported — \(paths)")
        XCTAssertTrue(paths.contains("stem"), "\(paths)")
        XCTAssertTrue(paths.contains("stem.bn"), "nested modules must be reached — \(paths)")
        XCTAssertTrue(paths.contains("stem.conv"), "\(paths)")
        XCTAssertTrue(paths.contains("head"), "\(paths)")
        XCTAssertTrue(paths.contains("drop"), "\(paths)")
    }

    func testWalkCapturesTypeNames() {
        let flags = InferenceModeConformance.flags(of: TinyNet())
        let types = Dictionary(uniqueKeysWithValues: flags.map { ($0.path, $0.type) })
        XCTAssertEqual(types["stem.bn"], "BatchNorm")
        XCTAssertEqual(types["norm"], "LayerNorm")
        XCTAssertEqual(types["drop"], "Dropout")
    }

    func testNilModelYieldsNoFlags() {
        XCTAssertTrue(InferenceModeConformance.flags(of: nil as Module?).isEmpty)
    }

    // MARK: - The default that motivated C14

    /// `MLXNN.Module.training` defaults to `true`, so a freshly built graph fails INF-1 — this is
    /// the state every port is in until something calls `train(false)`.
    func testFreshGraphIsInTrainingModeAndFailsINF1() {
        let report = InferenceModeConformance.check(flags: .init(TinyNet()), posture: .moduleGraph)
        XCTAssertFalse(report.passed, "a fresh MLXNN graph must fail INF-1:\n\(report.summary)")
        XCTAssertTrue(report.summary.contains("stem.bn (BatchNorm)"), report.summary)
        XCTAssertTrue(report.summary.contains("training-mode-SENSITIVE"), report.summary)
    }

    func testTrainFalseMakesTheGraphPassINF1() {
        let net = TinyNet()
        net.train(false)
        let report = InferenceModeConformance.check(flags: .init(net), posture: .moduleGraph)
        XCTAssertTrue(report.passed, report.summary)
    }

    /// `train(_:)` is recursive, so the fix at the root reaches a BatchNorm two levels down —
    /// which is why the choke-point fix is sufficient and per-call-site fixes are not necessary
    /// (only fragile).
    func testTrainFalseIsRecursive() {
        let net = TinyNet()
        net.train(false)
        let flags = InferenceModeConformance.flags(of: net)
        XCTAssertFalse(flags.isEmpty)
        XCTAssertTrue(flags.allSatisfy { !$0.training },
                      "still training: \(flags.filter(\.training).map(\.path))")
    }

    // Note: the "submodule swapped in after train(false)" regression cannot be built here —
    // MLXNN traps direct property mutation on a constructed module (`Module.swift`: "please use
    // Model.update(modules:) rather than mutating the Module property directly"), so a single
    // graph cannot silently grow an untreated subtree. The reachable form of that regression is
    // a package that treats one COMPONENT and constructs the next afterwards, covered below.

    // MARK: - Multi-component packages

    func testComponentsAreRolePrefixedAndSorted() {
        let gpt = TinyNet()
        let campplus = TinyNet()
        gpt.train(false)
        campplus.train(false)
        let flags = InferenceModeConformance.flags(of: ["gpt": gpt, "campplus": campplus])
        XCTAssertTrue(flags.contains { $0.path == "campplus.stem.bn" }, "\(flags.map(\.path))")
        XCTAssertTrue(flags.contains { $0.path == "gpt.stem.bn" }, "\(flags.map(\.path))")
        // Sorted key order keeps a failure note stable run to run.
        let firstGPT = flags.firstIndex { $0.path.hasPrefix("gpt") } ?? .max
        let firstCamp = flags.firstIndex { $0.path.hasPrefix("campplus") } ?? .max
        XCTAssertLessThan(firstCamp, firstGPT)
    }

    /// One component left in training mode fails the whole package — the IndexTTS2/MuseTalk shape,
    /// where `train(false)` is applied per component and a newly added one can be missed.
    func testOneUntreatedComponentFailsTheReport() {
        let treated = TinyNet()
        treated.train(false)
        let report = InferenceModeConformance.check(
            flags: .init(["gpt": treated, "campplus": TinyNet()]), posture: .moduleGraph)
        XCTAssertFalse(report.passed, report.summary)
        XCTAssertTrue(report.summary.contains("campplus.stem.bn (BatchNorm)"), report.summary)
        XCTAssertFalse(report.summary.contains("gpt.stem.bn"), report.summary)
    }
}

// Small readability shim so the tests above read as `check(flags: .init(net), …)`.
private extension Array where Element == InferenceModeConformance.ModuleTrainingFlag {
    init(_ model: Module?) { self = InferenceModeConformance.flags(of: model) }
    init(_ components: [String: Module?]) { self = InferenceModeConformance.flags(of: components) }
}
