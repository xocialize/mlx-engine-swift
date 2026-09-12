import XCTest
@testable import MLXToolKit

/// 1.41.0 additive-compatibility + arithmetic gates for `ActivationScaling` (AB-A-0069,
/// AB-D-0075). The worked example is VibeVoice-ASR-Streaming's own declaration, from its port's
/// `phys_footprint` re-measure (PORTING-SPEC.md V5b): int4 `peakActivationBytes` 4.60 GB = a
/// 10-minute session, growth 0.182 GB per minute of audio.
final class ActivationScalingTests: XCTestCase {

    /// A pre-1.41 footprint (no scaling key) must decode with `nil` — every shipped manifest on
    /// the fleet is this shape, and a decode failure here would brick registration fleet-wide.
    func testPre141FootprintDecodesWithNilScaling() throws {
        let old = #"{"quant":"int4","residentBytes":6200000000,"peakActivationBytes":4600000000}"#
        let fp = try JSONDecoder().decode(QuantFootprint.self, from: Data(old.utf8))
        XCTAssertNil(fp.activationScaling)
        XCTAssertEqual(fp.peakActivationBytes, 4_600_000_000)
    }

    /// The default-argument init keeps every existing call site compiling — scaling is opt-in.
    func testDefaultInitHasNoScaling() {
        XCTAssertNil(QuantFootprint(quant: .int4, residentBytes: 1).activationScaling)
    }

    func testScalingSurvivesRoundTripAndTheAxisEncodesAsAString() throws {
        let fp = QuantFootprint(
            quant: .int4, residentBytes: 6_200_000_000, peakActivationBytes: 4_600_000_000,
            activationScaling: ActivationScaling(axis: .audioSeconds, baseBytes: 2_780_000_000,
                                                 bytesPerUnit: 0.182e9 / 60,
                                                 measuredCeiling: 600))
        let data = try JSONEncoder().encode(fp)
        let json = String(decoding: data, as: UTF8.self)
        // An open vocabulary is only open if a manifest author can write the unit as a plain
        // string — a `{"rawValue":…}` wrapper would be a second thing to know.
        XCTAssertTrue(json.contains(#""axis":"audioSeconds""#), json)
        let round = try JSONDecoder().decode(QuantFootprint.self, from: data)
        XCTAssertEqual(round, fp)
        XCTAssertEqual(round.activationScaling?.measuredCeiling, 600)
    }

    /// The VibeVoice worked example: the model reproduces the declared scalar at the ceiling,
    /// projects the 60-minute meeting the port's spec estimates at ~13 GB, and refuses beyond
    /// the measured 10 minutes.
    func testVibeVoiceWorkedExample() {
        let perSecond = 0.182e9 / 60                      // 0.182 GB/min on phys_footprint
        let scaling = ActivationScaling(axis: .audioSeconds, baseBytes: 2_780_000_000,
                                        bytesPerUnit: perSecond, measuredCeiling: 600)
        XCTAssertTrue(scaling.isWellFormed)
        XCTAssertEqual(Int64(scaling.projectedBytes(at: 600)), 4_600_000_000, accuracy: 1)
        XCTAssertEqual(Int64(scaling.projectedBytes(at: 3600)), 13_700_000_000, accuracy: 1)
        XCTAssertEqual(Int64(scaling.projectedBytes(at: 0)), 2_780_000_000)
        XCTAssertTrue(scaling.covers(600))
        XCTAssertFalse(scaling.covers(600.5))
        // FIT-2: the declared 4.60 GB reserve covers the model at the ceiling — exactly, and the
        // nearest-byte rounding is what keeps "exactly" from failing by one byte.
        XCTAssertTrue(scaling.isCovered(by: 4_600_000_000))
        XCTAssertFalse(scaling.isCovered(by: 4_599_999_998))
    }

    /// The projection is monotonic in the workload, clamps at zero, and never traps on
    /// absurd inputs — it is shown for out-of-envelope jobs, so it must survive them.
    func testProjectionClampsAndSurvivesExtremes() {
        let flat = ActivationScaling(axis: .frames, baseBytes: 0, bytesPerUnit: 0,
                                     measuredCeiling: 1)
        XCTAssertEqual(flat.projectedBytes(at: 1e12), 0)
        let steep = ActivationScaling(axis: .tokens, baseBytes: 1, bytesPerUnit: 1e30,
                                      measuredCeiling: 1)
        XCTAssertEqual(steep.projectedBytes(at: 1e30), UInt64.max)
        XCTAssertEqual(steep.projectedBytes(at: .nan), 0)
        let line = ActivationScaling(axis: .visualTokens, baseBytes: 1_000, bytesPerUnit: 2.5,
                                     measuredCeiling: 8192)
        XCTAssertEqual(line.projectedBytes(at: 4096), 11_240)
        XCTAssertLessThan(line.projectedBytes(at: 4096), line.projectedBytes(at: 8192))
    }

    /// FIT-1: a zero or non-finite ceiling and a negative or non-finite slope are malformed —
    /// and a malformed declaration is not silently absent (a zero ceiling refuses every run).
    func testWellFormedness() {
        XCTAssertFalse(ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: 1,
                                         measuredCeiling: 0).isWellFormed)
        XCTAssertFalse(ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: -1,
                                         measuredCeiling: 10).isWellFormed)
        XCTAssertFalse(ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: .nan,
                                         measuredCeiling: 10).isWellFormed)
        XCTAssertFalse(ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: 1,
                                         measuredCeiling: .infinity).isWellFormed)
        XCTAssertTrue(ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: 0,
                                        measuredCeiling: 1).isWellFormed)
        XCTAssertFalse(ActivationScaling(axis: .tokens, baseBytes: 0, bytesPerUnit: 1,
                                         measuredCeiling: 0).covers(0.5))
    }

    /// The axis is open: a unit nobody named yet round-trips, and the canonical constants are
    /// plain strings a manifest author can write by hand.
    func testWorkloadAxisIsOpen() throws {
        let minted: WorkloadAxis = "meshTriangles"
        let round = try JSONDecoder().decode(WorkloadAxis.self, from: JSONEncoder().encode(minted))
        XCTAssertEqual(round, minted)
        XCTAssertEqual(WorkloadAxis.pixelFrames.rawValue, "pixelFrames")
        XCTAssertEqual(WorkloadAxis(rawValue: "audioSeconds"), .audioSeconds)
        XCTAssertEqual("\(WorkloadAxis.visualTokens)", "visualTokens")
    }

    /// `MachineFitAdvisory`'s two new members are defaulted — the 1.36.0 construction site
    /// compiles unchanged, and the scalar form reads as scalar-only.
    func testAdvisoryInitDefaultsAreScalarOnly() {
        let machine = MachineMemory(totalBytes: 1, freeBytes: 1, inactiveBytes: 0,
                                    wiredBytes: 0, compressedBytes: 0)
        let advisory = MachineFitAdvisory(package: "p", projectedPeakBytes: 1,
                                          currentProcessBytes: 0, additionalBytes: 1,
                                          machine: machine, fits: true, message: "m")
        XCTAssertNil(advisory.activationScaling)
        XCTAssertNil(advisory.workload)
    }

    /// The lane hint has an extension default of `nil`, so every existing `FootprintConfigured`
    /// conformer compiles unchanged.
    func testFootprintConfiguredHintDefaultsToNil() {
        struct Legacy: PackageConfiguration, FootprintConfigured {
            var residentBytesHint: UInt64? { 7 }
        }
        XCTAssertNil(Legacy().activationScalingHint)
        XCTAssertNil(Legacy().peakActivationBytesHint)
    }
}
