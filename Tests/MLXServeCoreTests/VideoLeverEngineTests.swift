//
//  VideoLeverEngineTests.swift
//  MLXServeCoreTests
//
//  Contract 1.61.0 (AB-A-0236, MES Video 0.1) — the engine pre-flight for the video levers: a retake,
//  extend, keyframe, audio switch, content kind or target frame rate the surface does not declare is
//  refused before admission, a declared one reaches the package intact, a package that declares
//  nothing runs exactly as before, and a host-bound preview sink sees the frames a package reports.
//  Offline, mock packages.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private func videoManifest(_ surface: ToolDescriptor) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/video", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: [surface])
}

private func mockConfig() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/video") }

private func refusal(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

private let source = Video(format: .mp4, data: Data([1]), durationSeconds: 10, frameRate: 24,
                           width: 640, height: 360, frameCount: 240, audio: .noAudio)
private let result = Video(format: .mp4, data: Data([2]), durationSeconds: 12, frameRate: 24,
                           width: 640, height: 360, frameCount: 288,
                           audio: .present(sampleRate: 48_000, channels: 2))
private let still = Image(format: .png, data: Data([7]))

/// LTX-shaped video editor: retake (joint tracks), extend forward. Echoes what it was handed.
@InferenceActor
private final class DeclaringEditor: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        videoManifest(VEditContract.descriptor(
            name: "ltx-edit", summary: "m",
            controls: VEditControls(retakeModalities: [.both], extendDirections: [.after],
                                    spanUnits: [.seconds, .frames], maxExtendSeconds: 20)))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let edit = request as? VEditRequest else { throw PackageError.unsupportedCapability(request.capability) }
        // The span / extension reach the package typed, so it reads them rather than metaData.
        let marker = edit.retake.map { "retake:\($0.span.start)-\($0.span.end)" }
            ?? edit.extend.map { "extend:\($0.length)" } ?? "plain"
        return VEditResponse(video: Video(format: .mp4, data: Data(marker.utf8)))
    }
}

/// A pre-1.61 editor: the canonical descriptor with no controls.
@InferenceActor
private final class LegacyEditor: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        videoManifest(VEditContract.descriptor(name: "legacy-edit", summary: "m"))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        VEditResponse(video: result)
    }
}

/// LTX-shaped generator: keyframes anywhere, muxed audio, previews a stage-one frame.
@InferenceActor
private final class DeclaringGenerator: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        videoManifest(T2VContract.descriptor(
            name: "ltx-t2v", summary: "m",
            controls: T2VControls(keyframes: VideoKeyframeSupport(maxCount: 8, placement: .anyFrame,
                                                                  supportsStrength: true),
                                  audioOutput: .always, emitsFramePreviews: true)))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let t2v = request as? T2VRequest else { throw PackageError.unsupportedCapability(request.capability) }
        // A decoded stage-one frame, produced only because someone is listening.
        if RunProgress.wantsPreviews {
            RunProgress.reportPreview(RunPreviewFrame(image: still, atSeconds: 0.5, frameIndex: 12,
                                                      stage: 1, totalStages: 2))
        }
        return T2VResponse(video: Video(format: .mp4, data: Data("keyframes:\(t2v.keyframes.count)".utf8),
                                        frameCount: t2v.numFrames))
    }
}

/// A surface that declares nothing at all: a raw descriptor, as a pre-1.61 package built one.
@InferenceActor
private final class BareUpscaler: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        videoManifest(VideoUpscaleContract.descriptor(name: "bare-up", summary: "m"))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        VideoUpscaleResponse(video: result, appliedScale: 2)
    }
}

@InferenceActor
private final class DeclaringUpscaler: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        videoManifest(VideoUpscaleContract.descriptor(
            name: "anime-up", summary: "m", controls: VideoUpscaleControls(contents: [.drawn])))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        VideoUpscaleResponse(video: result, appliedScale: 4)
    }
}

