//
//  VideoControlsTests.swift
//  MLXToolKitTests
//
//  Contract 1.61.0 (AB-A-0236, MES Video 0.1) — typed retake / extend, keyframes and an audio switch,
//  upscale content, a target frame rate, facts on `Video`, and the preview hook. Checks the refusal
//  rule of each lever, that a surface declaring nothing refuses every new lever and nothing else, that
//  descriptors advertise only what they declare, and that pre-1.61 JSON decodes unchanged.
//

import XCTest
@testable import MLXToolKit

final class VideoControlsTests: XCTestCase {

    private let source = Video(format: .mp4, data: Data([1, 2, 3]), durationSeconds: 10, frameRate: 24,
                               width: 1280, height: 720, frameCount: 240,
                               audio: .present(sampleRate: 48_000, channels: 2))
    private let still = Image(format: .png, data: Data([9, 9]))

    // MARK: videoEdit

    // The LTX shape: joint audio-video latent (so only `both`), extends forward, seconds and frames.
    private let ltxEdit = VEditControls(retakeModalities: [.both], extendDirections: [.after],
                                        spanUnits: [.seconds, .frames], maxExtendSeconds: 20)

    func testNothingDeclaredRefusesRetakeAndExtendButNotTheOldRequest() {
        let none = VEditControls()
        XCTAssertNil(none.refusal(for: VEditRequest(video: source, prompt: "p", seed: 1)))
        XCTAssertTrue(none.refusal(for: VEditRequest(
            video: source, prompt: "p", retake: VideoRetake(span: .seconds(1, 2))))!.hasPrefix("retake — "))
        XCTAssertTrue(none.refusal(for: VEditRequest(
            video: source, prompt: "p", extend: .seconds(2)))!.hasPrefix("extend — "))
        XCTAssertTrue(none.declarationProblems.isEmpty)
    }

    func testRetakeIsRefusedOutsideItsDeclaration() {
        func refusal(_ retake: VideoRetake, _ controls: VEditControls? = nil) -> String? {
            (controls ?? ltxEdit).refusal(for: VEditRequest(video: source, prompt: "p", retake: retake))
        }
        XCTAssertNil(refusal(VideoRetake(span: .seconds(2, 4))))
        XCTAssertNil(refusal(VideoRetake(span: .frames(48, 96))))
        // Picture only, on a surface whose tracks are joint.
        XCTAssertTrue(refusal(VideoRetake(span: .seconds(2, 4), modality: .picture))!
            .contains("retakeModalities: both"))
        // Frames on a seconds-only surface.
        let secondsOnly = VEditControls(retakeModalities: [.both])
        XCTAssertTrue(refusal(VideoRetake(span: .frames(0, 8)), secondsOnly)!.contains("spanUnits: seconds"))
        // Malformed spans, before anything about the package.
        XCTAssertNotNil(refusal(VideoRetake(span: .seconds(4, 4))))
        XCTAssertNotNil(refusal(VideoRetake(span: .seconds(-1, 2))))
        XCTAssertNotNil(refusal(VideoRetake(span: VideoSpan(start: 0.5, end: 8, unit: .frames))))
        // Past the source's end — by seconds and by frames, judged from the source's own facts.
        XCTAssertTrue(refusal(VideoRetake(span: .seconds(8, 12)))!.contains("past the end"))
        XCTAssertTrue(refusal(VideoRetake(span: .frames(200, 300)))!.contains("frame 300 of 240"))
        // An unstated source judges nothing.
        let unstated = Video(format: .mp4, data: Data([1]))
        XCTAssertNil(ltxEdit.refusal(for: VEditRequest(video: unstated, prompt: "p",
                                                       retake: VideoRetake(span: .seconds(500, 600)))))
    }

    func testPictureOrSoundRetakeIsAdmittedWhereDeclared() {
        let separable = VEditControls(retakeModalities: [.picture, .sound, .both])
        for modality in VideoModality.allCases {
            XCTAssertNil(separable.refusal(for: VEditRequest(
                video: source, prompt: "p", retake: VideoRetake(span: .seconds(1, 3), modality: modality))))
        }
    }

