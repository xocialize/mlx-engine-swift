//
//  DescribedTargetSeparationTests.swift
//  MLXToolKitTests
//
//  Contract 1.62.0 (AB-A-0268; SAM-Audio) — a described target and time spans on `audioSeparation`,
//  `Stem.target` / `.residual`, `LicenseRef-SAM`, and the notice a non-standard port-code licence owes.
//

import XCTest
@testable import MLXToolKit

final class DescribedTargetSeparationTests: XCTestCase {
    private let clip = Audio(data: Data([1]))
    /// The SAM-Audio shape: described target only, with spans.
    private let sam = AudioSeparationControls(
        stems: [.target, .residual],
        describedTarget: DescribedTargetControls(
            supportsSpans: true, phrasing: "A short lowercase noun phrase (\"speech\", \"dog barking\")."))

    private func refusal(_ controls: AudioSeparationControls, stems: [Stem] = [],
                         speaker: SpeakerSelection? = nil, _ description: String?,
                         spans: [AudioSeparationSpan] = [], duration: Double? = nil) -> String? {
        controls.refusal(for: AudioSeparationRequest(audio: clip, stems: stems, speaker: speaker,
                                                     targetDescription: description, spans: spans),
                         audioDurationSeconds: duration)
    }

    func testStemsAndSpanBasics() {
        XCTAssertEqual(Stem.target.rawValue, "target")
        XCTAssertEqual(Stem.residual.rawValue, "residual")
        XCTAssertTrue(AudioSeparationSpan(startSeconds: 0, endSeconds: 0.5).isValid)
        XCTAssertTrue(AudioSeparationSpan(startSeconds: 0, endSeconds: 0.5).present)
        XCTAssertFalse(AudioSeparationSpan(startSeconds: 2, endSeconds: 2).isValid)
        XCTAssertFalse(AudioSeparationSpan(startSeconds: -1, endSeconds: 2).isValid)
        XCTAssertFalse(AudioSeparationSpan(startSeconds: 0, endSeconds: .infinity).isValid)
        XCTAssertFalse(AudioSeparationSpan(startSeconds: .nan, endSeconds: 1).isValid)
    }

    func testADescribedTargetIsAdmittedWhereDeclared() {
        XCTAssertNil(refusal(sam, "speech"))
        XCTAssertNil(refusal(sam, stems: [.target], "dog barking"))
        XCTAssertNil(refusal(sam, stems: [.residual, .target], "speech",
                             spans: [AudioSeparationSpan(startSeconds: 0, endSeconds: 2),
                                     AudioSeparationSpan(startSeconds: 4, endSeconds: 6, present: false)]))
        XCTAssertEqual(sam.fixedStems, [])
    }

    func testRefusals() {
        // Not declared at all, or declared without spans.
        let auk = AudioSeparationControls(stems: [.speech, .speaker], speakerSelection: [.ordinal])
        XCTAssertTrue(refusal(auk, "speech")?.contains("describedTarget") == true)
        let noSpans = AudioSeparationControls(stems: [.target, .residual], describedTarget: DescribedTargetControls())
        let span = AudioSeparationSpan(startSeconds: 0, endSeconds: 1)
        XCTAssertNil(refusal(noSpans, "speech"))
        XCTAssertTrue(refusal(noSpans, "speech", spans: [span])?.contains("supportsSpans") == true)

        // The description itself.
        XCTAssertTrue(refusal(sam, "  \n")?.contains("name the sound") == true)
        XCTAssertTrue(refusal(sam, nil)?.contains("declares no fixed stems") == true)
        XCTAssertTrue(refusal(sam, nil, spans: [span])?.hasPrefix("spans") == true)
        XCTAssertTrue(refusal(sam, stems: [.target], nil)?.hasPrefix("stems(target)") == true)
        XCTAssertTrue(refusal(sam, stems: [.vocals], "speech")?.hasPrefix("stems(vocals)") == true)

        // Spans.
        XCTAssertTrue(refusal(sam, "speech", spans: [AudioSeparationSpan(startSeconds: 3, endSeconds: 3)])?
            .hasPrefix("spans[0]") == true)
        XCTAssertTrue(refusal(sam, "speech", spans: [span, AudioSeparationSpan(startSeconds: 0.5, endSeconds: 2,
                                                                                present: false)])?
            .contains("opposite") == true)
        // Overlap with the same polarity is harmless; touching spans do not overlap.
        XCTAssertNil(refusal(sam, "speech", spans: [span, AudioSeparationSpan(startSeconds: 0.5, endSeconds: 2)]))
        XCTAssertNil(refusal(sam, "speech", spans: [span, AudioSeparationSpan(startSeconds: 1, endSeconds: 2,
                                                                               present: false)]))
    }

