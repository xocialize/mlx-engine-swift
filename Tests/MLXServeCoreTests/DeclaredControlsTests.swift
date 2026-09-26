//
//  DeclaredControlsTests.swift
//  MLXServeCoreTests
//
//  Contract 1.38.0 — the engine-side pre-flight for the audio controls plane. Silently
//  ignoring a canonical request field is a contract violation (the rule 1.16.0 set for
//  `responseFormat`), but enforcing it package-side would make every shipped TTS/STT
//  conformer retroactively non-conformant. The coordinator holds both manifest and request,
//  so it refuses an undeclared control BEFORE admission — before weights are touched.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

/// A TTS package that declares nothing (every package shipping today).
@InferenceActor
private final class PlainTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [TTSContract.descriptor(name: "plain-tts", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

/// A TTS package that declares categorical emotion but NO native duration control —
/// the shape a consumer must be able to route around (VoxCPM2 / Qwen3-TTS).
@InferenceActor
private final class EmotiveTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [TTSContract.descriptor(
            name: "emotive-tts", summary: "m",
            controls: TTSControls(emotionModes: [.categorical, .textDescription],
                                  supportsTargetDuration: false))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

/// Both levers declared (the IndexTTS2 shape).
@InferenceActor
private final class FullControlTTSPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [TTSContract.descriptor(
            name: "full-tts", summary: "m",
            controls: TTSControls(emotionModes: [.categorical, .vector, .referenceAudio],
                                  supportsTargetDuration: true))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        TTSResponse(audio: Audio(format: .wav, data: Data(count: 44)))
    }
}

/// An STT package with no biasing surface (Nemotron's shape today).
@InferenceActor
private final class PlainSTTPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [STTContract.descriptor(name: "plain-stt", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "hello")
    }
}

/// An STT package that biases and attributes (the VibeVoice-ASR shape).
@InferenceActor
private final class BiasingSTTPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [STTContract.descriptor(
            name: "biasing-stt", summary: "m",
            controls: STTControls(attributesSpeakers: true, supportsContextBiasing: true))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "hello",
                    segments: [STTSegment(text: "hello", start: 0, duration: 1,
                                          speaker: "Speaker 0")])
    }
}

/// A t2v package that declares nothing (every t2v package shipping today except LTX-2.5).
@InferenceActor
private final class PlainT2VPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [T2VContract.descriptor(name: "plain-t2v", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2VResponse(video: Video(format: .mp4, data: Data(count: 8)))
    }
}

/// The LTX-2.5 shape: generates the clip AGAINST `initAudio` (contract 1.40.0).
@InferenceActor
private final class A2VCapableT2VPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [T2VContract.descriptor(
            name: "a2v-t2v", summary: "m", controls: T2VControls(supportsInitAudio: true))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2VResponse(video: Video(format: .mp4, data: Data(count: 8)))
    }
}

/// A t2i package that declares nothing (every t2i package shipping before contract 1.48.0).
@InferenceActor
private final class PlainT2IPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [T2IContract.descriptor(name: "plain-t2i", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data(count: 8)))
    }
}

/// The Ming-Image-0.1-Design shape: generates native alpha on request (contract 1.48.0).
@InferenceActor
private final class AlphaCapableT2IPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [T2IContract.descriptor(
            name: "alpha-t2i", summary: "m", controls: T2IControls(supportsTransparentBackground: true))])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data(count: 8)))
    }
}

/// A layerDecompose package (contract 1.48.0): returns one layer per requested count, front-most
/// first, tagged by index so the order can be checked end to end.
@InferenceActor
private final class MockLayerPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        controlsManifest(surfaces: [LayerDecomposeContract.descriptor(name: "layers", summary: "m")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard let r = request as? LayerDecomposeRequest else {
            throw PackageError.unsupportedCapability(request.capability)
        }
        return LayerDecomposeResponse(
            layers: (0..<(r.layerCount ?? 5)).map { Image(format: .png, data: Data([UInt8($0)])) },
            composite: r.image)
    }
}

private func controlsManifest(surfaces: [ToolDescriptor]) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/controls", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
            requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

private func mockConfig() -> StandardConfiguration {
    StandardConfiguration(weightsRepo: "mock/controls")
}

private func unsupportedFeature(_ error: any Error) -> String? {
    guard case .unsupportedRequestFeature(let detail) = error as? PackageError else { return nil }
    return detail
}

// MARK: - TTS

@Test func undeclaredEmotionIsRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainTTSPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(TTSRequest(text: "hi", emotion: .categorical("happy")))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("emotion") == true)
    }
}

@Test func aDeclaredEmotionModeIsAccepted() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(EmotiveTTSPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(TTSRequest(text: "hi", emotion: .categorical("happy")))
}

// The check is per MODE, not per field: declaring `categorical` does not license `.vector`.
@Test func anUndeclaredEmotionModeOnADeclaringPackageIsRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(EmotiveTTSPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(TTSRequest(text: "hi", emotion: .vector([0.1, 0.2])))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("vector") == true)
    }
}

