// MLXHubMetadata — **metadata-only** Hugging Face access for the engine (MS-3).
//
// Placement decision (2026-07, recorded in architecture.md): the engine deliberately ships no
// weight-downloading HTTP code — every package materializes through its own hub client. But
// answering "this will need 34 GB, you have 41 GB free" *before* any package code runs needs a
// listing of file sizes, which is HTTP. So it lives here, in its own tiny target:
//
//   • `MLXToolKit` stays Foundation-only, network-free, and dependency-free (the contract every
//     package builds against offline).
//   • The alternative — vendoring an `expectedBytes` field onto `WeightSource` — was rejected:
//     a declared size drifts from the hub the moment a repo is re-quantized, which defeats the
//     purpose of a *preview*.
//   • Everything is behind `HubMetadataProviding`, so tests (and offline consumers) inject a mock
//     and no network is touched.

import Foundation
import MLXToolKit

/// One file in a repo listing: path relative to the repo root, and its size in bytes.
public struct HubFileEntry: Sendable, Equatable, Codable {
    public let path: String
    public let size: UInt64

    public init(path: String, size: UInt64) {
        self.path = path
        self.size = size
    }
}

/// The metadata seam: list a repo's files with sizes. No downloads, no auth requirement.
public protocol HubMetadataProviding: Sendable {
    /// Every file in `repo` at `revision` (nil = main), with sizes.
    /// - Throws: when the hub is unreachable, the repo is private/absent, or the response is
    ///   unparseable. Callers **must** degrade gracefully — a preview is an affordance, never a gate
    ///   on materialization.
    func files(repo: String, revision: String?) async throws -> [HubFileEntry]
}

public enum HubMetadataError: Error, Sendable, Equatable {
    /// The hub answered with a non-200 status (404 = private or missing repo).
    case httpStatus(Int)
    /// The response body was not the expected tree JSON.
    case malformedResponse
}

/// Live implementation over the HF tree API:
/// `GET https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true`.
///
/// This is the *exact* sizing tier — real per-file byte counts for the files we would actually
/// fetch. (The cheap safetensors-params tier exists for *browsing* an open hub; we only ever
/// preview declared sources, so exactness costs nothing extra.)
public struct HubMetadataClient: HubMetadataProviding {
    private let endpoint: URL
    private let session: URLSession
    /// Optional token for gated/private repos; nil = anonymous (the normal case for our fleet).
    private let token: String?

    public init(endpoint: URL = URL(string: "https://huggingface.co")!,
                session: URLSession = .shared,
                token: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]) {
        self.endpoint = endpoint
        self.session = session
        self.token = token
    }

    public func files(repo: String, revision: String?) async throws -> [HubFileEntry] {
        let url = endpoint
            .appending(path: "api/models/\(repo)/tree/\(revision ?? "main")")
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "true")])
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HubMetadataError.httpStatus(http.statusCode)
        }
        return try Self.parseTree(data)
    }

    /// Parse a `/tree` response body. Directories appear in the listing with `type: "directory"`
    /// and no useful size — skip them; anything without a path is not a file we can fetch.
    static func parseTree(_ data: Data) throws -> [HubFileEntry] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HubMetadataError.malformedResponse
        }
        return items.compactMap { item in
            guard (item["type"] as? String) != "directory",
                  let path = item["path"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.uint64Value ?? 0
            return HubFileEntry(path: path, size: size)
        }
    }
}

// MARK: - Preview

/// What materializing a configuration's **missing** weight sources would cost, and whether the
/// store's volume can take it (MS-3).
///
/// Degrades honestly: when the hub is unreachable, per-source `expectedBytes` and `totalBytes` are
/// `nil` and `fits` is `nil` — "unknown", never "won't fit". A preview must never block a
/// materialization that would have succeeded.
public struct MaterializationPreview: Sendable, Equatable {

    /// One missing source's estimated download size.
    public struct Source: Sendable, Equatable {
        public let role: String
        public let repo: String
        /// Summed size of the files this source would fetch; `nil` when the hub couldn't be reached.
        public let expectedBytes: UInt64?

        public init(role: String, repo: String, expectedBytes: UInt64?) {
            self.role = role
            self.repo = repo
            self.expectedBytes = expectedBytes
        }
    }

    /// The missing sources only — an already-materialized source costs nothing to "download".
    public let sources: [Source]
    /// Σ `expectedBytes`, or `nil` when any source is unknown (a partial total would read as a
    /// safe-looking under-estimate, which is worse than "unknown").
    public let totalBytes: UInt64?
    /// Free space on the store root's volume (`volumeAvailableCapacityForImportantUsage`), or nil
    /// when there is no store root / the volume can't be queried.
    public let freeBytes: UInt64?
    /// `totalBytes <= freeBytes` when both are known; `nil` = unknown.
    public var fits: Bool? {
        guard let totalBytes, let freeBytes else { return nil }
        return totalBytes <= freeBytes
    }
    /// Nothing to download — every declared source is already materialized.
    public var isSatisfied: Bool { sources.isEmpty }

    public init(sources: [Source], totalBytes: UInt64?, freeBytes: UInt64?) {
        self.sources = sources
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

public extension MaterializationPreview {

    /// Build a preview for `missing` sources: size each against the hub, then read the store
    /// volume's free space.
    ///
    /// Sizing failures are per-source and non-fatal (that source's `expectedBytes` is nil).
    static func make(missing: [WeightSource],
                     storeRoot: URL?,
                     provider: any HubMetadataProviding) async -> MaterializationPreview {
        var sources: [Source] = []
        var total: UInt64? = 0
        for source in missing {
            let bytes = try? await sizeOf(source, provider: provider)
            sources.append(Source(role: source.role, repo: source.repo, expectedBytes: bytes))
            if let bytes, var running = total { running &+= bytes; total = running } else { total = nil }
        }
        return MaterializationPreview(sources: sources,
                                      totalBytes: sources.isEmpty ? 0 : total,
                                      freeBytes: storeRoot.flatMap(freeBytes(at:)))
    }

    /// Σ sizes of the files a source would fetch: everything matching its `matching` globs, or the
    /// whole listing when it declares none.
    static func sizeOf(_ source: WeightSource,
                       provider: any HubMetadataProviding) async throws -> UInt64 {
        let files = try await provider.files(repo: source.repo, revision: source.revision)
        guard let globs = source.matching, !globs.isEmpty else {
            return files.reduce(UInt64(0)) { $0 &+ $1.size }
        }
        return files.reduce(UInt64(0)) { sum, file in
            globs.contains { WeightSourceProbe.matches(path: file.path, glob: $0) }
                ? sum &+ file.size : sum
        }
    }

    /// Free space on the volume holding `url`, by the same measure the OS uses for purgeable-aware
    /// "can I write this" questions.
    static func freeBytes(at url: URL) -> UInt64? {
        guard let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity < 0 ? nil : UInt64(capacity)
    }
}
