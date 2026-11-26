//
//  QuantInt2Tests.swift
//  MLXToolKitTests
//
//  Contract 1.68.0 (AB-A-0334) — `Quant.int2`: 2-bit / ternary storage, ranked below `int4`.
//

import XCTest
@testable import MLXToolKit

final class QuantInt2Tests: XCTestCase {
    func testInt2RanksBelowEveryOtherQuant() {
        for other in Quant.allCases where other != .int2 {
            XCTAssertLessThan(Quant.int2.precisionRank, other.precisionRank, "\(other)")
            XCTAssertFalse(Quant.int2.meets(floor: other), "\(other)")
            XCTAssertTrue(other.meets(floor: .int2), "\(other)")
        }
        XCTAssertTrue(Quant.int2.meets(floor: .int2))
    }

    /// Ranks are public Ints; adding a case below `int4` must not move the ones already published.
    func testEarlierRanksKeepTheirValues() {
        XCTAssertEqual(Quant.int4.precisionRank, 0)
        XCTAssertEqual(Quant.mxfp4.precisionRank, 0)
        XCTAssertEqual(Quant.nvfp4.precisionRank, 0)
        XCTAssertEqual(Quant.int5.precisionRank, 1)
        XCTAssertEqual(Quant.int6.precisionRank, 2)
        XCTAssertEqual(Quant.int8.precisionRank, 3)
        XCTAssertEqual(Quant.mxfp8.precisionRank, 3)
        XCTAssertEqual(Quant.fp16.precisionRank, 4)
        XCTAssertEqual(Quant.bf16.precisionRank, 4)
        XCTAssertEqual(Quant.fp32.precisionRank, 5)
    }

    func testInt2CodesAsItsName() throws {
        XCTAssertTrue(Quant.allCases.contains(.int2))
        XCTAssertEqual(try JSONDecoder().decode(Quant.self, from: Data("\"int2\"".utf8)), .int2)
        XCTAssertEqual(String(data: try JSONEncoder().encode(Quant.int2), encoding: .utf8), "\"int2\"")
    }
}
