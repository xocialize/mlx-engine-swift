//
//  RetrievalContracts.swift
//  MLXRetrievalKitContracts
//
//  The MLX-free, Foundation-only contract surface for web retrieval / grounding:
//  the `WebSearchProvider` seam (swappable: Brave / Tavily / MCP), the Sendable
//  DTOs the service returns, and a `RetrievalProfile` that scales the pipeline
//  light↔thorough from one value. Apps and packages reference these shapes
//  without pulling the implementation (or any network/MLX).
//
//  Ported fresh from the companion app's MLXRetrievalKit design (a DEV_VOL1
//  learning trial); this is the real, MLXEngine-owned version.
//

import Foundation

// MARK: - Provider seam

/// Discovery: a query → ranked results. Swappable behind the contract so the
/// engine isn't bound to one search vendor.
public protocol WebSearchProvider: Sendable {
    /// Return up to `count` ranked results for `query`. Throws on transport/auth failure
    /// (the `RetrievalService` turns failures into a graceful, degraded result).
    func search(_ query: String, count: Int) async throws -> [WebSearchResult]
}

// MARK: - DTOs (Codable & Sendable)

/// A raw search hit from a `WebSearchProvider`.
public struct WebSearchResult: Codable, Sendable, Hashable {
    public let title: String
    public let url: URL
    public let snippet: String
    public let rank: Int
    public init(title: String, url: URL, snippet: String, rank: Int) {
        self.title = title; self.url = url; self.snippet = snippet; self.rank = rank
    }
}

/// A budgeted source ready to ground a prompt. v1 uses the provider snippet as the
/// text; full-page extraction/summarization is a documented Phase-2 seam.
public struct RetrievalSource: Codable, Sendable, Hashable {
    public let title: String
    public let url: URL
    public let text: String
    public let rank: Int
    public init(title: String, url: URL, text: String, rank: Int) {
        self.title = title; self.url = url; self.text = text; self.rank = rank
    }
}

/// The structured result the engine returns — sources, not prose. Prose synthesis
/// stays with the model/app, which is what keeps retrieval reusable.
public struct RetrievalResult: Codable, Sendable {
    public let query: String
    public let sources: [RetrievalSource]
    /// A budget forced a cut.
    public let truncated: Bool
    /// Search failed/offline → empty sources; the caller should answer from model knowledge.
    public let degraded: Bool

    public init(query: String, sources: [RetrievalSource], truncated: Bool, degraded: Bool) {
        self.query = query; self.sources = sources
        self.truncated = truncated; self.degraded = degraded
    }

    public var isEmpty: Bool { sources.isEmpty }
}

// MARK: - Profile (one value scales the pipeline)

public enum RetrievalProfile: String, Codable, Sendable, CaseIterable {
    /// Companion: 1 pass, few results, tight cap — fast and cheap.
    case conversational
    /// Balanced default.
    case balanced
    /// Research: more sources, larger budget (full extraction/summarization is Phase 2).
    case thorough

    public var config: Config {
        switch self {
        case .conversational: return Config(resultsFetched: 3, perResultTokenCap: 200, totalContextBudget: 800)
        case .balanced:       return Config(resultsFetched: 5, perResultTokenCap: 300, totalContextBudget: 1_500)
        case .thorough:       return Config(resultsFetched: 8, perResultTokenCap: 400, totalContextBudget: 3_000)
        }
    }

    public struct Config: Sendable, Equatable {
        public var resultsFetched: Int
        public var perResultTokenCap: Int
        public var totalContextBudget: Int
        public init(resultsFetched: Int, perResultTokenCap: Int, totalContextBudget: Int) {
            self.resultsFetched = resultsFetched
            self.perResultTokenCap = perResultTokenCap
            self.totalContextBudget = totalContextBudget
        }
    }
}

// MARK: - Errors + helpers

public enum RetrievalError: Error, Sendable, Equatable {
    case providerFailed(status: Int)
    case badResponse
    case missingAPIKey
}

/// Crude ~4 chars/token estimate — good enough for budgeting.
@inlinable public func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }
