//
//  LLMImageInputEngineTests.swift
//  MLXServeCoreTests
//
//  Contract 1.54.0 (AB-A-0190) — the engine pre-flight for chat-turn images: refused on a surface
//  that does not declare `LLMControls.acceptsImages`, on non-user turns and past the declared
//  maximum, before admission; delivered unchanged where declared. Offline, mock packages.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

private func llmManifest(name: String, controls: LLMControls?) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: RequirementsManifest(footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
                                           requiredBackends: [.metalGPU]),
        surfaces: [LLMContract.descriptor(name: name, summary: "m", controls: controls)])
}

/// A text-only backbone (Qwen3.5-4B's shape). Loads count, so a refusal is seen to come first.
@InferenceActor
private final class TextLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    static var loads = 0
    nonisolated static var manifest: PackageManifest { llmManifest(name: "text-llm", controls: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { Self.loads += 1 }
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "text", finishReason: .stop)
    }
}

/// A vision-language backbone that answers with the number of images it was handed.
@InferenceActor
private final class VisionLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        llmManifest(name: "vision-llm", controls: LLMControls(acceptsImages: true, maxImagesPerRequest: 2))
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "\((request as? LLMRequest)?.images.count ?? -1)", finishReason: .stop)
    }
}

private func config() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/llm") }
private let picture = Image(format: .png, data: Data([1]), width: 1, height: 1)

private func refusal(_ body: () async throws -> Void) async -> String? {
    do { try await body() } catch PackageError.unsupportedRequestFeature(let detail) { return detail } catch {
        return "unexpected \(error)"
    }
    return nil
}

@Suite("Image input on chat turns in the engine — contract 1.54.0", .serialized)
struct LLMImageInputEngineTests {

    @Test func aTextOnlySurfaceRefusesImagesBeforeLoading() async throws {
        let engine = MLXServeEngine()
        try await engine.register(.of(TextLLM.self), configuration: config())
        let before = await TextLLM.loads
        let detail = await refusal {
            _ = try await engine.run(LLMRequest(prompt: "describe", images: [picture]))
        }
        #expect(detail?.contains("declares no image input") == true)
        #expect(await TextLLM.loads == before)
        // Text still runs.
        let text = try await engine.run(LLMRequest(prompt: "hi")) as! LLMResponse
        #expect(text.text == "text")
    }

    @Test func aVisionSurfaceGetsItsImages() async throws {
        let engine = MLXServeEngine()
        try await engine.register(.of(VisionLLM.self), configuration: config())
        let response = try await engine.run(LLMRequest(messages: [
            ChatMessage(role: .system, content: "rewrite the edit prompt"),
            ChatMessage(role: .user, content: "make it dusk", images: [picture, picture]),
        ])) as! LLMResponse
        #expect(response.text == "2")
    }

    @Test func imagesOnANonUserTurnOrPastTheLimitAreRefused() async throws {
        let engine = MLXServeEngine()
        try await engine.register(.of(VisionLLM.self), configuration: config())
        #expect(await refusal {
            _ = try await engine.run(LLMRequest(messages: [
                ChatMessage(role: .assistant, content: "here", images: [picture]),
            ]))
        }?.contains("images on a .assistant turn") == true)
        #expect(await refusal {
            _ = try await engine.run(LLMRequest(messages: [
                ChatMessage(role: .user, content: "a", images: [picture, picture]),
                ChatMessage(role: .user, content: "b", images: [picture]),
            ]))
        }?.contains("3 in the request, vision-llm takes at most 2") == true)
        // A 16-bit chat image is held to the raw-format declaration like any other image.
        #expect(await refusal {
            _ = try await engine.run(LLMRequest(prompt: "describe",
                                                images: [Image.rawRGBA16(data: Data(count: 8), width: 1, height: 1)]))
        }?.contains("rawRGBA16") == true)
    }
}