@InferenceActor
private final class RifePackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        videoManifest(FrameInterpolateContract.descriptor(
            name: "rife", summary: "m",
            controls: FrameInterpolateControls(targetFrameRate: TargetFrameRateSupport(ratios: .any))))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let request = request as? FrameInterpolateRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        let rate = request.targetFrameRate ?? 48
        return FrameInterpolateResponse(video: result, appliedFactor: Int((rate / 24).rounded()),
                                        appliedFrameRate: rate)
    }
}

// MARK: - A package that declares nothing behaves exactly as before

@Test func aLegacyEditorRunsEveryPre161RequestAndRefusesTheNewLevers() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(LegacyEditor.self), configuration: mockConfig())
    #expect(try await engine.run(VEditRequest(video: source, prompt: "p", steps: 8, seed: 1)) is VEditResponse)

    do {
        _ = try await engine.run(VEditRequest(video: source, prompt: "p",
                                              retake: VideoRetake(span: .seconds(2, 4))))
        Issue.record("an undeclared retake reached the package")
    } catch {
        let detail = try #require(refusal(error))
        #expect(detail.hasPrefix("retake — this surface declares no retake"))
        #expect(detail.hasSuffix("[legacy-edit]"))
    }
    do {
        _ = try await engine.run(VEditRequest(video: source, prompt: "p", extend: .seconds(2)))
        Issue.record("an undeclared extend reached the package")
    } catch {
        #expect(refusal(error)?.hasPrefix("extend —") == true)
    }
}

@Test func aBareUpscalerRunsUntilItIsToldTheContent() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(BareUpscaler.self), configuration: mockConfig())
    #expect(try await engine.run(VideoUpscaleRequest(video: source, scale: 2)) is VideoUpscaleResponse)
    do {
        _ = try await engine.run(VideoUpscaleRequest(video: source, scale: 2, content: .liveAction))
        Issue.record("an undeclared content kind reached the package")
    } catch {
        #expect(refusal(error)?.hasPrefix("content(.liveAction) — this surface declares no content control") == true)
    }
}

// MARK: - Declared levers reach the package typed

@Test func aDeclaredRetakeAndExtendReachThePackageTyped() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DeclaringEditor.self), configuration: mockConfig())

    let retaken = try #require(try await engine.run(VEditRequest(
        video: source, prompt: "p", retake: VideoRetake(span: .seconds(2, 4)))) as? VEditResponse)
    #expect(String(decoding: retaken.video.data, as: UTF8.self) == "retake:2.0-4.0")

    let frames = try #require(try await engine.run(VEditRequest(
        video: source, prompt: "p", retake: VideoRetake(span: .frames(24, 48)))) as? VEditResponse)
    #expect(String(decoding: frames.video.data, as: UTF8.self) == "retake:24.0-48.0")

    let extended = try #require(try await engine.run(VEditRequest(
        video: source, prompt: "p", extend: .seconds(5))) as? VEditResponse)
    #expect(String(decoding: extended.video.data, as: UTF8.self) == "extend:5.0")
}

@Test func levers_outsideTheDeclarationAreRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DeclaringEditor.self), configuration: mockConfig())
    let cases: [(VEditRequest, String)] = [
        (VEditRequest(video: source, prompt: "p", retake: VideoRetake(span: .seconds(2, 4), modality: .sound)),
         "retake.modality(.sound)"),
        (VEditRequest(video: source, prompt: "p", extend: .seconds(2, direction: .before)),
         "extend.direction(.before)"),
        (VEditRequest(video: source, prompt: "p", extend: .seconds(40)), "extend.length(40 s)"),
        (VEditRequest(video: source, prompt: "p", retake: VideoRetake(span: .seconds(8, 14))),
         "retake.span — ends at"),
        (VEditRequest(video: source, prompt: "p", retake: VideoRetake(span: .seconds(1, 2)),
                      extend: .seconds(2)), "retake and extend"),
    ]
    for (request, prefix) in cases {
        do {
            _ = try await engine.run(request)
            Issue.record("\(prefix) reached the package")
        } catch {
            let detail = try #require(refusal(error))
            #expect(detail.hasPrefix(prefix), "\(detail)")
            #expect(detail.hasSuffix("[ltx-edit]"))
        }
    }
}

