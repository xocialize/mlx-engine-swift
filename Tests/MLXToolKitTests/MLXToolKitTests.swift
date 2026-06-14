import XCTest
@testable import MLXToolKit

final class MLXToolKitTests: XCTestCase {

    func testContractVersionIsV1_4() {
        XCTAssertEqual(ContractVersion.current, SemanticVersion(major: 1, minor: 4, patch: 0))
    }

    // 1.4.0 additive: talkingHead (source face video + driving audio -> re-lip-synced video).
    // Introduced by MuseTalk.
    func testTalkingHeadCapability() {
        XCTAssertEqual(TalkingHeadRequest.capability, .talkingHead)
        XCTAssertEqual(Capability.talkingHead.canonicalOutput, .video)
        let d = TalkingHeadContract.descriptor(name: "x", summary: "y")
        XCTAssertEqual(d.capability, .talkingHead)
        XCTAssertTrue(d.parameters.contains { $0.name == "source" && $0.kind == .video && $0.required })
        XCTAssertTrue(d.parameters.contains { $0.name == "audio" && $0.kind == .audio && $0.required })
    }

    // 1.3.0 additive: videoEdit (source video + optional refs + prompt -> edited video) +
    // T2VRequest.referenceImages (reference-to-video generation). Introduced by Bernini-R.
    func testVideoEditCapability() {
        XCTAssertEqual(VEditRequest.capability, .videoEdit)
        XCTAssertEqual(Capability.videoEdit.canonicalOutput, .video)
        let d = VEditContract.descriptor(name: "x", summary: "y")
        XCTAssertEqual(d.capability, .videoEdit)
        XCTAssertTrue(d.parameters.contains { $0.name == "video" && $0.required })
        // referenceImages is a canonical T2V field now (r2v).
        let t2v = T2VRequest(prompt: "p", referenceImages: [])
        XCTAssertNotNil(t2v.referenceImages)
    }

    // 1.2.0 additive: the soundEffect capability (text -> SFX audio; first package:
    // mlx-moss-soundeffect-swift over MOSS-SoundEffect-v2.0).
    func testSoundEffectContractAndIO() {
        let req = SoundEffectRequest(
            prompt: "a heavy wooden door creaks open slowly",
            durationSeconds: 5, steps: 100, guidanceScale: 4.0, seed: 42)
        XCTAssertEqual(SoundEffectRequest.capability, .soundEffect)
        XCTAssertEqual(Capability.soundEffect.canonicalOutput, .audio)
        XCTAssertEqual(req.durationSeconds, 5)

        let audio = Audio(data: Data([0x52, 0x49, 0x46, 0x46]), sampleRate: 48_000, channels: 1)
        let resp = SoundEffectResponse(audio: audio)
        XCTAssertEqual(resp.audio.sampleRate, 48_000)

        let d = SoundEffectContract.descriptor(name: "moss-sfx", summary: "Text to sound effect")
        XCTAssertEqual(d.capability, .soundEffect)
        XCTAssertEqual(d.parameters.first?.name, "prompt")
        XCTAssertTrue(d.parameters.contains { $0.name == "durationSeconds" })
    }

    // 1.1.0 additive: the ICL-cloning transcript is canonical (promoted from metaData when the
    // second TTS package needed it) and defaults to nil so 1.0.0-era call sites are unaffected.
    func testTTSReferenceTranscriptIsAdditive() {
        let legacy = TTSRequest(text: "hello")
        XCTAssertNil(legacy.referenceTranscript)

        let icl = TTSRequest(text: "hello",
                             voice: VoiceSelector(.referenceAudio(Audio(data: Data()))),
                             referenceTranscript: "reference transcript")
        XCTAssertEqual(icl.referenceTranscript, "reference transcript")

        // The descriptor exposes it for MCPBridge introspection (C11).
        let descriptor = TTSContract.descriptor(name: "t", summary: "s")
        XCTAssertTrue(descriptor.parameters.contains { $0.name == "referenceTranscript" })
    }

