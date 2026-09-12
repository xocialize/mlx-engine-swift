import XCTest
@testable import MLXServeConformance
import MLXToolKit

// The FIT gate (FootprintConformance, contract 1.41.0) proven against coherent, incoherent,
// malformed, and scalar-only declarations — the same harness-proof role the MAT mocks play.
// Numbers: reserve 4 000 B = base 1 000 + 5 B/unit × 600 ceiling.

private func manifest(peak: UInt64, scaling: ActivationScaling?) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/fit", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1, peakActivationBytes: peak,
                                        activationScaling: scaling)],
            requiredBackends: [.metalGPU]),
        surfaces: [STTContract.descriptor(name: "fit", summary: "m")])
}

private let coherent = ActivationScaling(axis: .audioSeconds, baseBytes: 1_000, bytesPerUnit: 5,
                                         measuredCeiling: 600)

private struct EnforceableConfig: PackageConfiguration, QuantConfigured, FootprintConfigured,
    WorkloadDeclaring
{
    var quant: Quant { .int4 }
    var laneScaling: ActivationScaling? = nil
    var laneReserve: UInt64? = nil
    var residentBytesHint: UInt64? { nil }
    var peakActivationBytesHint: UInt64? { laneReserve }
    var activationScalingHint: ActivationScaling? { laneScaling }
    func workloadUnits(for request: any CapabilityRequest) -> Double? { nil }
}

private struct UnenforceableConfig: PackageConfiguration, QuantConfigured {
    var quant: Quant { .int4 }
}

final class FootprintConformanceTests: XCTestCase {

    private func check(_ report: FootprintConformance.Report, _ prefix: String) -> Bool? {
        report.checks.first { $0.name.hasPrefix(prefix) }?.passed
    }

    func testScalarOnlyManifestPassesVacuously() {
        let report = FootprintConformance.check(manifest: manifest(peak: 4_000, scaling: nil),
                                                configuration: UnenforceableConfig())
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.checks.count, 1)
        XCTAssertEqual(check(report, "FIT-0"), true)
    }

    func testCoherentDeclarationPasses() {
        let report = FootprintConformance.check(manifest: manifest(peak: 4_000, scaling: coherent),
                                                configuration: EnforceableConfig())
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(check(report, "FIT-1"), true)
        XCTAssertEqual(check(report, "FIT-2"), true)
        XCTAssertEqual(check(report, "FIT-3"), true)
    }

    /// The failure the gate exists for: a reserve measured at a shorter workload than the
    /// declared ceiling — every admitted job between them runs beyond what admission reserved.
    func testReserveBelowTheModelAtTheCeilingFailsFIT2() {
        let report = FootprintConformance.check(manifest: manifest(peak: 3_999, scaling: coherent))
        XCTAssertFalse(report.passed)
        XCTAssertEqual(check(report, "FIT-1"), true)
        XCTAssertEqual(check(report, "FIT-2"), false)
    }

    func testMalformedDeclarationFailsFIT1AndSkipsFIT2() {
        let malformed = ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: 1,
                                          measuredCeiling: 0)
        let report = FootprintConformance.check(manifest: manifest(peak: 4_000, scaling: malformed))
        XCTAssertFalse(report.passed)
        XCTAssertEqual(check(report, "FIT-1"), false)
        XCTAssertNil(check(report, "FIT-2"))
    }

    /// Declared but unenforceable: the configuration never maps a request to units, so the
    /// ceiling can never refuse anything.
    func testScalingWithoutWorkloadDeclaringFailsFIT3() {
        let report = FootprintConformance.check(manifest: manifest(peak: 4_000, scaling: coherent),
                                                configuration: UnenforceableConfig())
        XCTAssertFalse(report.passed)
        XCTAssertEqual(check(report, "FIT-3"), false)
    }

    /// A lane that raises its cap re-declares BOTH, and the rule holds for that pair.
    func testLanePairIsCheckedOnItsOwn() {
        let lane = ActivationScaling(axis: .audioSeconds, baseBytes: 1_000, bytesPerUnit: 5,
                                     measuredCeiling: 1_000)                  // 6 000 at the ceiling
        let good = FootprintConformance.check(
            manifest: manifest(peak: 4_000, scaling: coherent),
            configuration: EnforceableConfig(laneScaling: lane, laneReserve: 6_000))
        XCTAssertTrue(good.passed, good.summary)
        XCTAssertTrue(good.checks.contains { $0.name == "FIT-2 coherent (lane int4)" })

        let bad = FootprintConformance.check(
            manifest: manifest(peak: 4_000, scaling: coherent),
            configuration: EnforceableConfig(laneScaling: lane, laneReserve: 4_000))
        XCTAssertFalse(bad.passed)
        XCTAssertEqual(bad.checks.first { $0.name == "FIT-2 coherent (lane int4)" }?.passed, false)
        // The quant-keyed pair is still coherent on its own; only the lane pair failed.
        XCTAssertEqual(bad.checks.first { $0.name == "FIT-2 coherent (int4)" }?.passed, true)
    }
}