    func testExtendIsRefusedOutsideItsDeclaration() {
        func refusal(_ extend: VideoExtend) -> String? {
            ltxEdit.refusal(for: VEditRequest(video: source, prompt: "p", extend: extend))
        }
        XCTAssertNil(refusal(.seconds(8)))
        XCTAssertNil(refusal(VideoExtend(length: 48, unit: .frames)))
        XCTAssertTrue(refusal(.seconds(4, direction: .before))!.contains("extendDirections: after"))
        XCTAssertNotNil(refusal(.seconds(0)))
        XCTAssertNotNil(refusal(.seconds(.infinity)))
        XCTAssertTrue(refusal(.seconds(30))!.contains("at most 20 s"))
        // 600 frames at the source's 24 fps is 25 s.
        XCTAssertTrue(refusal(VideoExtend(length: 600, unit: .frames))!.contains("at most 20 s"))
    }

    func testRetakeAndExtendTogetherAreRefusedWhateverIsDeclared() {
        let reason = ltxEdit.refusal(for: VEditRequest(
            video: source, prompt: "p", retake: VideoRetake(span: .seconds(1, 2)), extend: .seconds(2)))
        XCTAssertEqual(reason?.hasPrefix("retake and extend"), true)
    }

    func testVEditDeclarationProblems() {
        XCTAssertTrue(ltxEdit.declarationProblems.isEmpty)
        XCTAssertFalse(VEditControls(retakeModalities: [.both], spanUnits: [.frames]).declarationProblems.isEmpty)
        XCTAssertFalse(VEditControls(maxExtendSeconds: 5).declarationProblems.isEmpty)
        XCTAssertFalse(VEditControls(extendDirections: [.after], maxExtendSeconds: 0).declarationProblems.isEmpty)
    }

    func testVEditDescriptorAdvertisesOnlyWhatIsDeclared() throws {
        let bare = VEditContract.descriptor(name: "e", summary: "s")
        XCTAssertNil(bare.controls)
        XCTAssertFalse(bare.parameters.contains { $0.name == "retake" || $0.name == "extend" })
        XCTAssertEqual(bare.parameters.count, 11, "the pre-1.61 parameter list is unchanged")

        let retakeOnly = VEditContract.descriptor(
            name: "e", summary: "s", controls: VEditControls(retakeModalities: [.picture, .both]))
        XCTAssertEqual(retakeOnly.videoEditControls?.declaresRetake, true)
        XCTAssertTrue(retakeOnly.parameters.contains { $0.name == "retake" && $0.kind == .object })
        XCTAssertFalse(retakeOnly.parameters.contains { $0.name == "extend" })
        XCTAssertTrue(retakeOnly.controlsMatchCapability)

        let both = VEditContract.descriptor(name: "e", summary: "s", controls: ltxEdit)
        XCTAssertTrue(both.parameters.contains { $0.name == "extend" })
        XCTAssertTrue(try XCTUnwrap(both.parameters.first { $0.name == "extend" }?.summary).contains("up to 20 s"))
    }

    // MARK: textToVideo

    private let ltxT2V = T2VControls(supportsInitAudio: true,
                                     keyframes: VideoKeyframeSupport(maxCount: 8, placement: .anyFrame,
                                                                     supportsStrength: true),
                                     audioOutput: .always, emitsFramePreviews: true)
    private let firstLast = T2VControls(keyframes: VideoKeyframeSupport(maxCount: 2, placement: .endpoints),
                                        audioOutput: .silent)

    func testNothingDeclaredRefusesKeyframesAndTheAudioSwitchButNotTheOldRequest() {
        let none = T2VControls()
        XCTAssertNil(none.refusal(for: T2VRequest(prompt: "p", initImage: still, numFrames: 49, seed: 1)))
        XCTAssertTrue(none.refusal(for: T2VRequest(
            prompt: "p", keyframes: [VideoKeyframe(image: still, frame: 0)]))!.hasPrefix("keyframes — "))
        XCTAssertTrue(none.refusal(for: T2VRequest(prompt: "p", includeAudio: false))!
            .hasPrefix("includeAudio — "))
    }

