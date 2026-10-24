//
//  MusicDeclaredControlsTests.swift
//  MLXServeCoreTests
//
//  Contract 1.56.0 (AB-A-0201 / AB-A-0202) — the engine pre-flight for the music surface: an optional
//  lever the surface does not declare is refused before admission, a declared one reaches the package
//  intact, and a license with a UI display duty logs its missing notice at registration. Offline, mock
//  packages.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private func musicManifest(surfaces: [ToolDescriptor],
                           license: LicenseDeclaration = LicenseDeclaration(weightLicense: .apache2,
                                                                            portCodeLicense: .apache2)) -> PackageManifest {
    PackageManifest(
        license: license,
        provenance: Provenance(sourceRepo: "mock/music", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/music") }

private func unsupportedFeature(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

private let song = Audio(format: .wav, data: Data(count: 44), sampleRate: 48_000, channels: 2)
private let clip = Audio(format: .wav, data: Data(count: 44), sampleRate: 48_000, channels: 2)

/// The YuE2-3B shape: plans a score, renders a supplied one, nothing else. Answers with the score it
/// was handed (or a plan), so a test sees what crossed the engine.
@InferenceActor
private final class ScorePlanningPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        musicManifest(surfaces: [MusicContract.descriptor(
            name: "yue2-3b", summary: "m",
            controls: MusicControls(features: [.planning, .score, .guidanceScale],
                                    planningModes: [.full, .melody, .off], maxDurationSeconds: 360))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let music = request as? MusicRequest else { throw PackageError.unsupportedCapability(request.capability) }
        return MusicResponse(audio: song, truncated: false,
                             score: music.score ?? "X:1\nT:planned(\(music.planning?.rawValue ?? "default"))\n")
    }
}

/// The ACE-Step 1.5 turbo shape: reference and source audio, anchors, languages, timestamps, no CFG.
@InferenceActor
private final class SourceEditingPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        musicManifest(surfaces: [MusicContract.descriptor(
            name: "ace-step-1.5-turbo", summary: "m",
            controls: MusicControls(features: [.referenceAudio, .sourceAudio, .anchors, .vocalLanguage, .timestamps],
                                    editModes: [.cover, .repaint],
                                    vocalLanguages: ["en", "ja"], maxDurationSeconds: 600))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let music = request as? MusicRequest else { throw PackageError.unsupportedCapability(request.capability) }
        return MusicResponse(audio: song, anchors: music.anchors,
                             timestamps: [MusicLyricTimestamp(text: music.edit?.operation.kind.rawValue ?? "none", start: 0)])
    }
}

/// A music surface built without the contract helper, so it declares nothing.
@InferenceActor
private final class BareMusicPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        musicManifest(surfaces: [ToolDescriptor(name: "bare-music", capability: .music, summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse { MusicResponse(audio: song) }
}

/// The MiniMax Music 3 shape, with its §3.1 display notice declared.
@InferenceActor
private final class NoticedMusicPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        musicManifest(
            surfaces: [MusicContract.descriptor(
                name: "minimax-music3", summary: "m",
                controls: MusicControls(features: [.guidanceScale], maxDurationSeconds: 300))],
            license: LicenseDeclaration(
                weightLicense: .minimaxMusic3Community, portCodeLicense: .mit,
                notices: [LicenseNotice(text: "MiniMax-Music3", display: .required,
                                        license: .minimaxMusic3Community)]))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse { MusicResponse(audio: song) }
}

// MARK: - Routing

// The new capability routes like any other, and a declared lever reaches the package intact.
@Test func aDeclaredScoreRoutesAndReachesThePackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScorePlanningPackage.self), configuration: mockConfig())
    let response = try await engine.run(MusicRequest(caption: "c", lyrics: "l", guidanceScale: 1.2,
                                                     planning: .full, score: "X:1\nK:C\nCDEF|"))
    let sung = try #require(response as? MusicResponse)
    #expect(sung.score == "X:1\nK:C\nCDEF|")
    #expect(sung.audio.sampleRate == 48_000 && sung.audio.channels == 2)

    let planned = try #require(try await engine.run(MusicRequest(caption: "c", lyrics: "l", planning: .melody))
                               as? MusicResponse)
    #expect(planned.score == "X:1\nT:planned(melody)\n")
}

@Test func theCoreRequestRunsOnEveryMusicSurface() async throws {
    for registration in [PackageRegistration.of(ScorePlanningPackage.self),
                         PackageRegistration.of(SourceEditingPackage.self),
                         PackageRegistration.of(BareMusicPackage.self),
                         PackageRegistration.of(NoticedMusicPackage.self)] {
        let engine = MLXServeEngine()
        try await engine.register(registration, configuration: mockConfig())
        let response = try await engine.run(MusicRequest(caption: "synthwave", lyrics: "[chorus]\nneon",
                                                         durationSeconds: 60, seed: 1, guidanceScale: 3))
        #expect(response is MusicResponse)
    }
}

// MARK: - Refusals, before admission

@Test func anUndeclaredSourceEditIsRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScorePlanningPackage.self), configuration: mockConfig())
    await #expect(throws: PackageError.self) {
        _ = try await engine.run(MusicRequest(
            caption: "c", lyrics: "l", edit: MusicEdit(source: clip, operation: .cover(strength: 0.5))))
    }
    do {
        _ = try await engine.run(MusicRequest(
            caption: "c", lyrics: "l", edit: MusicEdit(source: clip, operation: .cover(strength: 0.5))))
        Issue.record("an undeclared source edit reached the package")
    } catch {
        let detail = try #require(unsupportedFeature(error))
        #expect(detail.hasPrefix("edit(.cover) — this surface declares no source-clip editing"))
        #expect(detail.hasSuffix("[yue2-3b]"))
    }
}