    // 1.1.0 additive: 5/6-bit quants (mlx-community ships them broadly).
    func testInt5Int6QuantsExist() {
        XCTAssertEqual(Quant.int5.rawValue, "int5")
        XCTAssertEqual(Quant.int6.rawValue, "int6")
        XCTAssertTrue(Quant.allCases.contains(.int5))
        XCTAssertTrue(Quant.allCases.contains(.int6))
    }

    func testCanonicalOutputsAreFixed() {
        XCTAssertEqual(Capability.tts.canonicalOutput, .audio)
        XCTAssertEqual(Capability.textToImage.canonicalOutput, .image)
        XCTAssertEqual(Capability.textToVideo.canonicalOutput, .video)
        XCTAssertEqual(Capability.llm.canonicalOutput, .text)
        XCTAssertEqual(Capability.imageAnalysis.canonicalOutput, .structuredText)
        XCTAssertEqual(Capability.videoAnalysis.canonicalOutput, .structuredText)
        XCTAssertEqual(Capability.audioSeparation.canonicalOutput, .audio)
        XCTAssertEqual(Capability.speechEmotion.canonicalOutput, .structuredText)
        XCTAssertEqual(Capability.audioCodec.canonicalOutput, .codes)
        XCTAssertEqual(Capability.audioPolish.canonicalOutput, .audio)
        XCTAssertEqual(Capability.imageQualityScore.canonicalOutput, .structuredText)
        XCTAssertEqual(Capability.imageRestore.canonicalOutput, .image)
        XCTAssertEqual(Capability.imageUpscale.canonicalOutput, .image)
        XCTAssertEqual(Capability.videoUpscale.canonicalOutput, .video)
        XCTAssertEqual(Capability.frameInterpolate.canonicalOutput, .video)
        XCTAssertEqual(Capability.contentClassify.canonicalOutput, .structuredText)
        XCTAssertEqual(Capability.opticalFlow.canonicalOutput, .flow)
    }

    func testOpticalFlowContractAndIO() {
        let img = Image(format: .png, data: Data([0x89]), width: 4, height: 2)
        let req = OpticalFlowRequest(image0: img, image1: img)
        XCTAssertEqual(OpticalFlowRequest.capability, .opticalFlow)

        // 4x2 field; pixel (1, 0) moves by (+2, -1)
        var uv = [Float](repeating: 0, count: 4 * 2 * 2)
        uv[(0 * 4 + 1) * 2] = 2
        uv[(0 * 4 + 1) * 2 + 1] = -1
        let field = FlowField(width: 4, height: 2, uv: uv)
        XCTAssertEqual(field[1, 0].u, 2)
        XCTAssertEqual(field[1, 0].v, -1)
        XCTAssertEqual(field[0, 0].u, 0)

        let resp = OpticalFlowResponse(flow: field)
        XCTAssertEqual(resp.flow.uv.count, 16)

        let d = OpticalFlowContract.descriptor(name: "flow", summary: "Dense motion")
        XCTAssertEqual(d.capability, .opticalFlow)
        XCTAssertEqual(d.parameters.count, 2)
        XCTAssertTrue(d.parameters.allSatisfy { $0.kind == .image && $0.required })
    }

    func testContentClassifyContractAndIO() {
        let video = Video(format: .mp4, data: Data([0x00]), durationSeconds: 2, frameRate: 30)
        let req = ContentClassifyRequest(video: video)
        XCTAssertEqual(ContentClassifyRequest.capability, .contentClassify)

        let resp = ContentClassifyResponse(
            labels: [ContentScore(label: "photographic", score: 0.9)],
            embedding: [0.1, 0.2, 0.3])
        XCTAssertEqual(resp.labels.first?.label, "photographic")
        XCTAssertEqual(resp.embedding.count, 3)

        let d = ContentClassifyContract.descriptor(name: "classify", summary: "Content routing")
        XCTAssertEqual(d.capability, .contentClassify)
        XCTAssertEqual(d.parameters.first?.kind, .video)
    }

