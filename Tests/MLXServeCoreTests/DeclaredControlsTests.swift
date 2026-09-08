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