@Test func anUndeclaredScoreOrPlanIsRefusedOnTheEditingSurface() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(SourceEditingPackage.self), configuration: mockConfig())
    do {
        _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", score: "X:1"))
        Issue.record("an undeclared score reached the package")
    } catch {
        #expect(unsupportedFeature(error)?.hasPrefix("score —") == true)
    }
    do {
        _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", planning: .off))
        Issue.record("an undeclared planning mode reached the package")
    } catch {
        #expect(unsupportedFeature(error)?.hasPrefix("planning(.off)") == true)
    }
}

// The check is per mode and per vocabulary entry: this surface covers and repaints but never extends,
// and sings in two languages.
@Test func modesAndLanguagesOutsideTheDeclaredVocabularyAreRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(SourceEditingPackage.self), configuration: mockConfig())

    let covered = try #require(try await engine.run(MusicRequest(
        caption: "c", lyrics: "l", edit: MusicEdit(source: clip, operation: .repaint(start: 10, end: 20)),
        anchors: MusicAnchors(bpm: 120), vocalLanguage: "JA")) as? MusicResponse)
    #expect(covered.timestamps?.first?.text == "repaint")
    #expect(covered.anchors?.bpm == 120)

    do {
        _ = try await engine.run(MusicRequest(
            caption: "c", lyrics: "l", edit: MusicEdit(source: clip, operation: .extend(trailing: 30))))
        Issue.record("an undeclared edit mode reached the package")
    } catch {
        #expect(unsupportedFeature(error)?.contains("editModes: cover / repaint") == true)
    }
    do {
        _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", vocalLanguage: "fr"))
        Issue.record("an undeclared language reached the package")
    } catch {
        #expect(unsupportedFeature(error)?.contains("vocalLanguages: en / ja") == true)
    }
}

@Test func aLengthPastTheDeclaredMaximumIsRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScorePlanningPackage.self), configuration: mockConfig())
    _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", durationSeconds: 360))
    do {
        _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", durationSeconds: 361))
        Issue.record("a too-long request reached the package")
    } catch {
        #expect(unsupportedFeature(error)?.hasPrefix("durationSeconds(361) — this surface renders at most 360 s") == true)
    }
}

// A music surface that declares nothing takes the core and nothing else — which is why the contract
// helper requires the declaration.
@Test func aBareMusicSurfaceTakesOnlyTheCore() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(BareMusicPackage.self), configuration: mockConfig())
    _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", guidanceScale: 2))
    do {
        _ = try await engine.run(MusicRequest(caption: "c", lyrics: "l", referenceAudio: clip, vocalLanguage: "en"))
        Issue.record("an undeclared feature reached a bare surface")
    } catch {
        let detail = try #require(unsupportedFeature(error))
        #expect(detail.hasPrefix("referenceAudio, vocalLanguage — "))
        #expect(detail.contains("MusicContract.descriptor(controls:)"))
    }
}

// MARK: - License notices

// MiniMax's license is allowlisted, so registering it records no advisory; its §3.1 string is declared.
@Test func aMiniMaxPackageWithItsDisplayNoticeRegistersClean() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(NoticedMusicPackage.self), configuration: mockConfig())
    #expect(await engine.licenseAdvisories.isEmpty)
    let manifest = NoticedMusicPackage.manifest
    #expect(manifest.license.requiredNotices.map(\.text) == ["MiniMax-Music3"])
    #expect(manifest.license.missingRequiredDisplayNotices.isEmpty)
    #expect(manifest.surfaces.first?.musicControls?.declarationProblems.isEmpty == true)
}