    func testFrameInterpolateContractAndIO() {
        let video = Video(format: .mp4, data: Data([0x00]), durationSeconds: 2, frameRate: 12)
        let req = FrameInterpolateRequest(video: video, factor: 2)
        XCTAssertEqual(FrameInterpolateRequest.capability, .frameInterpolate)
        XCTAssertEqual(req.factor, 2)

        let resp = FrameInterpolateResponse(video: video, appliedFactor: 2)
        XCTAssertEqual(resp.appliedFactor, 2)

        let d = FrameInterpolateContract.descriptor(name: "interp", summary: "FPS up-conversion")
        XCTAssertEqual(d.capability, .frameInterpolate)
        XCTAssertEqual(d.parameters.first?.kind, .video)
        XCTAssertTrue(d.parameters.contains { $0.name == "factor" && !$0.required })
    }

    func testVideoUpscaleContractAndIO() {
        let video = Video(format: .mp4, data: Data([0x00, 0x00, 0x00, 0x18]), durationSeconds: 2, frameRate: 30)
        let req = VideoUpscaleRequest(video: video, scale: 2)
        XCTAssertEqual(VideoUpscaleRequest.capability, .videoUpscale)
        XCTAssertEqual(req.scale, 2)

        let resp = VideoUpscaleResponse(video: video, appliedScale: 2)
        XCTAssertEqual(resp.appliedScale, 2)

        let d = VideoUpscaleContract.descriptor(name: "videoUpscale", summary: "Video SR")
        XCTAssertEqual(d.capability, .videoUpscale)
        XCTAssertEqual(d.parameters.first?.kind, .video)
        XCTAssertTrue(d.parameters.contains { $0.name == "scale" && !$0.required })
    }

    func testImageUpscaleContractAndIO() {
        let image = Image(format: .png, data: Data([0x89, 0x50, 0x4E, 0x47]), width: 64, height: 64)
        let req = ImageUpscaleRequest(image: image, scale: 4)
        XCTAssertEqual(ImageUpscaleRequest.capability, .imageUpscale)
        XCTAssertEqual(req.scale, 4)

        let resp = ImageUpscaleResponse(image: image, appliedScale: 4)
        XCTAssertEqual(resp.appliedScale, 4)

        let d = ImageUpscaleContract.descriptor(name: "upscale", summary: "SR")
        XCTAssertEqual(d.capability, .imageUpscale)
        XCTAssertEqual(d.parameters.first?.kind, .image)
        XCTAssertTrue(d.parameters.contains { $0.name == "scale" && !$0.required })
    }

    func testImageRestoreContractAndIO() {
        let image = Image(format: .png, data: Data([0x89, 0x50, 0x4E, 0x47]), width: 64, height: 64)
        let req = ImageRestoreRequest(image: image)
        XCTAssertEqual(ImageRestoreRequest.capability, .imageRestore)
        XCTAssertEqual(req.image.height, 64)

        let resp = ImageRestoreResponse(image: image)
        XCTAssertEqual(resp.image.width, 64)

        let d = ImageRestoreContract.descriptor(name: "restore", summary: "Denoise/deblock")
        XCTAssertEqual(d.capability, .imageRestore)
        XCTAssertEqual(d.parameters.first?.kind, .image)
    }