@Test func keyframesAndTheAudioSwitchAreGatedByTheDeclaration() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DeclaringGenerator.self), configuration: mockConfig())

    let ok = try #require(try await engine.run(T2VRequest(
        prompt: "p", initImage: still,
        keyframes: [VideoKeyframe(image: still, frame: 48, strength: 0.6), .last(still)],
        includeAudio: true, numFrames: 97)) as? T2VResponse)
    #expect(String(decoding: ok.video.data, as: UTF8.self) == "keyframes:2")
    #expect(ok.video.frameCount == 97)

    // LTX muxes its audio: asking to drop it is refused rather than silently ignored.
    do {
        _ = try await engine.run(T2VRequest(prompt: "p", includeAudio: false))
        Issue.record("includeAudio(false) reached an always-muxed package")
    } catch {
        #expect(refusal(error)?.hasPrefix("includeAudio(false)") == true)
    }
    // Two keyframes on one frame.
    do {
        _ = try await engine.run(T2VRequest(
            prompt: "p", keyframes: [VideoKeyframe(image: still, frame: 8), VideoKeyframe(image: still, frame: 8)]))
        Issue.record("duplicate keyframes reached the package")
    } catch {
        #expect(refusal(error)?.contains("same frame") == true)
    }
    // The request every earlier host sends runs untouched.
    #expect(try await engine.run(T2VRequest(prompt: "p", numFrames: 49, seed: 3)) is T2VResponse)
}

@Test func contentAndTargetFrameRateAreGatedByTheDeclaration() async throws {
    let anime = MLXServeEngine()
    try await anime.register(PackageRegistration.of(DeclaringUpscaler.self), configuration: mockConfig())
    #expect(try await anime.run(VideoUpscaleRequest(video: source, content: .drawn)) is VideoUpscaleResponse)
    do {
        _ = try await anime.run(VideoUpscaleRequest(video: source, content: .liveAction))
        Issue.record("an undeclared content kind reached the upscaler")
    } catch {
        #expect(refusal(error)?.contains("contents: drawn") == true)
    }

    let rife = MLXServeEngine()
    try await rife.register(PackageRegistration.of(RifePackage.self), configuration: mockConfig())
    let retimed = try #require(try await rife.run(
        FrameInterpolateRequest(video: source, targetFrameRate: 60)) as? FrameInterpolateResponse)
    #expect(retimed.appliedFrameRate == 60 && retimed.appliedFactor == 3)   // 2.5 rounds to 3
    do {
        _ = try await rife.run(FrameInterpolateRequest(video: source, factor: 2, targetFrameRate: 60))
        Issue.record("factor and targetFrameRate together reached the package")
    } catch {
        #expect(refusal(error)?.contains("one or the other") == true)
    }
}

// MARK: - Preview hook

private final class PreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [RunPreviewFrame] = []
    func append(_ frame: RunPreviewFrame) { lock.withLock { _frames.append(frame) } }
    var frames: [RunPreviewFrame] { lock.withLock { _frames } }
}

// The host's own sink, bound around engine.run, is the one the package reports to — the engine does
// not rebind it, so a frame reaches the host without a hop through the run monitor.
@Test func aHostBoundPreviewSinkSeesTheFramesAPackageReports() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DeclaringGenerator.self), configuration: mockConfig())
    let log = PreviewLog()
    _ = try await RunProgress.$previewSink.withValue({ log.append($0) }) {
        try await engine.run(T2VRequest(prompt: "p"))
    }
    #expect(log.frames == [RunPreviewFrame(image: still, atSeconds: 0.5, frameIndex: 12,
                                           stage: 1, totalStages: 2)])
}

@Test func withNoSinkBoundThePackageIsToldNobodyIsListening() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(DeclaringGenerator.self), configuration: mockConfig())
    // No sink: `wantsPreviews` is false inside the run, so the package skips the decode. Nothing to
    // observe except that the run completes — the log from the previous test is not shared.
    #expect(try await engine.run(T2VRequest(prompt: "p")) is T2VResponse)
    #expect(!RunProgress.wantsPreviews)
}
