import Testing
import Foundation
import MLXRetrievalKitContracts
@testable import MLXRetrievalKit

private struct MockProvider: WebSearchProvider {
    var results: [WebSearchResult] = []
    var error: Error? = nil
    func search(_ query: String, count: Int) async throws -> [WebSearchResult] {
        if let error { throw error }
        return Array(results.prefix(count))
    }
}

private func makeResults(_ n: Int, snippet: String = "a current fact") -> [WebSearchResult] {
    (0..<n).map { i in
        WebSearchResult(title: "Title \(i)", url: URL(string: "https://example.com/\(i)")!,
                        snippet: snippet, rank: i)
    }
}

@Test func retrieveBudgetsResultsIntoSources() async {
    let service = RetrievalService(provider: MockProvider(results: makeResults(5)), profile: .conversational)
    let result = await service.retrieve("what is new today")
    #expect(!result.degraded)
    #expect(result.sources.count == 3) // conversational fetches 3
    #expect(result.sources.first?.rank == 0)
    let grounding = result.groundingText()
    #expect(grounding != nil)
    #expect(grounding?.contains("what is new today") == true)
}

@Test func providerFailureDegradesGracefully() async {
    let service = RetrievalService(provider: MockProvider(error: RetrievalError.providerFailed(status: 429)))
    let result = await service.retrieve("anything")
    #expect(result.degraded)
    #expect(result.sources.isEmpty)
    #expect(result.groundingText() == nil) // caller answers from model knowledge
}

@Test func oversizedSnippetTruncatesUnderBudget() async {
    let huge = String(repeating: "x", count: 10_000) // far over the per-result cap
    let service = RetrievalService(provider: MockProvider(results: makeResults(1, snippet: huge)),
                                   profile: .conversational)
    let result = await service.retrieve("q")
    #expect(result.truncated)
    let cap = RetrievalProfile.conversational.config.perResultTokenCap
    #expect(estimateTokens(result.sources.first!.text) <= cap)
}

@Test func braveFactoryNilWithoutKey() {
    // No key passed and (in CI) no env/defaults key → nil so callers degrade.
    #expect(RetrievalService.brave(apiKey: nil) == nil)
}
