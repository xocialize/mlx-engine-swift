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

/// Lane hints without `WorkloadDeclaring`: the lane's scalar has to stand alone.
private struct UnenforceableLaneConfig: PackageConfiguration, QuantConfigured, FootprintConfigured {
    var quant: Quant { .int4 }
    var laneScaling: ActivationScaling? = nil
    var laneReserve: UInt64? = nil
    var residentBytesHint: UInt64? { nil }
    var peakActivationBytesHint: UInt64? { laneReserve }
    var activationScalingHint: ActivationScaling? { laneScaling }
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
    func testReserveBelowTheModelAtTheCeilingFailsFIT2WhenNothingMapsARequest() {
        // 1.42.0: the scalar must stand alone only when no configuration can map a request to
        // the line — a manifest checked alone, or a configuration without WorkloadDeclaring.
        let alone = FootprintConformance.check(manifest: manifest(peak: 3_000, scaling: coherent))
        XCTAssertFalse(alone.passed, alone.summary)
        XCTAssertEqual(check(alone, "FIT-2"), false)
        let unmapped = FootprintConformance.check(manifest: manifest(peak: 3_000, scaling: coherent),
                                                  configuration: UnenforceableConfig())
        XCTAssertFalse(unmapped.passed, unmapped.summary)
        XCTAssertEqual(check(unmapped, "FIT-2"), false)
        XCTAssertEqual(check(unmapped, "FIT-3"), false)
    }

    func testReserveBelowTheModelAtTheCeilingPassesFIT2WithPerRunSizing() {
        // The scalar is the representative case; a mapping configuration reserves the projection
        // per run (1.42.0), so the pair is coherent — with the note saying so.
        let report = FootprintConformance.check(manifest: manifest(peak: 3_000, scaling: coherent),
                                                configuration: EnforceableConfig())
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(check(report, "FIT-2"), true)
        let note = report.checks.first { $0.name.hasPrefix("FIT-2") }?.note ?? ""
        XCTAssertTrue(note.contains("per run"), note)
        XCTAssertTrue(note.contains("representative case"), note)
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

        // A lane whose reserve sits below its model at the ceiling: coherent PER RUN for a
        // configuration that maps workloads (1.42.0 — the lane row passes with the note) …
        let perRun = FootprintConformance.check(
            manifest: manifest(peak: 4_000, scaling: coherent),
            configuration: EnforceableConfig(laneScaling: lane, laneReserve: 4_000))
        XCTAssertTrue(perRun.passed, perRun.summary)
        let laneRow = perRun.checks.first { $0.name == "FIT-2 coherent (lane int4)" }
        XCTAssertEqual(laneRow?.passed, true)
        XCTAssertTrue(laneRow?.note.contains("per run") == true, laneRow?.note ?? "")

        // … and a finding for one that cannot: the lane pair fails on its own while the
        // quant-keyed pair stays coherent (and FIT-3 names the missing mapping).
        let bad = FootprintConformance.check(
            manifest: manifest(peak: 4_000, scaling: coherent),
            configuration: UnenforceableLaneConfig(laneScaling: lane, laneReserve: 4_000))
        XCTAssertFalse(bad.passed)
        XCTAssertEqual(bad.checks.first { $0.name == "FIT-2 coherent (lane int4)" }?.passed, false)
        XCTAssertEqual(bad.checks.first { $0.name == "FIT-2 coherent (int4)" }?.passed, true)
        XCTAssertEqual(check(bad, "FIT-3"), false)
    }
}
