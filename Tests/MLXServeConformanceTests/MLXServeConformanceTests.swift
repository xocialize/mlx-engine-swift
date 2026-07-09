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

// MARK: - Bundled-weights vocabulary (contract 1.17)

/// Bundled-only shape (Real-ESRGAN-like): checkpoints vendored in the resource bundle, no
/// network sources. `url` stands in for the resolved bundle lookup.
private struct BundledConfig: PackageConfiguration, ModelStorable, BundledWeightSourcing {
    var modelsRootDirectory: URL?
    var checkpointURL: URL?
    var bundledWeightSources: [BundledWeightSource] {
        [BundledWeightSource(role: "checkpoint", url: checkpointURL)]
    }
}

final class BundledMaterializationConformanceTests: XCTestCase {

    private func existingFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mat-bundled-\(UUID().uuidString).bin")
        try Data("w".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A bundled-only package with a resolvable checkpoint is a first-class MAT citizen: the
    /// full fresh report passes (MAT-4 verifies the source PRESENT, not required-missing).
    func testBundledOnlyConfigPassesFreshChecks() throws {
        let config = BundledConfig(checkpointURL: try existingFile())
        let report = MaterializationConformance.check(freshConfiguration: config)
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.checks.count, 4)   // MAT-1…4
    }

    /// A stripped/misdeclared bundle resource (nil or dangling URL) fails MAT-4 in the package's
    /// own suite — not at the user's first inference.
    func testUnresolvedBundledSourceFailsMAT4() {
        for url in [nil, URL(fileURLWithPath: "/nonexistent/checkpoint.bin")] {
            let report = MaterializationConformance.check(
                freshConfiguration: BundledConfig(checkpointURL: url))
            XCTAssertFalse(report.passed)
            XCTAssertFalse(report.checks.first { $0.name.hasPrefix("MAT-4") }!.passed,
                           report.summary)
        }
    }

    /// Hybrid (network + bundled): each subset is checked by its own rule, and the role
    /// namespace is shared — a duplicate role across the vocabularies fails MAT-3.
    func testHybridConfigAndSharedRoleNamespace() throws {
        struct Hybrid: PackageConfiguration, ModelStorable, WeightSourcing, BundledWeightSourcing {
            var modelsRootDirectory: URL?
            var checkpointURL: URL?
            var networkRole = "text-encoder"
            var weightSources: [WeightSource] { [WeightSource(role: networkRole, repo: "org/enc")] }
            func missingWeightSources(storeRoot: URL?) -> [WeightSource] { weightSources }
            var bundledWeightSources: [BundledWeightSource] {
                [BundledWeightSource(role: "checkpoint", url: checkpointURL)]
            }
        }
        let url = try existingFile()
        let good = MaterializationConformance.check(
            freshConfiguration: Hybrid(checkpointURL: url))
        XCTAssertTrue(good.passed, good.summary)

        let clashing = MaterializationConformance.check(
            freshConfiguration: Hybrid(checkpointURL: url, networkRole: "checkpoint"))
        XCTAssertFalse(clashing.checks.first { $0.name.hasPrefix("MAT-3") }!.passed)
    }

    /// A bundled-only satisfied configuration is acceptable for MAT-5 — nothing to satisfy from
    /// the network, bundled set must still resolve.
    func testBundledOnlySatisfiedConfigPassesMAT5() throws {
        let config = BundledConfig(checkpointURL: try existingFile())
        let report = MaterializationConformance.check(freshConfiguration: config,
                                                      satisfiedConfiguration: config)
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.checks.count, 5)
    }
}
