//
//  AppleLicenseTests.swift
//  MLXToolKitTests
//
//  Contract 1.67.0 (AB-A-0309) — the two Apple licences mlx-fastframes-swift declares:
//  `LicenseRef-Apple-AMLR` on research weights (eval-acknowledged) and
//  `LicenseRef-Apple-Sample-Code` on port code (a standard code licence).
//

import XCTest
@testable import MLXToolKit

final class AppleLicenseTests: XCTestCase {
    func testRawValuesMatchThePublishedManifests() {
        XCTAssertEqual(SPDXLicense.appleAMLR.identifier, "LicenseRef-Apple-AMLR")
        XCTAssertEqual(SPDXLicense.appleSampleCode.identifier, "LicenseRef-Apple-Sample-Code")
        XCTAssertEqual(SPDXLicense.appleAMLR, "LicenseRef-Apple-AMLR")
        XCTAssertEqual(SPDXLicense.appleSampleCode, "LicenseRef-Apple-Sample-Code")
    }

    func testAMLRIsEvalAcknowledgedAndNeverPermissive() {
        XCTAssertFalse(SPDXLicense.appleAMLR.isPermissive)
        XCTAssertTrue(SPDXLicense.appleAMLR.isEvalAcknowledged)
        XCTAssertFalse(SPDXLicense.appleAMLR.isStandardCodeLicense)
        XCTAssertNil(SPDXLicense.appleAMLR.requiredDisplayText)
        XCTAssertFalse(LicensePolicy.permissiveOnly.admits(.appleAMLR))
        XCTAssertTrue(LicensePolicy.permissiveOrAcknowledged.admits(.appleAMLR))
    }

    func testSampleCodeIsAPermissiveStandardCodeLicense() {
        XCTAssertTrue(SPDXLicense.appleSampleCode.isPermissive)
        XCTAssertFalse(SPDXLicense.appleSampleCode.isEvalAcknowledged)
        XCTAssertTrue(SPDXLicense.appleSampleCode.isStandardCodeLicense)
        XCTAssertNil(SPDXLicense.appleSampleCode.requiredDisplayText)
        // Port code under it owes no notice naming it, unlike `.sam`.
        XCTAssertNil(LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .appleSampleCode)
            .portCodeLicenseLackingNotice)
    }

    /// The FastFrames-S declaration: an Apache-2.0 DiT, AMLR refiner and decoder, Apple sample code.
    func testTheFastFramesDeclarationIsJudgedOnTheWeightLayerOnly() {
        let decl = LicenseDeclaration(weightLicense: .apache2, additionalWeightLicenses: [.appleAMLR],
                                      portCodeLicense: .appleSampleCode)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .rejectedWeight(.appleAMLR))
        XCTAssertEqual(LicensePolicy.permissiveOrAcknowledged.evaluate(decl), .admitted)
        XCTAssertNil(decl.portCodeLicenseLackingNotice)
        XCTAssertTrue(decl.missingRequiredDisplayNotices.isEmpty)
    }
}
