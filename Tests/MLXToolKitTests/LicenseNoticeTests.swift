//
//  LicenseNoticeTests.swift
//  MLXToolKitTests
//
//  Contract 1.56.0 — `LicenseRef-MiniMax-Music3-Community` and the screen-side `LicenseNotice` slot
//  (AB-A-0202, AB-D-0157): the license admits under the default policy, a license with a UI display
//  duty is caught when its string is missing, and pre-1.56 declaration JSON still decodes.
//

import XCTest
@testable import MLXToolKit

final class LicenseNoticeTests: XCTestCase {

    func testMiniMaxMusic3CommunityIsAllowlisted() {
        // The operator accepted the US$20 M cap, the UI display duty and the §4 safeguards duty
        // (AB-D-0157). The bar sits above ltx2Community's US$10 M with no non-compete, so it admits
        // under the DEFAULT .permissiveOnly — no acknowledgement flow, no advisory.
        XCTAssertEqual(SPDXLicense.minimaxMusic3Community.identifier, "LicenseRef-MiniMax-Music3-Community")
        XCTAssertTrue(SPDXLicense.minimaxMusic3Community.isPermissive)
        XCTAssertFalse(SPDXLicense.minimaxMusic3Community.isEvalAcknowledged)
        let decl = LicenseDeclaration(weightLicense: .minimaxMusic3Community, portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .admitted)
        XCTAssertTrue(LicensePolicy.permissiveOrAcknowledged.admits(.minimaxMusic3Community))
    }

    func testOnlyLicensesWithADisplayDutyNameAString() {
        XCTAssertEqual(SPDXLicense.minimaxMusic3Community.requiredDisplayText, "MiniMax-Music3")
        for license in [SPDXLicense.mit, .apache2, .ltx2Community, .bilibiliModelUse, .dinov3, "CC-BY-NC-4.0"] {
            XCTAssertNil(license.requiredDisplayText, "\(license) has no UI display duty")
        }
    }

    // The MiniMax manifest shape: the §3.1 string as a required notice, the §4 duty as information.
    func testADeclaredDisplayNoticeSatisfiesTheDuty() {
        let decl = LicenseDeclaration(
            weightLicense: .minimaxMusic3Community, portCodeLicense: .mit,
            notices: [
                LicenseNotice(text: "MiniMax-Music3", display: .required, license: .minimaxMusic3Community,
                              termsURL: "https://huggingface.co/MiniMaxAI/MiniMax-Music3/blob/main/LICENSE"),
                LicenseNotice(text: "A hosted generation service built on this model owes reasonable and "
                              + "proportionate safeguards against infringing outputs (§4).",
                              display: .informational, license: .minimaxMusic3Community),
            ])
        XCTAssertEqual(decl.requiredNotices.map(\.text), ["MiniMax-Music3"])
        XCTAssertTrue(decl.missingRequiredDisplayNotices.isEmpty)
    }

    func testAMissingDisplayNoticeIsNamed() {
        let silent = LicenseDeclaration(weightLicense: .minimaxMusic3Community, portCodeLicense: .mit)
        XCTAssertEqual(silent.missingRequiredDisplayNotices, [.minimaxMusic3Community])

        // An informational notice carrying the string does not count — the duty is to SHOW it.
        let folded = LicenseDeclaration(
            weightLicense: .minimaxMusic3Community, portCodeLicense: .mit,
            notices: [LicenseNotice(text: "Built on MiniMax-Music3", display: .informational)])
        XCTAssertEqual(folded.missingRequiredDisplayNotices, [.minimaxMusic3Community])

        // A required notice whose text merely contains the string satisfies it.
        let phrased = LicenseDeclaration(
            weightLicense: .apache2, additionalWeightLicenses: [.minimaxMusic3Community], portCodeLicense: .mit,
            notices: [LicenseNotice(text: "Music by MiniMax-Music3", display: .required)])
        XCTAssertTrue(phrased.missingRequiredDisplayNotices.isEmpty)

        // A license with no duty is never missing anything.
        XCTAssertTrue(LicenseDeclaration(weightLicense: .mit, portCodeLicense: .mit).missingRequiredDisplayNotices.isEmpty)
    }

    // YuE2's shape: a non-commercial license (never allowlisted) with two informational notices, one
    // about a clause and one about the use.
    func testInformationalNoticesCarryANonCommercialOffer() {
        let decl = LicenseDeclaration(
            weightLicense: "CC-BY-NC-4.0", portCodeLicense: .mit,
            notices: [
                LicenseNotice(text: "YuE2-3B by M-A-P, CC BY-NC 4.0. Non-commercial use only.",
                              display: .informational, license: "CC-BY-NC-4.0",
                              termsURL: "https://huggingface.co/m-a-p/YuE2-3B/blob/main/LICENSE"),
                LicenseNotice(text: "Covers and supplied lyrics may need the original song's rights.",
                              display: .informational),
            ])
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .rejectedWeight("CC-BY-NC-4.0"))
        XCTAssertTrue(decl.requiredNotices.isEmpty)
        XCTAssertNil(decl.notices?.last?.license)
        XCTAssertTrue(decl.missingRequiredDisplayNotices.isEmpty)
    }

    // Pre-1.56 declaration JSON has no `notices` key and decodes as before; a declaration with notices
    // round-trips.
    func testWireCompatibility() throws {
        let legacy = Data("""
        {"weightLicense":{"identifier":"Apache-2.0"},"portCodeLicense":{"identifier":"MIT"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(LicenseDeclaration.self, from: legacy)
        XCTAssertNil(decoded.notices)
        XCTAssertEqual(decoded.weightLicense, .apache2)

        let decl = LicenseDeclaration(
            weightLicense: .minimaxMusic3Community, portCodeLicense: .mit,
            notices: [LicenseNotice(text: "MiniMax-Music3", display: .required, license: .minimaxMusic3Community)])
        let round = try JSONDecoder().decode(LicenseDeclaration.self, from: JSONEncoder().encode(decl))
        XCTAssertEqual(round, decl)
    }
}
