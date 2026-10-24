//
//  MusicContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.56.0 — `Capability.music` (AB-A-0201 / AB-A-0202): one lyrics-to-song surface for three
//  models that share no protocol. Checks the capability's place in the contract, the three first
//  providers' declarations, the refusal rule each optional lever is gated by, that the descriptor is
//  born declared and advertises only what it declares, and the wire shapes.
//

import XCTest
@testable import MLXToolKit

final class MusicContractTests: XCTestCase {

    // The three first providers, as their surveys describe them (MUSIC-MODEL-SURVEY.md §3).
    private let yue2 = MusicControls(features: [.planning, .score, .guidanceScale],
                                     planningModes: [.full, .melody, .off],
                                     maxDurationSeconds: 360)
    private let aceStepTurbo = MusicControls(
        features: [.referenceAudio, .sourceAudio, .anchors, .vocalLanguage, .timestamps],
        editModes: [.cover, .repaint, .extend],
        vocalLanguages: ["en", "zh", "ja", "ko", "es"],
        maxDurationSeconds: 600)
    private let minimax = MusicControls(features: [.guidanceScale], maxDurationSeconds: 300)

    private let clip = Audio(data: Data([1, 2, 3]), sampleRate: 48_000, channels: 2)

    func testMusicIsACapabilityWithAudioOutput() {
        XCTAssertTrue(Capability.allCases.contains(.music))
        XCTAssertEqual(Capability.music.rawValue, "music")
        XCTAssertEqual(Capability.music.canonicalOutput, .audio)
        XCTAssertEqual(MusicRequest.capability, .music)
    }

    func testRequestEnvelopeDefaults() {
        let request = MusicRequest(caption: "indie folk, female vocal", lyrics: "[verse]\nla la")
        XCTAssertEqual(request.capability, .music)
        XCTAssertNil(request.durationSeconds)
        XCTAssertNil(request.seed)
        XCTAssertNil(request.guidanceScale)
        XCTAssertNil(request.planning)
        XCTAssertNil(request.score)
        XCTAssertNil(request.referenceAudio)
        XCTAssertNil(request.edit)
        XCTAssertNil(request.anchors)
        XCTAssertNil(request.vocalLanguage)
        XCTAssertNil(request.mode)
        XCTAssertTrue(request.metaData.isEmpty)
        XCTAssertTrue(request.requestedFeatures.isEmpty)
    }

    // The core request passes every surface — that is what makes it the core.
    func testTheCoreRequestPassesAllThreeDeclarations() {
        let core = MusicRequest(caption: "synthwave", lyrics: "[chorus]\nneon nights",
                                durationSeconds: 120, seed: 7, guidanceScale: 1.2)
        for controls in [yue2, aceStepTurbo, minimax] {
            XCTAssertNil(controls.refusal(for: core))
            XCTAssertTrue(controls.declarationProblems.isEmpty)
        }
    }

    // guidanceScale is advisory: the turbo surface declares no CFG and still takes the request.
    func testGuidanceScaleIsNeverRefused() {
        XCTAssertFalse(aceStepTurbo.declares(.guidanceScale))
        XCTAssertNil(aceStepTurbo.refusal(for: MusicRequest(caption: "c", lyrics: "l", guidanceScale: 7)))
        XCTAssertFalse(MusicRequest(caption: "c", lyrics: "l", guidanceScale: 7).requestedFeatures
            .contains(.guidanceScale))
    }