    func testImageQualityContractAndIO() {
        let image = Image(format: .png, data: Data([0x89, 0x50, 0x4E, 0x47]), width: 16, height: 16)
        let req = ImageQualityScoreRequest(image: image)
        XCTAssertEqual(ImageQualityScoreRequest.capability, .imageQualityScore)
        XCTAssertEqual(req.image.width, 16)

        let resp = ImageQualityScoreResponse(score: 0.78, subscores: ["patchMin": 0.6])
        XCTAssertEqual(resp.score, 0.78)
        XCTAssertEqual(resp.subscores["patchMin"], 0.6)

        let d = ImageQualityContract.descriptor(name: "scoreQuality", summary: "NR-IQA")
        XCTAssertEqual(d.capability, .imageQualityScore)
        XCTAssertEqual(d.parameters.first?.kind, .image)
    }

    func testAudioPolishContractAndIO() {
        let audio = Audio(data: Data([0x52, 0x49, 0x46, 0x46]), sampleRate: 48_000, channels: 1)
        let req = AudioPolishRequest(audio: audio, mode: .broadcast)
        XCTAssertEqual(AudioPolishRequest.capability, .audioPolish)
        XCTAssertEqual(req.mode, .broadcast)

        let resp = AudioPolishResponse(audio: audio, inputLUFS: -30, outputLUFS: -23)
        XCTAssertEqual(resp.outputLUFS, -23)

        let d = AudioPolishContract.descriptor(name: "polish", summary: "Master audio", modes: [.broadcast, .streaming])
        XCTAssertEqual(d.capability, .audioPolish)
        XCTAssertEqual(d.parameters.first?.kind, .audio)
        XCTAssertEqual(d.supportedModes, [.broadcast, .streaming])
    }

    func testClassicalCapabilityAdmitsWithEmptyRequirements() {
        // The non-MLX seam: a weightless/backendless capability must be admissible.
        let reqs = RequirementsManifest(footprints: [], requiredBackends: [])
        XCTAssertTrue(reqs.footprints.isEmpty)
        XCTAssertTrue(reqs.requiredBackends.isEmpty)
        // license = port-code on both layers (no separate weights) still clears the gate.
        let decl = LicenseDeclaration(weightLicense: .mit, portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .admitted)
    }

    func testCcBy4LicenseIsPermissive() {
        // Kyutai's Mimi codec ships under CC-BY-4.0 (permissive: commercial + redistribution OK).
        XCTAssertTrue(SPDXLicense.ccBy4.isPermissive)
        let decl = LicenseDeclaration(weightLicense: .ccBy4, portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .admitted)
    }

    func testFp32QuantExists() {
        XCTAssertTrue(Quant.allCases.contains(.fp32))
    }

    func testAudioCodecContractAndIO() {
        let audio = Audio(data: Data([0x52, 0x49, 0x46, 0x46]), sampleRate: 24_000, channels: 1)
        let req = AudioCodecRequest(audio: audio)
        XCTAssertEqual(AudioCodecRequest.capability, .audioCodec)

        let resp = AudioCodecResponse(codes: [[0, 1, 2], [3, 4, 5]], numCodebooks: 2, frameRate: 12.5)
        XCTAssertEqual(resp.codes.count, 2)
        XCTAssertEqual(resp.numCodebooks, 2)
        XCTAssertEqual(resp.frameRate, 12.5)

        let d = AudioCodecContract.descriptor(name: "encodeAudio", summary: "Mimi encode")
        XCTAssertEqual(d.capability, .audioCodec)
        XCTAssertEqual(d.parameters.first?.kind, .audio)
    }

    func testFunasrModelLicenseIsPermissive() {
        // emotion2vec+ ships under FunASR's non-SPDX MODEL_LICENSE, deliberately allowlisted.
        XCTAssertTrue(SPDXLicense.funasrModel.isPermissive)
        let decl = LicenseDeclaration(weightLicense: .funasrModel, portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .admitted)
    }