    // `Audio` states no length, so the engine passes none; a package that decoded the audio does.
    func testASpanPastTheEndIsRefusedOnlyWhereTheLengthIsKnown() {
        let late = [AudioSeparationSpan(startSeconds: 8, endSeconds: 12)]
        XCTAssertNil(refusal(sam, "speech", spans: late))
        XCTAssertNil(refusal(sam, "speech", spans: late, duration: 12))
        XCTAssertTrue(refusal(sam, "speech", spans: late, duration: 10)?.contains("past the end") == true)
    }

    // A surface serving fixed stems, speaker picks AND a described target: a plain stem request still
    // runs, the described stems need a description, and the two ways of naming a target do not mix.
    func testAMixedSurface() {
        let mixed = AudioSeparationControls(stems: [.speech, .music, .speaker, .target, .residual],
                                            speakerSelection: [.ordinal],
                                            describedTarget: DescribedTargetControls())
        XCTAssertEqual(mixed.fixedStems, [.speech, .music, .speaker])
        XCTAssertNil(refusal(mixed, stems: [.speech], nil))
        XCTAssertNil(refusal(mixed, speaker: .ordinal(1), nil))
        XCTAssertNotNil(refusal(mixed, stems: [.residual], nil))
        XCTAssertTrue(refusal(mixed, speaker: .ordinal(1), "speech")?.contains("send one") == true)
        // The 1.59 speaker rules still run after the described-target ones.
        XCTAssertNotNil(refusal(mixed, speaker: .ordinal(0), nil))
        // A description-only surface with speaker picks does not demand a description for a pick.
        let picks = AudioSeparationControls(stems: [.speaker, .target], speakerSelection: [.ordinal],
                                            describedTarget: DescribedTargetControls())
        XCTAssertNil(refusal(picks, speaker: .ordinal(2), nil))
    }

