//
//  RetrievalService.swift
//  MLXRetrievalKit
//
//  The reusable grounding service: query → ranked results → budgeted sources.
//  Any MLXEngine package or app can call it to ground an answer in current
//  knowledge (RAG): retrieve, then prepend `RetrievalResult.groundingText()` to
//  the prompt before generation. It returns structured sources, never prose, and
//  never throws — search failure degrades to an empty, `degraded` result so the
//  caller simply answers from model knowledge.
//
//  MLX-free and network-only: it depends solely on the Foundation-only contracts.
//

import Foundation
import MLXRetrievalKitContracts

public struct RetrievalService: Sendable {
    private let provider: any WebSearchProvider
    private let profile: RetrievalProfile

    public init(provider: any WebSearchProvider, profile: RetrievalProfile = .conversational) {
        self.provider = provider
        self.profile = profile
    }

    /// Convenience: build a Brave-backed service from a resolved API key, or `nil` if no key is
    /// configured (`BRAVE_API_KEY` env or `BraveKeyStore`). Lets callers degrade cleanly.
    public static func brave(apiKey: String? = BraveKeyStore.load(),
                             profile: RetrievalProfile = .conversational) -> RetrievalService? {
        guard let apiKey else { return nil }
        return RetrievalService(provider: BraveSearchProvider(apiKey: apiKey), profile: profile)
    }

    /// Search + budget snippets into sources. Never throws: a provider failure (offline, auth,
    /// rate limit) returns an empty `degraded` result.
    public func retrieve(_ query: String) async -> RetrievalResult {
        let config = profile.config
        let hits: [WebSearchResult]
        do {
            hits = try await provider.search(query, count: config.resultsFetched)
        } catch {
            return RetrievalResult(query: query, sources: [], truncated: false, degraded: true)
        }

        var sources: [RetrievalSource] = []
        var remaining = config.totalContextBudget
        var truncated = false

        for hit in hits.prefix(config.resultsFetched) {
            if remaining <= 0 { truncated = true; break }
            let budget = min(config.perResultTokenCap, remaining)
            let capped = Self.cap(hit.snippet, toTokens: budget)
            if capped.didTruncate { truncated = true }
            remaining -= capped.tokens
            sources.append(RetrievalSource(title: hit.title, url: hit.url,
                                           text: capped.text, rank: hit.rank))
        }

        return RetrievalResult(query: query, sources: sources, truncated: truncated, degraded: false)
    }

    /// Extractive token cap (~4 chars/token).
    static func cap(_ text: String, toTokens tokens: Int) -> (text: String, tokens: Int, didTruncate: Bool) {
        let maxChars = max(0, tokens * 4)
        if text.count <= maxChars { return (text, estimateTokens(text), false) }
        return (String(text.prefix(maxChars)), tokens, true)
    }
}

extension RetrievalService {
    /// Build a service from saved `WebSearchPreferences` — returns `nil` when web search is
    /// disabled or no key is configured, so callers degrade with a single optional check.
    public static func fromPreferences() -> RetrievalService? {
        guard WebSearchPreferences.isEnabled else { return nil }
        return brave(profile: WebSearchPreferences.profile)
    }

    /// Retrieve and return a ready-to-prepend grounding block (RAG), or `nil` if there were no
    /// usable sources. Lets a consumer ground a turn without touching the contracts types.
    public func grounding(for query: String) async -> String? {
        await retrieve(query).groundingText()
    }
}

extension RetrievalResult {
    /// Render the sources as a grounding block to prepend to a prompt (RAG). Returns `nil` when
    /// there are no sources, so the caller can skip grounding and answer from model knowledge.
    public func groundingText() -> String? {
        guard !sources.isEmpty else { return nil }
        var block = "Web search results for \"\(query)\". Use these to answer with current "
        block += "information and cite sources by number when relevant:\n"
        for source in sources {
            block += "\n[\(source.rank + 1)] \(source.title) — \(source.url.absoluteString)\n"
            block += "\(source.text)\n"
        }
        return block
    }
}