    func testKeyframePlacementCountAndStrength() {
        func refusal(_ frames: [VideoKeyframe], numFrames: Int? = nil,
                     _ controls: T2VControls? = nil) -> String? {
            (controls ?? ltxT2V).refusal(for: T2VRequest(prompt: "p", keyframes: frames, numFrames: numFrames))
        }
        func kf(_ frame: Int, _ strength: Double? = nil) -> VideoKeyframe {
            VideoKeyframe(image: still, frame: frame, strength: strength)
        }
        XCTAssertNil(refusal([kf(0, 1), kf(48, 0.6), .last(still, strength: 0.8)]))
        XCTAssertNil(refusal([kf(0), .last(still)], firstLast))
        // An interior frame on an endpoints surface.
        XCTAssertTrue(refusal([kf(24)], firstLast)!.contains("first (0) and last (-1)"))
        // Over the count.
        XCTAssertTrue(refusal([kf(0), kf(8), .last(still)], firstLast)!.contains("at most 2"))
        // Strength where undeclared, and outside 0…1 where declared.
        XCTAssertTrue(refusal([kf(0, 0.5)], firstLast)!.contains("supportsStrength"))
        XCTAssertTrue(refusal([kf(0, 1.5)])!.contains("0…1"))
        // The same frame twice, literally and once the count resolves -1.
        XCTAssertTrue(refusal([kf(8), kf(8)])!.contains("same frame"))
        XCTAssertTrue(refusal([kf(48), .last(still)], numFrames: 49)!.contains("same frame"))
        // Outside the frames requested.
        XCTAssertTrue(refusal([kf(60)], numFrames: 49)!.contains("outside the 49 frames"))
        XCTAssertTrue(refusal([kf(-60)], numFrames: 49)!.contains("outside the 49 frames"))
    }

    func testAKeyframeAndAnInitImageMayNotBothPinFrameZero() {
        let request = T2VRequest(prompt: "p", initImage: still,
                                 keyframes: [VideoKeyframe(image: still, frame: 0)])
        XCTAssertTrue(ltxT2V.refusal(for: request)!.contains("name it once"))
        // First image plus a last-frame keyframe is the ordinary first/last-frame request.
        XCTAssertNil(ltxT2V.refusal(for: T2VRequest(prompt: "p", initImage: still, keyframes: [.last(still)])))
    }

    func testResolvedFrame() {
        XCTAssertEqual(VideoKeyframe(image: still, frame: 5).resolvedFrame(in: 49), 5)
        XCTAssertEqual(VideoKeyframe.last(still).resolvedFrame(in: 49), 48)
        XCTAssertEqual(VideoKeyframe(image: still, frame: -2).resolvedFrame(in: 49), 47)
        XCTAssertNil(VideoKeyframe(image: still, frame: 49).resolvedFrame(in: 49))
        XCTAssertNil(VideoKeyframe(image: still, frame: -50).resolvedFrame(in: 49))
    }

    func testTheAudioSwitchFollowsTheDeclaredOutput() {
        func refusal(_ include: Bool, _ output: VideoAudioOutput?) -> String? {
            T2VControls(audioOutput: output).refusal(for: T2VRequest(prompt: "p", includeAudio: include))
        }
        XCTAssertNil(refusal(true, .switchable))
        XCTAssertNil(refusal(false, .switchable))
        XCTAssertNil(refusal(true, .always))      // LTX muxes: asking for what it does is fine
        XCTAssertNotNil(refusal(false, .always))  // …but not for what it cannot do
        XCTAssertNil(refusal(false, .silent))
        XCTAssertNotNil(refusal(true, .silent))
        XCTAssertNotNil(refusal(true, nil))
        // Not asking is never refused, whatever the declaration.
        XCTAssertNil(T2VControls(audioOutput: .always).refusal(for: T2VRequest(prompt: "p")))
    }