// The failure this exists to prevent: a dub cue sent to a package with no duration control
// used to return audio of the wrong length with nothing in the response saying why.
@Test func targetDurationAgainstAPackageWithoutNativeDurationIsRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(EmotiveTTSPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(TTSRequest(text: "hi", targetDuration: 3.5))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("targetDuration") == true)
    }
}

@Test func bothControlsPassAgainstAFullyDeclaringPackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(FullControlTTSPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(TTSRequest(text: "hi", emotion: .vector([0.1]), targetDuration: 2))
}

// metaData is the untouched compatibility path: a package shipping on the pre-1.38 string
// keys keeps working, and the pre-flight never looks at metaData.
@Test func metaDataCompatPathIsUnaffected() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainTTSPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(TTSRequest(text: "hi",
                                        metaData: ["emotion": .string("happy"),
                                                   "targetDuration": .double(3.5)]))
}

// MARK: - STT

@Test func undeclaredContextBiasingIsRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainSTTPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(STTRequest(audio: Audio(data: Data()), context: ["MLXEngine"]))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("context") == true)
    }
}

// An empty list asks for nothing, so it is not a violation — refusing it would make
// `context: terms.isEmpty ? nil : terms` a required incantation at every call site.
@Test func anEmptyContextIsNotARefusal() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainSTTPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(STTRequest(audio: Audio(data: Data()), context: []))
}

@Test func declaredContextBiasingIsAcceptedAndSpeakersRideTheResponse() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(BiasingSTTPackage.self),
                              configuration: mockConfig())
    let response = try await engine.run(
        STTRequest(audio: Audio(data: Data()), context: ["MLXEngine", "VoxCPM2"]))
    let stt = try #require(response as? STTResponse)
    #expect(stt.segments.first?.speaker == "Speaker 0")
}

// A pre-1.38 request is never affected — no control, no check, no behavior change.
@Test func requestsWithoutControlsAreUntouched() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainSTTPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(STTRequest(audio: Audio(data: Data()), language: "en-US"))
}

// MARK: - textToVideo (contract 1.40.0, AB-A-0023)

// The failure this exists to prevent: a soundtrack sent to a package with no a2v path used to
// come back as a video UNRELATED to the track, with nothing in the response saying so.
@Test func initAudioAgainstAPackageWithoutA2VIsRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainT2VPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(T2VRequest(prompt: "rain on a tin roof",
                                            initAudio: Audio(data: Data(count: 44))))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("initAudio") == true)
    }
}

// The ignorable inputs are NOT gated: a plain t2v package still takes `referenceImages`, and a
// request with no track never touches the declaration.
@Test func plainT2VStillAcceptsTheIgnorableConditioning() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainT2VPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(T2VRequest(prompt: "p", referenceImages: []))
}

@Test func initAudioPassesAgainstADeclaringPackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(A2VCapableT2VPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(T2VRequest(prompt: "p", initAudio: Audio(data: Data(count: 44))))
}

// MARK: - textToImage background (contract 1.48.0)

// The failure this exists to prevent: an asset asked for with a transparent background, sent to a
// package that cannot make alpha, comes back OPAQUE and is composited as a full-canvas rectangle,
// with nothing in the response saying so.
@Test func transparentBackgroundAgainstAPackageWithoutAlphaIsRefusedBeforeTheRun() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainT2IPackage.self),
                              configuration: mockConfig())
    do {
        _ = try await engine.run(T2IRequest(prompt: "a red enamel badge", background: .transparent))
        Issue.record("expected unsupportedRequestFeature")
    } catch {
        #expect(unsupportedFeature(error)?.contains("background") == true)
    }
}

// Opaque is every model's behaviour: asking for it explicitly, or not at all, is never gated.
@Test func opaqueOrUnsetBackgroundIsNeverGated() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(PlainT2IPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(T2IRequest(prompt: "p", background: .opaque))
    _ = try await engine.run(T2IRequest(prompt: "p"))
}

@Test func transparentBackgroundPassesAgainstADeclaringPackage() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(AlphaCapableT2IPackage.self),
                              configuration: mockConfig())
    _ = try await engine.run(T2IRequest(prompt: "p", background: .transparent))
}

// MARK: - layerDecompose (contract 1.48.0)

// The new capability routes like any other, and the engine carries the package's layer order
// (front-most first) through untouched.
@Test func layerDecomposeRoutesAndKeepsLayerOrder() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(MockLayerPackage.self),
                              configuration: mockConfig())
    let flat = Image(format: .png, data: Data(count: 8), width: 1920, height: 1080)
    let response = try await engine.run(LayerDecomposeRequest(image: flat, layerCount: 3))
    let layers = try #require(response as? LayerDecomposeResponse)
    #expect(layers.layers.map(\.data) == [Data([0]), Data([1]), Data([2])])
    #expect(layers.composite == flat)
}
