//
//  BundledWeightLicenseTests.swift
//  MLXToolKitTests
//
//  Contract 1.49.0 — a package that loads more than one weight set declares every weight license,
//  and the gate judges each (AB-A-0136 item 3). Before 1.49.0 a bundle was reduced to one license
//  in a source comment, which gives the right verdict only while every component is on the same list.
//

import XCTest
@testable import MLXToolKit

final class BundledWeightLicenseTests: XCTestCase {

    private let nonCommercial: SPDXLicense = "CC-BY-NC-4.0"

    func testASingleLicenseDeclarationIsUnchanged() {
        let legacy = LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit)
        XCTAssertNil(legacy.additionalWeightLicenses)
        XCTAssertEqual(legacy.weightLicenses, [.apache2])
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(legacy), .admitted)
    }

    // The Dia2-2B bundle: an Apache-2.0 model over Kyutai Mimi's CC-BY-4.0 codec, both allowlisted.
    func testAnAllowlistedBundleIsAdmitted() {
        let dia2 = LicenseDeclaration(weightLicense: .apache2, additionalWeightLicenses: [.ccBy4],
                                      portCodeLicense: .mit)
        XCTAssertEqual(dia2.weightLicenses, [.apache2, .ccBy4])
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(dia2), .admitted)
    }

    // The case the field exists for: a permissive model over a component that is not on the list
    // was admitted, because only the headline license was ever judged. The finding names the
    // COMPONENT's license, on the weight layer.
    func testANonPermissiveComponentIsTheFinding() {
        let bundle = LicenseDeclaration(weightLicense: .apache2,
                                        additionalWeightLicenses: [.ccBy4, nonCommercial],
                                        portCodeLicense: .mit)
        let result = LicensePolicy.permissiveOnly.evaluate(bundle)
        XCTAssertEqual(result, .rejectedWeight(nonCommercial))
        let advisory = result.advisory(repo: "mock/bundle", policy: .permissiveOnly)
        XCTAssertEqual(advisory?.layer, .weight)
        XCTAssertEqual(advisory?.license, nonCommercial)

        XCTAssertEqual(LicensePolicy.any.evaluate(bundle), .admitted)
    }

    // An eval-acknowledged component passes only the eval policy, as an eval-acknowledged
    // checkpoint does.
    func testAnAcknowledgedComponentPassesOnlyTheEvalPolicy() {
        let bundle = LicenseDeclaration(weightLicense: .apache2,
                                        additionalWeightLicenses: [.circleStoneNonCommercial],
                                        portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(bundle),
                       .rejectedWeight(.circleStoneNonCommercial))
        XCTAssertEqual(LicensePolicy.permissiveOrAcknowledged.evaluate(bundle), .admitted)
    }

    // The primary checkpoint is judged first, and the weight layer before the port-code layer —
    // the order a contributor already reads findings in.
    func testOrderIsPrimaryThenComponentsThenPortCode() {
        let both = LicenseDeclaration(weightLicense: .circleStoneNonCommercial,
                                      additionalWeightLicenses: [nonCommercial],
                                      portCodeLicense: "LicenseRef-Proprietary")
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(both),
                       .rejectedWeight(.circleStoneNonCommercial))

        let componentAndCode = LicenseDeclaration(weightLicense: .apache2,
                                                  additionalWeightLicenses: [nonCommercial],
                                                  portCodeLicense: "LicenseRef-Proprietary")
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(componentAndCode),
                       .rejectedWeight(nonCommercial))
    }

    // Manifest JSON written before 1.49.0 has no key for the components, and still decodes.
    func testDeclarationJSONIsBackwardCompatible() throws {
        let legacy = LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit)
        let json = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("additionalWeightLicenses"))
        XCTAssertEqual(try JSONDecoder().decode(LicenseDeclaration.self, from: json), legacy)

        let bundle = LicenseDeclaration(weightLicense: .apache2, additionalWeightLicenses: [.ccBy4],
                                        portCodeLicense: .mit)
        XCTAssertEqual(try JSONDecoder().decode(
            LicenseDeclaration.self, from: JSONEncoder().encode(bundle)), bundle)
    }
}