    func testDescriptorAdvertisesOnlyWhatIsDeclared() throws {
        let descriptor = AudioSeparationContract.descriptor(name: "sam-audio", summary: "s", controls: sam)
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "stems", "targetDescription", "spans"])
        let description = try XCTUnwrap(descriptor.parameters.first { $0.name == "targetDescription" })
        XCTAssertTrue(description.required)
        XCTAssertTrue(description.summary?.contains("dog barking") == true)
        XCTAssertEqual(descriptor.audioSeparationControls, sam)
        XCTAssertTrue(descriptor.controlsMatchCapability)
        XCTAssertEqual(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor)),
                       descriptor)

        let noSpans = AudioSeparationContract.descriptor(
            name: "x", summary: "s",
            controls: AudioSeparationControls(stems: [.vocals, .target, .residual],
                                              describedTarget: DescribedTargetControls()))
        XCTAssertEqual(noSpans.parameters.map(\.name), ["audio", "stems", "targetDescription"])
        XCTAssertFalse(try XCTUnwrap(noSpans.parameters.last).required)

        let auk = AudioSeparationContract.descriptor(
            name: "auk", summary: "s",
            controls: AudioSeparationControls(stems: [.speaker], speakerSelection: [.ordinal]))
        XCTAssertEqual(auk.parameters.map(\.name), ["audio", "stems", "speaker"])
    }

    func testWireCompatibility() throws {
        // A 1.59–1.61 request and controls block decode with nothing described.
        let oldRequest = Data(#"{"audio":{"format":"wav","data":"AQ=="},"stems":["vocals"],"metaData":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(AudioSeparationRequest.self, from: oldRequest)
        XCTAssertNil(decoded.targetDescription)
        XCTAssertEqual(decoded.spans, [])
        XCTAssertNil(decoded.declaredLever)
        let oldControls = Data(#"{"stems":["speaker"],"speakerSelection":["ordinal"]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AudioSeparationControls.self, from: oldControls).describedTarget)
        XCTAssertEqual(try JSONDecoder().decode(DescribedTargetControls.self, from: Data("{}".utf8)),
                       DescribedTargetControls())
        XCTAssertTrue(try JSONDecoder().decode(AudioSeparationSpan.self,
                                               from: Data(#"{"startSeconds":1,"endSeconds":2}"#.utf8)).present)

        let request = AudioSeparationRequest(
            audio: clip, stems: [.target], targetDescription: "speech",
            spans: [AudioSeparationSpan(startSeconds: 1, endSeconds: 2.5, present: false)])
        let round = try JSONDecoder().decode(AudioSeparationRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(round.targetDescription, "speech")
        XCTAssertEqual(round.spans, request.spans)
        XCTAssertEqual(round.stems, [.target])
        XCTAssertEqual(request.declaredLever, "targetDescription")
        XCTAssertEqual(try JSONDecoder().decode(AudioSeparationControls.self, from: JSONEncoder().encode(sam)), sam)
    }

    // MARK: - LicenseRef-SAM (AB-D-0220) and a non-standard port-code licence

    func testSAMLicenseIsAllowlistedOnBothLayers() {
        XCTAssertEqual(SPDXLicense.sam.identifier, "LicenseRef-SAM")
        XCTAssertTrue(SPDXLicense.sam.isPermissive)
        XCTAssertFalse(SPDXLicense.sam.isEvalAcknowledged)
        XCTAssertNil(SPDXLicense.sam.requiredDisplayText)
        XCTAssertFalse(SPDXLicense.sam.isStandardCodeLicense)
        // SAM-Audio: weights and port code both under the SAM License; T5 / DAC-VAE are Apache-2.0.
        let decl = LicenseDeclaration(weightLicense: .sam, additionalWeightLicenses: [.apache2],
                                      portCodeLicense: .sam)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .admitted)
    }

    func testAStandardCodeLicenseOwesNoPortCodeNotice() {
        for license in [SPDXLicense.mit, .apache2, .bsd2, .bsd3, .isc, .unlicense] {
            XCTAssertTrue(license.isStandardCodeLicense)
            XCTAssertNil(LicenseDeclaration(weightLicense: .sam, portCodeLicense: license)
                .portCodeLicenseLackingNotice)
        }
        // Model licences are on the allowlist as terms on WEIGHTS; none is a code licence.
        for license in [SPDXLicense.ltx2Community, .dinov3, .gemmaTerms, .ccBy4, .sam] {
            XCTAssertFalse(license.isStandardCodeLicense, "\(license)")
        }
    }

    func testPortCodeUnderCustomTermsNeedsANoticeNamingThatLicense() {
        let silent = LicenseDeclaration(weightLicense: .sam, portCodeLicense: .sam)
        XCTAssertEqual(silent.portCodeLicenseLackingNotice, .sam)

        // A note about the output (the watermark) names no licence and does not satisfy it.
        let watermark = LicenseNotice(text: "Every output carries an AudioSeal watermark.", display: .informational)
        XCTAssertEqual(LicenseDeclaration(weightLicense: .sam, portCodeLicense: .sam, notices: [watermark])
            .portCodeLicenseLackingNotice, .sam)

        let terms = LicenseNotice(
            text: "Model and code are under Meta's SAM License: redistribute only under the same "
                + "agreement with a copy of it; no military, nuclear, espionage or weapons end uses.",
            display: .informational, license: .sam,
            termsURL: "https://huggingface.co/facebook/sam-audio-base/blob/main/LICENSE")
        let declared = LicenseDeclaration(weightLicense: .sam, portCodeLicense: .sam, notices: [terms, watermark])
        XCTAssertNil(declared.portCodeLicenseLackingNotice)
        XCTAssertTrue(declared.missingRequiredDisplayNotices.isEmpty)
        XCTAssertTrue(declared.requiredNotices.isEmpty)
        XCTAssertNil(declared.notices?.last?.license)
    }
}