    // Each lever maps onto the feature it needs, and the refusal names the feature and the fix.
    func testEachLeverNeedsItsFeature() throws {
        let planned = MusicRequest(caption: "c", lyrics: "l", planning: .full)
        XCTAssertEqual(planned.requestedFeatures, [.planning])
        XCTAssertNil(yue2.refusal(for: planned))
        XCTAssertTrue(try XCTUnwrap(minimax.refusal(for: planned)).hasPrefix("planning(.full)"))

        let scored = MusicRequest(caption: "c", lyrics: "l", score: "X:1\nK:C\nCDEF|")
        XCTAssertEqual(scored.requestedFeatures, [.score])
        XCTAssertNil(yue2.refusal(for: scored))
        XCTAssertTrue(try XCTUnwrap(aceStepTurbo.refusal(for: scored)).hasPrefix("score —"))

        let timbre = MusicRequest(caption: "c", lyrics: "l", referenceAudio: clip)
        XCTAssertEqual(timbre.requestedFeatures, [.referenceAudio])
        XCTAssertNil(aceStepTurbo.refusal(for: timbre))
        XCTAssertTrue(try XCTUnwrap(yue2.refusal(for: timbre)).hasPrefix("referenceAudio —"))

        let cover = MusicRequest(caption: "c", lyrics: "l",
                                 edit: MusicEdit(source: clip, operation: .cover(strength: 0.6)))
        XCTAssertEqual(cover.requestedFeatures, [.sourceAudio])
        XCTAssertNil(aceStepTurbo.refusal(for: cover))
        XCTAssertTrue(try XCTUnwrap(minimax.refusal(for: cover)).hasPrefix("edit(.cover)"))

        let anchored = MusicRequest(caption: "c", lyrics: "l", anchors: MusicAnchors(bpm: 120, key: "A minor"))
        XCTAssertEqual(anchored.requestedFeatures, [.anchors])
        XCTAssertNil(aceStepTurbo.refusal(for: anchored))
        XCTAssertTrue(try XCTUnwrap(yue2.refusal(for: anchored)).hasPrefix("anchors —"))

        let sung = MusicRequest(caption: "c", lyrics: "l", vocalLanguage: "ja")
        XCTAssertEqual(sung.requestedFeatures, [.vocalLanguage])
        XCTAssertNil(aceStepTurbo.refusal(for: sung))
        XCTAssertTrue(try XCTUnwrap(minimax.refusal(for: sung)).hasPrefix("vocalLanguage(\"ja\")"))
    }

    // An empty anchors value asks for nothing, so it is neither a feature nor a refusal.
    func testEmptyAnchorsAskForNothing() {
        let request = MusicRequest(caption: "c", lyrics: "l", anchors: MusicAnchors())
        XCTAssertTrue(request.anchors?.isEmpty == true)
        XCTAssertTrue(request.requestedFeatures.isEmpty)
        XCTAssertNil(minimax.refusal(for: request))
    }

    // Vocabularies: a declared mode or language outside the list is refused; the list is quoted.
    func testVocabulariesAreEnforcedWhenDeclared() throws {
        let melodyOnly = MusicControls(features: [.planning], planningModes: [.melody])
        XCTAssertNil(melodyOnly.refusal(for: MusicRequest(caption: "c", lyrics: "l", planning: .melody)))
        let planning = try XCTUnwrap(melodyOnly.refusal(for: MusicRequest(caption: "c", lyrics: "l", planning: .full)))
        XCTAssertTrue(planning.contains("planningModes: melody"))

        let coverOnly = MusicControls(features: [.sourceAudio], editModes: [.cover])
        let repaint = MusicRequest(caption: "c", lyrics: "l",
                                   edit: MusicEdit(source: clip, operation: .repaint(start: 10, end: 20)))
        XCTAssertTrue(try XCTUnwrap(coverOnly.refusal(for: repaint)).contains("editModes: cover"))

        let english = MusicRequest(caption: "c", lyrics: "l", vocalLanguage: "EN")
        XCTAssertNil(aceStepTurbo.refusal(for: english), "BCP-47 tags compare case-insensitively")
        let french = MusicRequest(caption: "c", lyrics: "l", vocalLanguage: "fr")
        XCTAssertTrue(try XCTUnwrap(aceStepTurbo.refusal(for: french)).contains("vocalLanguages: en / zh"))

        let open = MusicControls(features: [.vocalLanguage])
        XCTAssertNil(open.refusal(for: french), "an empty vocabulary is open")
    }