    func testSpeechEmotionContractAndIO() {
        let audio = Audio(data: Data([0x52, 0x49, 0x46, 0x46]), sampleRate: 16_000, channels: 1)
        let req = SpeechEmotionRequest(audio: audio)
        XCTAssertEqual(SpeechEmotionRequest.capability, .speechEmotion)
        XCTAssertEqual(req.audio.sampleRate, 16_000)

        let resp = SpeechEmotionResponse(label: "happy", confidence: 0.8,
                                         scores: [EmotionScore(label: "happy", score: 0.8),
                                                  EmotionScore(label: "neutral", score: 0.2)])
        XCTAssertEqual(resp.label, "happy")
        XCTAssertEqual(resp.scores.count, 2)

        let d = SpeechEmotionContract.descriptor(name: "classifyEmotion", summary: "SER")
        XCTAssertEqual(d.capability, .speechEmotion)
        XCTAssertEqual(d.parameters.first?.kind, .audio)
    }

    func testLicenseGateAdmitsPermissive() {
        let decl = LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl), .admitted)
    }

    func testLicenseGateNamesFailingLayer() {
        // Permissive port code wrapping a non-permissive checkpoint: the common mistake.
        let decl = LicenseDeclaration(weightLicense: "CC-BY-NC-4.0", portCodeLicense: .mit)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl),
                       .rejectedWeight("CC-BY-NC-4.0"))

        let decl2 = LicenseDeclaration(weightLicense: .mit, portCodeLicense: "GPL-3.0-only")
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(decl2),
                       .rejectedPortCode("GPL-3.0-only"))
    }

    func testTTSRequestCarriesCanonicalSurface() {
        let req = TTSRequest(text: "hello", voice: VoiceSelector(.named("nova")), mode: .expressive)
        XCTAssertEqual(TTSRequest.capability, .tts)
        XCTAssertEqual(req.mode, .expressive)
        XCTAssertEqual(req.text, "hello")
    }

    func testAudioSeparationRequestCarriesCanonicalSurface() {
        let mixture = Audio(data: Data([0x52, 0x49, 0x46, 0x46]), sampleRate: 44_100, channels: 2)
        let req = AudioSeparationRequest(audio: mixture, stems: [.vocals, .instrumental])
        XCTAssertEqual(AudioSeparationRequest.capability, .audioSeparation)
        XCTAssertEqual(req.stems, [.vocals, .instrumental])
        XCTAssertEqual(req.audio.sampleRate, 44_100)
    }

    func testAudioSeparationResponseKeysStemsByName() {
        let vocals = Audio(data: Data([0x01]), sampleRate: 44_100, channels: 1)
        let inst = Audio(data: Data([0x02]), sampleRate: 44_100, channels: 1)
        let resp = AudioSeparationResponse(stems: [.vocals: vocals, .instrumental: inst])
        XCTAssertEqual(resp[.vocals], vocals)
        XCTAssertEqual(resp[.instrumental], inst)
        XCTAssertNil(resp[.drums])
    }

    func testAudioSeparationDescriptorIsCanonical() {
        let d = AudioSeparationContract.descriptor(name: "separateVocals", summary: "Split vocals")
        XCTAssertEqual(d.capability, .audioSeparation)
        XCTAssertEqual(d.parameters.first?.name, "audio")
        XCTAssertEqual(d.parameters.first?.kind, .audio)
        XCTAssertTrue(d.parameters.contains { $0.name == "stems" && !$0.required })
    }

    func testArtifactRoundTripsThroughCodable() throws {
        let audio = Audio(data: Data([0x52, 0x49, 0x46, 0x46]), sampleRate: 24_000, channels: 1)
        let encoded = try JSONEncoder().encode(audio)
        let decoded = try JSONDecoder().decode(Audio.self, from: encoded)
        XCTAssertEqual(decoded, audio)
        XCTAssertEqual(decoded.format, .wav)
    }

    func testMetaValueRoundTrips() throws {
        let mv: MetaValue = .object(["emotion": .string("calm"), "strength": .double(0.7),
                                     "loop": .bool(false), "tags": .array([.string("a"), .int(2)])])
        let data = try JSONEncoder().encode(mv)
        let back = try JSONDecoder().decode(MetaValue.self, from: data)
        XCTAssertEqual(back, mv)
    }

    func testChipTierOrders() {
        XCTAssertTrue(ChipTier.base < ChipTier.pro)
        XCTAssertTrue(ChipTier.pro < ChipTier.max)
        XCTAssertTrue(ChipTier.max < ChipTier.ultra)
    }

    // MARK: - ModelPackage / manifest contract

    func testManifestRunsLicenseGateAndDerivesCapabilities() {
        let m = EchoTTSPackage.manifest
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(m.license), .admitted)
        XCTAssertEqual(m.capabilities, [.tts])
        XCTAssertEqual(m.contractVersion, ContractVersion.current)
    }

    func testRegistrationFactoryConstructsAndDispatches() async throws {
        let reg = PackageRegistration.of(EchoTTSPackage.self)
        XCTAssertEqual(LicensePolicy.permissiveOnly.evaluate(reg.manifest.license), .admitted)

        let pkg = try reg.makePackage(EchoTTSPackage.Config(weightsRepo: "mlx-community/echo-tts"))
        try await pkg.load()
        let response = try await pkg.run(TTSRequest(text: "hello"))
        let tts = try XCTUnwrap(response as? TTSResponse)
        XCTAssertEqual(tts.audio.format, .wav)
        await pkg.unload()
    }

    func testRunBeforeLoadThrowsNotLoaded() async {
        let pkg = EchoTTSPackage(configuration: .init(weightsRepo: "x"))
        do {
            _ = try await pkg.run(TTSRequest(text: "hi"))
            XCTFail("expected PackageError.notLoaded")
        } catch let error as PackageError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunRejectsUnbackedCapability() async throws {
        let pkg = EchoTTSPackage(configuration: .init(weightsRepo: "x"))
        try await pkg.load()
        do {
            _ = try await pkg.run(UnbackedLLMRequest())
            XCTFail("expected PackageError.unsupportedCapability")
        } catch let error as PackageError {
            XCTAssertEqual(error, .unsupportedCapability(.llm))
        }
    }

    func testFactoryRejectsMismatchedConfiguration() {
        let reg = PackageRegistration.of(EchoTTSPackage.self)
        XCTAssertThrowsError(try reg.makePackage(WrongConfig())) { error in
            guard case PackageError.configurationMismatch = error else {
                return XCTFail("expected configurationMismatch, got \(error)")
            }
        }
    }
}

