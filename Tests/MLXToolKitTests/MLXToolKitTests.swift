import XCTest
@testable import MLXToolKit

final class MLXToolKitTests: XCTestCase {

    func testContractVersionIsV1() {
        XCTAssertEqual(ContractVersion.current, SemanticVersion(major: 1, minor: 0, patch: 0))
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