    func testDurationPastTheDeclaredMaximumIsRefused() throws {
        XCTAssertNil(minimax.refusal(for: MusicRequest(caption: "c", lyrics: "l", durationSeconds: 300)))
        let long = try XCTUnwrap(minimax.refusal(for: MusicRequest(caption: "c", lyrics: "l", durationSeconds: 301)))
        XCTAssertEqual(long, "durationSeconds(301) — this surface renders at most 300 s "
                       + "(MusicControls.maxDurationSeconds)")
        let unstated = MusicControls(features: [])
        XCTAssertNil(unstated.refusal(for: MusicRequest(caption: "c", lyrics: "l", durationSeconds: 9_999)))
    }

    // A declaration says what it means: a feature carries its vocabulary and a vocabulary its feature.
    func testDeclarationProblemsNameIncoherence() {
        XCTAssertEqual(MusicControls(features: [.planning]).declarationProblems,
                       ["planning is declared with no planningModes"])
        XCTAssertEqual(MusicControls(features: [], planningModes: [.off]).declarationProblems,
                       ["planningModes are declared without the planning feature"])
        XCTAssertEqual(MusicControls(features: [.sourceAudio]).declarationProblems,
                       ["sourceAudio is declared with no editModes"])
        XCTAssertEqual(MusicControls(features: [], editModes: [.extend]).declarationProblems,
                       ["editModes are declared without the sourceAudio feature"])
        XCTAssertEqual(MusicControls(features: [], vocalLanguages: ["en"]).declarationProblems,
                       ["vocalLanguages are declared without the vocalLanguage feature"])
        XCTAssertEqual(MusicControls(features: [], maxDurationSeconds: 0).declarationProblems,
                       ["maxDurationSeconds must be positive"])
    }

    func testEditOperationKinds() {
        XCTAssertEqual(MusicEditOperation.cover(strength: 0.5).kind, .cover)
        XCTAssertEqual(MusicEditOperation.repaint(start: 1, end: 2).kind, .repaint)
        XCTAssertEqual(MusicEditOperation.extend(trailing: 30).kind, .extend)
        if case .extend(let leading, let trailing) = MusicEditOperation.extend(trailing: 30) {
            XCTAssertEqual(leading, 0)
            XCTAssertEqual(trailing, 30)
        } else {
            XCTFail("extend lost its defaults")
        }
    }

    // Born declared: only a declared feature's parameter is advertised, core parameters always.
    func testDescriptorAdvertisesOnlyWhatItDeclares() throws {
        let yue = MusicContract.descriptor(name: "yue2-3b", summary: "s", controls: yue2)
        XCTAssertEqual(yue.capability, .music)
        XCTAssertEqual(yue.musicControls, yue2)
        XCTAssertTrue(yue.controlsMatchCapability)
        XCTAssertEqual(yue.parameters.map(\.name),
                       ["caption", "lyrics", "durationSeconds", "seed", "guidanceScale", "planning", "score"])
        XCTAssertEqual(yue.parameters.filter(\.required).map(\.name), ["caption", "lyrics"])
        let planning = try XCTUnwrap(yue.parameters.first { $0.name == "planning" })
        XCTAssertEqual(planning.summary, "Plan a score first: full / melody / off. The plan comes back as `score` (ABC).")
        let duration = try XCTUnwrap(yue.parameters.first { $0.name == "durationSeconds" })
        XCTAssertEqual(duration.summary, "Target length in seconds (up to 360); a package that plans its own "
                       + "length treats it as a cap and reports `truncated`.")

        let ace = MusicContract.descriptor(name: "ace-step-1.5-turbo", summary: "s", controls: aceStepTurbo)
        XCTAssertEqual(ace.parameters.map(\.name),
                       ["caption", "lyrics", "durationSeconds", "seed", "referenceAudio", "edit", "anchors",
                        "vocalLanguage"])
        let edit = try XCTUnwrap(ace.parameters.first { $0.name == "edit" })
        XCTAssertEqual(edit.kind, .object)
        XCTAssertEqual(edit.summary, "A source clip and what to do to it: cover {strength 0…1}; "
                       + "repaint {start, end} seconds; extend {leading?, trailing} seconds.")
        XCTAssertEqual(ace.parameters.first { $0.name == "referenceAudio" }?.kind, .audio)
        XCTAssertEqual(ace.parameters.first { $0.name == "vocalLanguage" }?.summary,
                       "BCP-47 tag of the language to sing in: en / zh / ja / ko / es.")

        let mm = MusicContract.descriptor(name: "minimax-music3", summary: "s", controls: minimax)
        XCTAssertEqual(mm.parameters.map(\.name), ["caption", "lyrics", "durationSeconds", "seed", "guidanceScale"])
    }

