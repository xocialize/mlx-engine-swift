// WeightMaterializer.swift — the ENGINE-EXECUTED first-run download of a package's declared
// weight sources (contract 1.24: the engine executes materialization; `load()` just loads).
//
// `MLXServeEngine.resident()` runs this before `load()` whenever a `WeightSourcing`
// configuration reports missing sources and a store root is set, so every package gains
// first-run materialization without shipping its own downloader. Packages opt out via
// `SelfMaterializing` (non-HF hosts, wrappers whose runtime downloads internally); packages
// that still self-materialize defensively stay correct — their own missing-check runs after
// this and finds nothing left.
//
// Files land in the FLAT store layout, `ModelStore.directory(for:)/<path>` (the fleet
// convention established by the per-package executors this replaces); the MS-2 default probe
// accepts that layout alongside the hub-client snapshot layout.
//
// The transport encodes three hard-won fixes (lifted from the mage-flow-swift reference
// implementation, its commits cf45682 + 6faa4cb):
//
// 1. Files are streamed CHUNK-WISE through a URLSessionDataDelegate — deliberately not
//    swift-huggingface's snapshot API, whose per-file Progress never delivers byte updates
//    during a transfer (fraction sits at 0% for a whole multi-GB file) and which double-stores
//    every artifact through its own cache; and deliberately not per-byte
//    `URLSession.AsyncBytes` iteration, which collapses to ~1 MB/s in unoptimized (-Onone)
//    builds. Delegate `Data` chunks arrive at ~64 KB–1 MB regardless of optimization level.
//
// 2. Byte deltas from delegate-queue threads BRIDGE back into task context via `AsyncStream`:
//    `WeightDownloadProgress.sink` is a TaskLocal, so a report made on a URLSession delegate
//    thread reads an UNBOUND sink and silently vanishes. The reporter child task inherits the
//    caller's binding; the delegate threads only yield byte totals.
//
// 3. Large files (>= 64 MB) download as PARALLEL RANGED CHUNKS written at their offsets into a
//    preallocated file (the hf_transfer design): HF's resolve endpoint for xet-backed repos
//    reconstructs through the CAS bridge at ~0.5 MB/s per cold connection (measured; classic
//    LFS serves ~50 MB/s single-stream) — 8 ranged connections aggregate back to 60–65 MB/s.
//
// Enumeration rides the engine's existing metadata seam (`HubMetadataProviding` — one public
// GET against the HF tree API), so this target still carries no hub-client dependency.

import Foundation
import MLXHubMetadata
import MLXToolKit

/// The executor seam `MLXServeEngine` drives pre-`load()`. Injectable so engine tests exercise
/// the hook without a network; the live implementation is `WeightMaterializer`.
public protocol WeightMaterializing: Sendable {
    /// Download every `source` into `root` (flat `ModelStore` layout), forwarding byte-accurate
    /// progress to `WeightDownloadProgress` (bound by the caller). Idempotent at file level:
    /// a file already present at its full size is skipped.
    func materialize(_ sources: [WeightSource], into root: URL) async throws
}

public struct WeightMaterializer: WeightMaterializing {

    public enum MaterializeError: Error, LocalizedError {
        case badRepoId(String)
        case httpStatus(String, Int)
        case sizeMismatch(String)
        public var errorDescription: String? {
            switch self {
            case .badRepoId(let id): return "Malformed weight-source repo id '\(id)' (want org/name)."
            case .httpStatus(let path, let code): return "Download of \(path) failed (HTTP \(code))."
            case .sizeMismatch(let path): return "Download of \(path) ended with the wrong size."
            }
        }
    }

    private static let parallelThreshold: UInt64 = 64 << 20
    private static let chunkSize: Int64 = 64 << 20
    private static let workers = 8

    /// File listing per repo (the engine shares its `hubMetadata` provider here).
    private let listing: any HubMetadataProviding
    /// Host files are resolved against: `<endpoint>/<repo>/resolve/<revision>/<path>`. Tests
    /// point this at a `file://` tree; the default is the public hub.
    private let endpoint: URL
    /// Explicit token override; `nil` resolves the HF convention at request time
    /// (`HF_TOKEN` env, then `~/.cache/huggingface/token`).
    private let token: String?

    public init(listing: any HubMetadataProviding = HubMetadataClient(),
                endpoint: URL = URL(string: "https://huggingface.co")!,
                token: String? = nil) {
        self.listing = listing
        self.endpoint = endpoint
        self.token = token
    }

