//
//  LLMImageInputTests.swift
//  MLXToolKitTests
//
//  Contract 1.54.0 (AB-A-0190) — image input on chat turns: the wire shape stays compatible with
//  pre-1.54 messages, and the `llm` surface declares it through `LLMControls`.
//

import Foundation
import Testing
@testable import MLXToolKit

@Suite("Image input on chat turns — contract 1.54.0")
struct LLMImageInputTests {

    private let picture = Image(format: .png, data: Data([0x89, 0x50]), width: 1, height: 1)

    @Test func contractIsAt1_54() {
        #expect(ContractVersion.current >= SemanticVersion(major: 1, minor: 54, patch: 0))
    }

    @Test func aTextOnlyMessageKeepsItsPre154WireShape() throws {
        let text = ChatMessage(role: .user, content: "hi")
        #expect(text.images.isEmpty)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text)) as? [String: Any]
        #expect(json?.keys.sorted() == ["content", "role"])
        let legacy = try JSONDecoder().decode(ChatMessage.self,
                                              from: Data(#"{"role":"user","content":"hi"}"#.utf8))
        #expect(legacy == text)
    }

    @Test func imagesRoundTripInOrder() throws {
        let second = Image(format: .jpeg, data: Data([0xFF, 0xD8]))
        let turn = ChatMessage(role: .user, content: "compare", images: [picture, second])
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(turn))
        #expect(decoded == turn)
        #expect(decoded.images.map(\.format) == [.png, .jpeg])

        let request = LLMRequest(messages: [
            ChatMessage(role: .system, content: "rewrite"),
            turn,
            ChatMessage(role: .user, content: "and this", images: [picture]),
        ])
        #expect(request.images.count == 3)
        #expect(LLMRequest(prompt: "describe", images: [picture]).messages
            == [ChatMessage(role: .user, content: "describe", images: [picture])])
    }

    @Test func theSurfaceDeclaresImageInput() throws {
        let text = LLMContract.descriptor(name: "qwen-4b", summary: "s")
        #expect(text.llmControls == nil)
        #expect(text.controls == nil)

        let vision = LLMContract.descriptor(name: "qwen-vl", summary: "s",
                                            controls: LLMControls(acceptsImages: true, maxImagesPerRequest: 4))
        #expect(vision.llmControls == LLMControls(acceptsImages: true, maxImagesPerRequest: 4))
        #expect(vision.controlsMatchCapability)
        #expect(vision.parameters.first { $0.name == "messages" }?.summary?.contains("images on user turns, at most 4") == true)
        #expect(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(vision)) == vision)

        let misplaced = ToolDescriptor(name: "x", capability: .tts, summary: "s",
                                       controls: .llm(LLMControls(acceptsImages: true)))
        #expect(!misplaced.controlsMatchCapability)
        #expect(misplaced.ttsControls == nil)
    }
}
