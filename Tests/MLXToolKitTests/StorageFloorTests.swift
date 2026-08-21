import XCTest
@testable import MLXToolKit

/// 1.34.0 additive-compatibility gates for the §5.6 bandwidth floor (AB-T-0070).
final class StorageFloorTests: XCTestCase {

    /// A pre-1.34 manifest (no floor key) must decode with `nil` — every shipped manifest on the
    /// fleet is this shape, and a decode failure here would brick registration fleet-wide.
    func testPre134FootprintDecodesWithNilFloor() throws {
        let old = #"{"quant":"int8","residentBytes":23000000000,"peakActivationBytes":5000000000}"#
        let fp = try JSONDecoder().decode(QuantFootprint.self, from: Data(old.utf8))
        XCTAssertNil(fp.minSustainedReadBytesPerSecond)
        XCTAssertEqual(fp.residentBytes, 23_000_000_000)
    }

    func testFloorSurvivesRoundTrip() throws {
        let fp = QuantFootprint(quant: .bf16, residentBytes: 40_000_000_000,
                                peakActivationBytes: 6_000_000_000,
                                minSustainedReadBytesPerSecond: 1_000_000_000)
        let round = try JSONDecoder().decode(
            QuantFootprint.self, from: JSONEncoder().encode(fp))
        XCTAssertEqual(round, fp)
        XCTAssertEqual(round.minSustainedReadBytesPerSecond, 1_000_000_000)
    }

    /// The default-argument init keeps every existing call site compiling — the floor is opt-in.
    func testDefaultInitHasNoFloor() {
        let fp = QuantFootprint(quant: .int4, residentBytes: 1)
        XCTAssertNil(fp.minSustainedReadBytesPerSecond)
        XCTAssertNil(fp.expectedWeightReadBytesPerRun)
    }

    /// 1.35.0: pre-existing JSON (no expected-read key) decodes to nil, and the field round-trips.
    func testExpectedReadVolumeIsAdditive() throws {
        let old = #"{"quant":"int8","residentBytes":1,"peakActivationBytes":0}"#
        let fp = try JSONDecoder().decode(QuantFootprint.self, from: Data(old.utf8))
        XCTAssertNil(fp.expectedWeightReadBytesPerRun)
        let with = QuantFootprint(quant: .int8, residentBytes: 1,
                                  expectedWeightReadBytesPerRun: 147 << 30)
        let round = try JSONDecoder().decode(QuantFootprint.self, from: JSONEncoder().encode(with))
        XCTAssertEqual(round.expectedWeightReadBytesPerRun, 147 << 30)
    }
}
