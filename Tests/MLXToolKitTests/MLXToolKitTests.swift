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
