//
//  BraveSearchProvider.swift
//  MLXRetrievalKit
//
//  Default discovery provider — Brave Search (independent index, no query logging:
//  the policy-aligned default for an on-device privacy story). Requires an API
//  subscription token. Verify current free-tier terms before relying on them.
//

import Foundation
import MLXRetrievalKitContracts

public struct BraveSearchProvider: WebSearchProvider {
    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func search(_ query: String, count: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RetrievalError.badResponse }
        guard http.statusCode == 200 else { throw RetrievalError.providerFailed(status: http.statusCode) }

        let decoded = try JSONDecoder().decode(BraveResponse.self, from: data)
        return (decoded.web?.results ?? []).enumerated().compactMap { index, result in
            guard let url = URL(string: result.url) else { return nil }
            return WebSearchResult(title: result.title, url: url,
                                   snippet: result.description ?? "", rank: index)
        }
    }

    /// Minimal slice of the Brave web-search response.
    private struct BraveResponse: Decodable {
        let web: Web?
        struct Web: Decodable { let results: [Result] }
        struct Result: Decodable { let title: String; let url: String; let description: String? }
    }
}