    func testT2VDescriptorAdvertisesOnlyWhatIsDeclared() {
        let plain = T2VContract.descriptor(name: "g", summary: "s")
        XCTAssertFalse(plain.parameters.contains { $0.name == "keyframes" || $0.name == "includeAudio" })
        // An always-muxed surface has nothing to switch, so it offers keyframes only.
        let ltx = T2VContract.descriptor(name: "g", summary: "s", controls: ltxT2V)
        XCTAssertTrue(ltx.parameters.contains { $0.name == "keyframes" && $0.kind == .array })
        XCTAssertFalse(ltx.parameters.contains { $0.name == "includeAudio" })
        let switchable = T2VContract.descriptor(name: "g", summary: "s",
                                                controls: T2VControls(audioOutput: .switchable))
        XCTAssertTrue(switchable.parameters.contains { $0.name == "includeAudio" && $0.kind == .boolean })
        XCTAssertFalse(switchable.parameters.contains { $0.name == "keyframes" })
        XCTAssertTrue(ltxT2V.declarationProblems.isEmpty)
        XCTAssertFalse(T2VControls(keyframes: VideoKeyframeSupport(maxCount: 4, placement: .endpoints))
            .declarationProblems.isEmpty)
    }

    // MARK: videoUpscale / frameInterpolate

    func testUpscaleContentIsDeclarationGated() {
        let request = VideoUpscaleRequest(video: source, scale: 2, content: .drawn)
        XCTAssertNil(VideoUpscaleControls().refusal(for: VideoUpscaleRequest(video: source, scale: 2)))
        XCTAssertTrue(VideoUpscaleControls().refusal(for: request)!.contains("declares no content control"))
        XCTAssertTrue(VideoUpscaleControls(contents: [.liveAction]).refusal(for: request)!
            .contains("contents: liveAction"))
        XCTAssertNil(VideoUpscaleControls(contents: [.liveAction, .drawn]).refusal(for: request))

        let none = VideoUpscaleContract.descriptor(name: "u", summary: "s")
        XCTAssertFalse(none.parameters.contains { $0.name == "content" })
        let both = VideoUpscaleContract.descriptor(
            name: "u", summary: "s", controls: VideoUpscaleControls(contents: [.liveAction, .drawn]))
        XCTAssertTrue(both.parameters.contains { $0.name == "content" })
        XCTAssertEqual(both.videoUpscaleControls?.contents, [.liveAction, .drawn])
        XCTAssertTrue(both.controlsMatchCapability)
    }

    func testTargetFrameRate() {
        func refusal(_ rate: Double, factor: Int? = nil, _ controls: FrameInterpolateControls,
                     video: Video? = nil) -> String? {
            controls.refusal(for: FrameInterpolateRequest(video: video ?? source, factor: factor,
                                                          targetFrameRate: rate))
        }
        let rife = FrameInterpolateControls(targetFrameRate: TargetFrameRateSupport(ratios: .any, maxFrameRate: 120))
        let multiples = FrameInterpolateControls(
            targetFrameRate: TargetFrameRateSupport(ratios: .integerMultiples))
        XCTAssertNil(FrameInterpolateControls().refusal(for: FrameInterpolateRequest(video: source, factor: 2)))
        XCTAssertTrue(refusal(60, FrameInterpolateControls())!.contains("declares no target frame rate"))
        XCTAssertNil(refusal(60, rife))               // 24 → 60: not a multiple, RIFE takes it
        XCTAssertNil(refusal(48, multiples))
        XCTAssertTrue(refusal(60, multiples)!.contains("whole multiple"))
        XCTAssertTrue(refusal(12, rife)!.contains("raises the rate"))
        XCTAssertTrue(refusal(240, rife)!.contains("at most 120"))
        XCTAssertNotNil(refusal(0, rife))
        XCTAssertNotNil(refusal(.nan, rife))
        XCTAssertTrue(refusal(48, factor: 2, rife)!.contains("one or the other"))
        // A source that states no rate cannot be judged for ratio or direction; the package does.
        XCTAssertNil(refusal(60, multiples, video: Video(format: .mp4, data: Data([1]))))

        let advertised = FrameInterpolateContract.descriptor(name: "i", summary: "s", controls: rife)
        XCTAssertTrue(advertised.parameters.contains { $0.name == "targetFrameRate" })
        XCTAssertFalse(FrameInterpolateContract.descriptor(name: "i", summary: "s").parameters
            .contains { $0.name == "targetFrameRate" })
        XCTAssertTrue(advertised.controlsMatchCapability)
    }

