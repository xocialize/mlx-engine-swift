import XCTest
@testable import MLXServeConformance
import MLXToolKit

final class MLXServeConformanceTests: XCTestCase {
    // MLXServeConformance's C0–C13 harness is still scaffolding; this asserts the target builds
    // and tracks the current contract. The MAT gate below is the first executable check.
    func testHarnessTracksCurrentContract() {
        XCTAssertEqual(MLXServeConformance.contractVersion, ContractVersion.current)
    }
}

// MARK: - MAT gate (MaterializationConformance)

/// Mock of a well-behaved multi-source configuration (an LTX-shaped example: components +
/// text-encoder + quant transformer).
private struct GoodConfig: PackageConfiguration, ModelStorable, WeightSourcing {
    var modelsRootDirectory: URL?
    var componentsDirectory: URL?
    var encoderDirectory: URL?

    var weightSources: [WeightSource] {
        [WeightSource(role: "components", repo: "org/model", matching: ["a.safetensors"]),
         WeightSource(role: "text-encoder", repo: "org/encoder"),
         WeightSource(role: "transformer-int8", repo: "org/model-q8")]
    }

    func missingWeightSources(storeRoot: URL?) -> [WeightSource] {
        weightSources.filter { source in
            switch source.role {
            case "components", "transformer-int8":
                if let dir = componentsDirectory,
                   FileManager.default.fileExists(atPath: dir.path) { return false }
            case "text-encoder":
                if let dir = encoderDirectory,
                   FileManager.default.fileExists(atPath: dir.path) { return false }
            default: break
            }
            guard let storeRoot else { return true }
            let dir = source.repo.split(separator: "/").reduce(storeRoot) {
                $0.appending(path: String($1))
            }
            return !FileManager.default.fileExists(atPath: dir.path)
        }
    }
}

/// Configuration that declares nothing (legacy shape) — must fail MAT-2.
private struct UndeclaredConfig: PackageConfiguration, ModelStorable {
    var modelsRootDirectory: URL?
}

/// Declares sources but claims some already satisfied on a fresh machine — must fail MAT-4.
private struct LyingConfig: PackageConfiguration, ModelStorable, WeightSourcing {
    var modelsRootDirectory: URL?
    var weightSources: [WeightSource] { [WeightSource(role: "weights", repo: "org/model")] }
    func missingWeightSources(storeRoot: URL?) -> [WeightSource] { [] }   // "nothing missing" fresh
}

final class MaterializationConformanceTests: XCTestCase {

    func testGoodConfigPassesFreshChecks() {
        let report = MaterializationConformance.check(freshConfiguration: GoodConfig())
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.checks.count, 4)   // MAT-1…4 (no satisfied config given)
    }

    func testSatisfiedConfigPassesMAT5() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "mat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let satisfied = GoodConfig(componentsDirectory: tmp, encoderDirectory: tmp)
        let report = MaterializationConformance.check(freshConfiguration: GoodConfig(),
                                                      satisfiedConfiguration: satisfied)
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.checks.count, 5)
    }

    func testUndeclaredConfigFailsMAT2() {
        let report = MaterializationConformance.check(freshConfiguration: UndeclaredConfig())
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.checks.first { $0.name.hasPrefix("MAT-2") }!.passed)
    }

    func testLyingConfigFailsMAT4() {
        let report = MaterializationConformance.check(freshConfiguration: LyingConfig())
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.checks.first { $0.name.hasPrefix("MAT-4") }!.passed)
    }

    func testNotStorableFailsMAT1() {
        struct Bare: PackageConfiguration, WeightSourcing {
            var weightSources: [WeightSource] { [WeightSource(role: "w", repo: "o/r")] }
            func missingWeightSources(storeRoot: URL?) -> [WeightSource] { weightSources }
        }
        let report = MaterializationConformance.check(freshConfiguration: Bare())
        XCTAssertFalse(report.checks.first { $0.name.hasPrefix("MAT-1") }!.passed)
    }
}