    /// Download every `source` into `root`. Progress is byte-weighted and monotonic across ALL
    /// sources' files.
    public func materialize(_ sources: [WeightSource], into root: URL) async throws {
        let store = ModelStore(root: root)

        // Enumerate everything first so the fraction denominator is global. Glob semantics match
        // the MS-2 probe and the MS-3 preview (`WeightSourceProbe.matches`), so what gets fetched
        // is exactly what was previewed and what the probe will call present.
        struct Item {
            let repo: String; let revision: String; let path: String
            let size: UInt64; let destination: URL
        }
        var items: [Item] = []
        for source in sources {
            guard source.repo.split(separator: "/").count == 2,
                  let destination = store.directory(for: source.repo) else {
                throw MaterializeError.badRepoId(source.repo)
            }
            let revision = source.revision ?? "main"
            let entries = try await listing.files(repo: source.repo, revision: source.revision)
            for entry in entries {
                let globs = source.matching ?? []
                let matches = globs.isEmpty
                    || globs.contains { WeightSourceProbe.matches(path: entry.path, glob: $0) }
                guard matches else { continue }
                let dest = destination.appending(path: entry.path)
                // Skip files already fully present (source-level resume).
                if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
                   (attrs[.size] as? UInt64) == entry.size { continue }
                items.append(Item(repo: source.repo, revision: revision, path: entry.path,
                                  size: entry.size, destination: dest))
            }
        }
        guard !items.isEmpty else { return }
        let totalBytes = max(items.reduce(UInt64(0)) { $0 + $1.size }, 1)

        // Deltas from every worker funnel through one counter, then BRIDGE back into task
        // context via AsyncStream (fix 2 in the header).
        let started = Date()
        var streamContinuation: AsyncStream<Int64>.Continuation!
        let totals = AsyncStream<Int64>(bufferingPolicy: .bufferingNewest(1)) { streamContinuation = $0 }
        let continuation = streamContinuation!
        let reporter = Task {
            for await transferred in totals {
                WeightDownloadProgress.report(
                    fraction: min(Double(transferred) / Double(totalBytes), 1.0),
                    bytesPerSecond: Double(transferred) / max(Date().timeIntervalSince(started), 0.001))
            }
        }
        let counter = ByteCounter { transferred in
            continuation.yield(transferred)
        }
        do {
            for item in items {
                try await downloadItem(
                    repo: item.repo, revision: item.revision, path: item.path,
                    size: item.size, to: item.destination, counter: counter)
            }
        } catch {
            continuation.finish()
            await reporter.value
            throw error
        }
        continuation.finish()
        await reporter.value
        WeightDownloadProgress.report(fraction: 1.0, bytesPerSecond: nil)
    }

    // MARK: one file

    private func downloadItem(
        repo: String, revision: String, path: String, size: UInt64, to destination: URL,
        counter: ByteCounter
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var request = URLRequest(url: endpoint.appending(path: "\(repo)/resolve/\(revision)/\(path)"))
        if let token = token ?? Self.hfToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)

        do {
            if size >= Self.parallelThreshold {
                try await downloadParallel(request: request, size: Int64(size),
                                           partial: partial, counter: counter)
            } else {
                let handle = try FileHandle(forWritingTo: partial)
                do {
                    try await Self.stream(request, to: handle, expect206: false, counter: counter)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if size > 0 {
            let final = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size])
                as? UInt64) ?? 0
            guard final == size else { throw MaterializeError.sizeMismatch(path) }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Parallel ranged chunks written at their offsets into a preallocated file (fix 3).
    private func downloadParallel(
        request: URLRequest, size: Int64, partial: URL, counter: ByteCounter
    ) async throws {
        let pre = try FileHandle(forWritingTo: partial)
        try pre.truncate(atOffset: UInt64(size))
        try pre.close()

        var chunks: [(start: Int64, end: Int64)] = []
        var offset: Int64 = 0
        while offset < size {
            chunks.append((offset, Swift.min(offset + Self.chunkSize, size) - 1))
            offset += Self.chunkSize
        }
        let queue = ChunkQueue(chunks)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Swift.min(Self.workers, chunks.count) {
                group.addTask {
                    while let chunk = queue.next() {
                        try Task.checkCancellation()
                        var req = request
                        req.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
                        let handle = try FileHandle(forWritingTo: partial)
                        do {
                            try handle.seek(toOffset: UInt64(chunk.start))
                            try await Self.stream(req, to: handle, expect206: true, counter: counter)
                            try handle.close()
                        } catch {
                            try? handle.close()
                            throw error
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private final class ChunkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [(start: Int64, end: Int64)]
        init(_ chunks: [(start: Int64, end: Int64)]) { self.chunks = chunks }
        func next() -> (start: Int64, end: Int64)? {
            lock.lock(); defer { lock.unlock() }
            return chunks.isEmpty ? nil : chunks.removeFirst()
        }
    }

    // MARK: transport

    /// Chunk-wise delegate streaming (`didReceive Data`) — see fix 1 in the header for why this
    /// is neither `URLSession.bytes` nor a hub client's snapshot API.
    private static func stream(
        _ request: URLRequest, to handle: FileHandle, expect206: Bool, counter: ByteCounter
    ) async throws {
        let delegate = StreamingDelegate(handle: handle, counter: counter, expect206: expect206)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.continuation = cont
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        try Task.checkCancellation()
    }

    private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let counter: ByteCounter
        let expect206: Bool
        var continuation: CheckedContinuation<Void, Error>?
        private var failedStatus: Int?

        init(handle: FileHandle, counter: ByteCounter, expect206: Bool) {
            self.handle = handle
            self.counter = counter
            self.expect206 = expect206
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            // Non-HTTP responses (file:// in tests) carry no status to check.
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) || (expect206 && http.statusCode != 206) {
                failedStatus = http.statusCode
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            try? handle.write(contentsOf: data)
            counter.add(Int64(data.count))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let cont = continuation
            continuation = nil
            if let failedStatus {
                cont?.resume(throwing: MaterializeError.httpStatus(
                    task.originalRequest?.url?.lastPathComponent ?? "?", failedStatus))
            } else if let error {
                cont?.resume(throwing: error)
            } else {
                cont?.resume()
            }
        }
    }

    /// Cross-worker byte total with throttled (~4/s) reporting.
    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Int64 = 0
        private var lastReport = Date.distantPast
        private let onTotal: (Int64) -> Void
        init(onTotal: @escaping (Int64) -> Void) { self.onTotal = onTotal }
        func add(_ n: Int64) {
            lock.lock()
            total += n
            let snapshot = total
            let due = Date().timeIntervalSince(lastReport) > 0.25
            if due { lastReport = Date() }
            lock.unlock()
            if due { onTotal(snapshot) }
        }
    }

    /// HF token: env first, then the CLI token file (upstream convention).
    private static func hfToken() -> String? {
        if let t = ProcessInfo.processInfo.environment["HF_TOKEN"], !t.isEmpty { return t }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/token")
        return (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