    func testControlsMustMatchTheSurfaceCapability() {
        XCTAssertFalse(ToolDescriptor(name: "x", capability: .tts, summary: "s",
                                      controls: .videoEdit(ltxEdit)).controlsMatchCapability)
        XCTAssertFalse(ToolDescriptor(name: "x", capability: .videoEdit, summary: "s",
                                      controls: .frameInterpolate(FrameInterpolateControls()))
            .controlsMatchCapability)
    }

    // MARK: Video facts and wire shapes

    func testVideoFactsRoundTripAndAreOptional() throws {
        let old = Video(format: .mp4, data: Data([1]), durationSeconds: 2, frameRate: 24)
        XCTAssertNil(old.width); XCTAssertNil(old.frameCount); XCTAssertNil(old.audio)

        let decoded = try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.audio, .present(sampleRate: 48_000, channels: 2))

        // "none" and "unknown" differ.
        let silent = Video(format: .mp4, data: Data([1]), audio: .noAudio)
        let roundTripped = try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(silent))
        XCTAssertEqual(roundTripped.audio, VideoAudioFacts.noAudio)
        XCTAssertEqual(roundTripped.audio?.hasAudio, false)
        XCTAssertNil(try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(old)).audio)
    }

    func testPre161VideoJSONDecodes() throws {
        let json = #"{"format":"mp4","data":"AQID","durationSeconds":1.5,"frameRate":24}"#
        let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
        XCTAssertEqual(video.data, Data([1, 2, 3]))
        XCTAssertEqual(video.frameRate, 24)
        XCTAssertNil(video.width); XCTAssertNil(video.height)
        XCTAssertNil(video.frameCount); XCTAssertNil(video.audio)
    }

    func testVideoFactsSurviveTheArtifactSpool() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = ArtifactSpool(directory: directory)

        let encoder = JSONEncoder()
        encoder.userInfo[ArtifactSpool.userInfoKey] = spool
        let encoded = try encoder.encode(source)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"file\""), "the bytes travel as a file")
        XCTAssertTrue(text.contains("\"frameCount\":240") && text.contains("\"sampleRate\":48000"))
        let decoder = JSONDecoder()
        decoder.userInfo[ArtifactSpool.userInfoKey] = spool
        XCTAssertEqual(try decoder.decode(Video.self, from: encoded), source)
    }

    func testPre161RequestAndControlsJSONDecode() throws {
        // A 1.53–1.60 T2VRequest: no keyframes, no includeAudio.
        let t2v = #"{"prompt":"p","numFrames":49,"adapters":[],"resolvedAdapters":[],"metaData":{}}"#
        let request = try JSONDecoder().decode(T2VRequest.self, from: Data(t2v.utf8))
        XCTAssertEqual(request.numFrames, 49)
        XCTAssertTrue(request.keyframes.isEmpty)
        XCTAssertNil(request.includeAudio)
        // …and a pre-1.53 one, which carried no adapters either.
        XCTAssertTrue(try JSONDecoder().decode(T2VRequest.self, from: Data(#"{"prompt":"p"}"#.utf8))
            .adapters.isEmpty)

        let edit = try JSONDecoder().decode(VEditRequest.self, from: JSONEncoder().encode(
            VEditRequest(video: source, prompt: "p")))
        XCTAssertNil(edit.retake); XCTAssertNil(edit.extend)

        // A 1.40 descriptor's controls block: supportsInitAudio only.
        let controls = try JSONDecoder().decode(T2VControls.self, from: Data(#"{"supportsInitAudio":true}"#.utf8))
        XCTAssertTrue(controls.supportsInitAudio)
        XCTAssertNil(controls.keyframes); XCTAssertNil(controls.audioOutput)
        XCTAssertFalse(controls.emitsFramePreviews)
    }

    func testNewRequestsRoundTrip() throws {
        let t2v = T2VRequest(prompt: "p",
                             keyframes: [VideoKeyframe(image: still, frame: 0, strength: 1), .last(still)],
                             includeAudio: false, numFrames: 49)
        XCTAssertEqual(try JSONDecoder().decode(T2VRequest.self, from: JSONEncoder().encode(t2v)).keyframes,
                       t2v.keyframes)
        let decodedT2V = try JSONDecoder().decode(T2VRequest.self, from: JSONEncoder().encode(t2v))
        XCTAssertEqual(decodedT2V.includeAudio, false)

        let edit = VEditRequest(video: source, prompt: "p",
                                retake: VideoRetake(span: .frames(24, 72), modality: .picture))
        let decodedEdit = try JSONDecoder().decode(VEditRequest.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(decodedEdit.retake, edit.retake)

        let extend = VEditRequest(video: source, prompt: "p", extend: .seconds(5, direction: .before))
        XCTAssertEqual(try JSONDecoder().decode(VEditRequest.self, from: JSONEncoder().encode(extend)).extend,
                       extend.extend)

        // A span with no unit, and a retake with no modality, take their defaults.
        let span = try JSONDecoder().decode(VideoRetake.self, from: Data(#"{"span":{"start":1,"end":3}}"#.utf8))
        XCTAssertEqual(span, VideoRetake(span: .seconds(1, 3), modality: .both))

        let interpolate = FrameInterpolateRequest(video: source, targetFrameRate: 60)
        XCTAssertEqual(try JSONDecoder().decode(FrameInterpolateRequest.self,
                                                from: JSONEncoder().encode(interpolate)).targetFrameRate, 60)
        let upscale = VideoUpscaleRequest(video: source, scale: 2, content: .liveAction)
        XCTAssertEqual(try JSONDecoder().decode(VideoUpscaleRequest.self,
                                                from: JSONEncoder().encode(upscale)).content, .liveAction)
        // The response states the rate; an older response without it still decodes.
        let response = FrameInterpolateResponse(video: source, appliedFactor: 3, appliedFrameRate: 60)
        XCTAssertEqual(try JSONDecoder().decode(FrameInterpolateResponse.self,
                                                from: JSONEncoder().encode(response)).appliedFrameRate, 60)
        let legacy = try JSONEncoder().encode(FrameInterpolateResponse(video: source, appliedFactor: 2))
        XCTAssertNil(try JSONDecoder().decode(FrameInterpolateResponse.self, from: legacy).appliedFrameRate)
    }

    func testSurfaceControlsRoundTripThroughTheDescriptor() throws {
        for descriptor in [
            VEditContract.descriptor(name: "e", summary: "s", controls: ltxEdit),
            T2VContract.descriptor(name: "g", summary: "s", controls: ltxT2V),
            VideoUpscaleContract.descriptor(name: "u", summary: "s",
                                            controls: VideoUpscaleControls(contents: [.drawn], emitsFramePreviews: true)),
            FrameInterpolateContract.descriptor(name: "i", summary: "s", controls: FrameInterpolateControls(
                targetFrameRate: TargetFrameRateSupport(ratios: .any, maxFrameRate: 120))),
        ] {
            let decoded = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(descriptor))
            XCTAssertEqual(decoded, descriptor)
        }
    }

    // MARK: Preview hook

    func testPreviewFramesReachABoundSinkAndAreNoOpsOtherwise() async {
        XCTAssertFalse(RunProgress.wantsPreviews)
        RunProgress.reportPreview(RunPreviewFrame(image: still, atSeconds: 0))   // harmless unbound

        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [RunPreviewFrame] = []
            func append(_ frame: RunPreviewFrame) { lock.withLock { frames.append(frame) } }
            var all: [RunPreviewFrame] { lock.withLock { frames } }
        }
        let log = Log()
        let sawListener = await RunProgress.$previewSink.withValue({ log.append($0) }) {
            let listening = RunProgress.wantsPreviews
            RunProgress.reportPreview(RunPreviewFrame(image: still, atSeconds: 0.5, frameIndex: 12,
                                                      stage: 1, totalStages: 2))
            return listening
        }
        XCTAssertTrue(sawListener)
        XCTAssertEqual(log.all, [RunPreviewFrame(image: still, atSeconds: 0.5, frameIndex: 12,
                                                 stage: 1, totalStages: 2)])
        XCTAssertFalse(RunProgress.wantsPreviews)
    }

    func testPreviewFrameCodableRoundTrip() throws {
        let frame = RunPreviewFrame(image: still, atSeconds: 1.25, frameIndex: 30, stage: 1, totalStages: 2)
        XCTAssertEqual(try JSONDecoder().decode(RunPreviewFrame.self, from: JSONEncoder().encode(frame)), frame)
    }
}
