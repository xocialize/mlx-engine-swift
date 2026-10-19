// AdapterStore.swift — the engine-managed half of typed adapters (contract 1.53.0, AB-A-0189).
//
// An adapter file is fetched like any weight source — through the engine's `WeightMaterializing`
// executor, with the hub token from the shared chain, into the models root — but it is keyed by
// CONTENT: `<root>/adapters/<sha256>/<file name>` (`ModelStore.adapterFile(for:)`). Content keys
// make the pinned revision and the digest one fact: two catalog entries for the same bytes share
// a file, two revisions of one path never collide, and a file is used only after its SHA-256
// matched the catalog's (`adapter.json` beside it records the verification).

import CryptoKit
import Foundation
import MLXToolKit

/// Whether a run may fetch a missing adapter itself (contract 1.53.0).
public enum AdapterFetchPolicy: Sendable, Equatable {
    /// A run naming an adapter that is not on disk downloads it first, as `prepare` downloads a
    /// package's weights. The default.
    case onDemand
    /// A run naming an adapter that is not on disk is refused with
    /// `EngineError.adapterNotMaterialized`. The host previews the download
    /// (`adapterMaterializationPreview`), asks the operator, and fetches with `prepareAdapters`.
    /// For a server that must not download without consent.
    case preparedOnly
}

/// Streaming SHA-256 of a file — 8 MB reads, so a multi-GB adapter never sits in memory.
enum AdapterDigest {
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The same, off the caller's executor: hashing a large file on the engine actor would stall
    /// every other engine call for its duration.
    static func sha256Detached(of file: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try sha256(of: file) }.value
    }
}

extension WeightMaterializing {
    /// Download ONE file of `repo` at `revision` to exactly `destination` (contract 1.53.0) — the
    /// adapter path. The default stages it through `materialize(_:into:)` in a deterministic
    /// `.download` directory beside the destination (so an interrupted transfer resumes from its
    /// chunk ledger), then moves the file into place. Any materializer gets it for free; one that
    /// can write to a path directly may override it.
    ///
    /// The source's glob is the path itself, so a top-level name also matches the same name in a
    /// subfolder (the hub's allow-pattern rule) — such a sibling is downloaded and discarded with
    /// the staging directory, never used.
    public func materializeFile(repo: String, revision: String, path: String,
                                to destination: URL) async throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appending(path: ".download", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try await materialize([WeightSource(role: "adapter", repo: repo, revision: revision,
                                            matching: [path])],
                              into: staging)
        guard let landed = ModelStore(root: staging).directory(for: repo)?.appending(path: path),
              fm.fileExists(atPath: landed.path) else {
            throw WeightMaterializer.MaterializeError.httpStatus("\(repo)@\(revision)/\(path)", 404)
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: landed, to: destination)
        try? fm.removeItem(at: staging)
    }
}