// MARK: - Test doubles

/// A tiny in-memory package that exercises the `ModelPackage` lifecycle and erased dispatch.
@InferenceActor
final class EchoTTSPackage: ModelPackage {
    struct Config: PackageConfiguration { var weightsRepo: String }

    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
            provenance: Provenance(sourceRepo: "mlx-community/echo-tts", revision: "abc123", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .int4, residentBytes: 200_000_000)],
                requiredBackends: [.metalGPU]),
            specialties: [SpecialtyWeight(.companion, strength: 0.8)],
            surfaces: [TTSContract.descriptor(name: "generateSpeech", summary: "Echo TTS")])
    }

    private var resident = false
    nonisolated init(configuration: Config) {}

    func load() async throws { resident = true }
    func unload() async { resident = false }

    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard resident else { throw PackageError.notLoaded }
        guard let tts = request as? TTSRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        // Echo: trivial wav bytes sized from the input text.
        let bytes = Data(repeating: 0, count: max(1, tts.text.count))
        return TTSResponse(audio: Audio(data: bytes, sampleRate: 24_000, channels: 1))
    }
}

/// A request whose capability the EchoTTS package does not back — drives the dispatch guard.
struct UnbackedLLMRequest: CapabilityRequest {
    static var capability: Capability { .llm }
    var mode: Mode? { nil }
    var metaData: MetaData { [:] }
}

/// A configuration of the wrong type, to drive the factory's mismatch guard.
struct WrongConfig: PackageConfiguration {}