    func testControlsMustMatchTheSurfaceCapability() {
        let mismatched = ToolDescriptor(name: "sfx", capability: .soundEffect, summary: "s",
                                        controls: .music(minimax))
        XCTAssertFalse(mismatched.controlsMatchCapability)
        XCTAssertNil(SoundEffectContract.descriptor(name: "sfx", summary: "s").musicControls)
    }

    func testDescriptorAndRequestRoundTrip() throws {
        let descriptor = MusicContract.descriptor(name: "ace-step-1.5-turbo", summary: "s", controls: aceStepTurbo)
        let round = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor))
        XCTAssertEqual(round, descriptor)
        XCTAssertEqual(round.musicControls?.editModes, [.cover, .repaint, .extend])

        // Requests are not wire types (no CapabilityRequest is Codable); their value parts are.
        let edit = MusicEdit(source: clip, operation: .extend(leading: 5, trailing: 30))
        XCTAssertEqual(try JSONDecoder().decode(MusicEdit.self, from: JSONEncoder().encode(edit)), edit)
        let anchors = MusicAnchors(bpm: 96, key: "F# minor", timeSignature: "6/8")
        XCTAssertEqual(try JSONDecoder().decode(MusicAnchors.self, from: JSONEncoder().encode(anchors)), anchors)
        for mode in MusicPlanningMode.allCases {
            XCTAssertEqual(try JSONDecoder().decode(MusicPlanningMode.self, from: JSONEncoder().encode(mode)), mode)
        }
        let operations: [MusicEditOperation] = [.cover(strength: 0.4), .repaint(start: 1, end: 2), .extend(trailing: 9)]
        for operation in operations {
            XCTAssertEqual(try JSONDecoder().decode(MusicEditOperation.self, from: JSONEncoder().encode(operation)),
                           operation)
        }
    }

    // The response states its rate and channels and whether it was cut short.
    func testResponseCarriesThePlanAndTheTruncationFlag() throws {
        let response = MusicResponse(audio: clip, truncated: true, score: "X:1\nK:C\n",
                                     anchors: MusicAnchors(bpm: 120),
                                     timestamps: [MusicLyricTimestamp(text: "neon", start: 1.5, end: 2.0)])
        XCTAssertEqual(response.audio.sampleRate, 48_000)
        XCTAssertEqual(response.audio.channels, 2)
        XCTAssertTrue(response.truncated)
        XCTAssertEqual(response.timestamps?.first?.text, "neon")
        let stamp = try XCTUnwrap(response.timestamps?.first)
        XCTAssertEqual(try JSONDecoder().decode(MusicLyricTimestamp.self, from: JSONEncoder().encode(stamp)), stamp)

        XCTAssertFalse(MusicResponse(audio: clip).truncated)
        XCTAssertNil(MusicResponse(audio: clip).score)
    }

    func testPlanIsACanonicalRunPhase() {
        XCTAssertEqual(RunPhase.plan.rawValue, "plan")
        XCTAssertNotEqual(RunPhase.plan, RunPhase.generate)
    }
}
