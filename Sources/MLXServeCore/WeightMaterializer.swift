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
// 4. Interrupted transfers RESUME at chunk granularity and transient failures RETRY inside the
//    executor (AB-A-0016). A field receipt: one dropped connection 21 minutes into a ~60 GB pack
//    discarded ~28 GB of a ~35 GB file and surfaced terminal failure to the consumer. Completed
//    chunks are now recorded in a `ChunkLedger` sidecar, so a drop costs one 64 MB chunk; and
//    transient `URLError`s (-1005/-1001/-1009 and kin) plus 429/5xx are retried with bounded
//    backoff before anything propagates. See `ChunkLedger.swift` for why a surviving partial was
//    previously unsafe to keep rather than merely unkept.
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
        /// A transfer ended cleanly but short of the bytes it promised — treated as transient and
        /// retried, because a silently-truncated chunk is how a preallocated file acquires a hole.
        case truncated(String)
        public var errorDescription: String? {
            switch self {
            case .badRepoId(let id): return "Malformed weight-source repo id '\(id)' (want org/name)."
            case .httpStatus(let path, let code): return "Download of \(path) failed (HTTP \(code))."
            case .sizeMismatch(let path): return "Download of \(path) ended with the wrong size."
            case .truncated(let path): return "Download of \(path) ended early."
            }
        }
    }

    /// How hard the executor tries before a transient network fault becomes the consumer's problem.
    ///
    /// The defaults are the requester's (AB-A-0016): the first attempt plus three retries at
    /// 15 s / 45 s / 120 s. Long on purpose — a Wi-Fi flap or a hub throttle is not over in one
    /// second, and against a multi-hour materialization three minutes of patience is free, while a
    /// surfaced failure costs the user the whole run.
    public struct RetryPolicy: Sendable, Equatable {
        /// Total attempts, the first one included. `1` disables retrying.
        public var maxAttempts: Int
        /// Delay before attempt 2, 3, … The last value repeats if attempts outrun the list.
        public var backoff: [Duration]

        public init(maxAttempts: Int, backoff: [Duration]) {
            self.maxAttempts = maxAttempts
            self.backoff = backoff
        }

        public static let `default` = RetryPolicy(
            maxAttempts: 4, backoff: [.seconds(15), .seconds(45), .seconds(120)])
        /// Fail on the first fault — the pre-1.37.0 behavior, and what tests want.
        public static let none = RetryPolicy(maxAttempts: 1, backoff: [])

        func delay(beforeAttempt attempt: Int) -> Duration {
            guard !backoff.isEmpty else { return .zero }
            return backoff[Swift.min(attempt - 2, backoff.count - 1)]
        }
    }

    /// A transport error plus how many bytes the failed attempt had already reported to the
    /// progress counter. Retrying re-transfers them, so they must be rolled back out of the total
    /// or the fraction climbs past 100% and the rate is fiction.
    private struct TransportFailure: Error {
        let underlying: Error
        let bytesWritten: Int64
    }

    private static let parallelThreshold: UInt64 = 64 << 20
    /// Owned by `ChunkLedger` — the ledger's decomposition and this downloader's must be the same
    /// number or no resume ever validates. See the note on `ChunkLedger.chunkSize`.
    private static let chunkSize: Int64 = ChunkLedger.chunkSize
    private static let workers = 8

    /// File listing per repo (the engine shares its `hubMetadata` provider here).
    private let listing: any HubMetadataProviding
    /// Host files are resolved against: `<endpoint>/<repo>/resolve/<revision>/<path>`. Tests
    /// point this at a `file://` tree; the default is the public hub.
    private let endpoint: URL
    /// The hub token, resolved **per request** through the shared chain (env → Keychain → CLI
    /// token file). A closure rather than a stored `String?` because a sandboxed host keeps its
    /// token in the Keychain and can change it mid-session: a value captured at init would pin
    /// whatever was true when the engine was constructed (AB-A-0016 ask 3).
    private let tokenProvider: @Sendable () -> String?
    /// Bounded in-executor retry for transient faults.
    private let retryPolicy: RetryPolicy

    public init(listing: any HubMetadataProviding = HubMetadataClient(),
                endpoint: URL = URL(string: "https://huggingface.co")!,
                tokenProvider: @escaping @Sendable () -> String? = HFTokenStore.shared.provider(),
                retryPolicy: RetryPolicy = .default) {
        self.listing = listing
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.retryPolicy = retryPolicy
    }

    /// Fixed-token convenience. `nil` means **anonymous** here, not "resolve the chain".
    public init(listing: any HubMetadataProviding = HubMetadataClient(),
                endpoint: URL = URL(string: "https://huggingface.co")!,
                token: String?,
                retryPolicy: RetryPolicy = .default) {
        self.init(listing: listing, endpoint: endpoint,
                  tokenProvider: { token }, retryPolicy: retryPolicy)
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
            let size: UInt64; let destination: URL; let url: URL
            /// Bytes a prior interrupted attempt left recoverable in this file's partial.
            let resumable: UInt64
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
                let url = endpoint.appending(path: "\(source.repo)/resolve/\(revision)/\(entry.path)")
                // Asked here, not inside the download, so the progress DENOMINATOR counts what will
                // actually cross the wire. Crediting resumed bytes to the counter instead would
                // make a 28 GB resume report an opening rate of tens of GB/s.
                let resumable = entry.size >= Self.parallelThreshold
                    ? ChunkLedger.resumableBytes(partial: dest.appendingPathExtension("partial"),
                                                 source: url, size: Int64(entry.size))
                    : 0
                items.append(Item(repo: source.repo, revision: revision, path: entry.path,
                                  size: entry.size, destination: dest, url: url,
                                  resumable: resumable))
            }
        }
        guard !items.isEmpty else { return }
        let totalBytes = max(items.reduce(UInt64(0)) { $0 + ($1.size - $1.resumable) }, 1)
        let resumedBytes = items.reduce(UInt64(0)) { $0 + $1.resumable }
        if resumedBytes > 0 {
            print("[Weights] resuming \(resumedBytes / (1 << 20)) MB already transferred across "
                + "\(items.filter { $0.resumable > 0 }.count) interrupted file(s)")
        }

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
                try await downloadItem(url: item.url, path: item.path,
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
        url: URL, path: String, size: UInt64, to destination: URL, counter: ByteCounter
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var request = URLRequest(url: url)
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let partial = destination.appendingPathExtension("partial")

        if size >= Self.parallelThreshold {
            // Resume-capable path. The ledger owns the (partial, sidecar) pair: it either validates
            // both and reports what a prior attempt completed, or resets and preallocates.
            let ledger = try ChunkLedger.prepare(partial: partial, source: url, size: Int64(size))
            do {
                try await downloadParallel(request: request, size: Int64(size), path: path,
                                           partial: partial, ledger: ledger, counter: counter)
            } catch {
                // KEEP the partial and its sidecar — together they ARE the resume state, and the
                // next attempt costs one 64 MB chunk instead of the whole file. Cancellation lands
                // here too, which is the point: a user who stops a 35 GB pull can continue it.
                ledger.suspend()
                throw error
            }
            // A preallocated file is its final size from the moment it is created, so the size
            // guard the sequential path relies on proves nothing here — it would wave through a
            // file full of holes. The ledger is the only honest completeness statement.
            guard ledger.isComplete(for: Int64(size)) else {
                ledger.suspend()
                throw MaterializeError.truncated(path)
            }
            ledger.finish()
        } else {
            // Below the parallel threshold a restart costs less than one chunk, so this path keeps
            // no bookkeeping — and therefore leaves behind no partial it could not verify.
            ChunkLedger.discard(partial: partial)
            do {
                try await withRetry(counter: counter) {
                    try? FileManager.default.removeItem(at: partial)
                    FileManager.default.createFile(atPath: partial.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: partial)
                    do {
                        _ = try await Self.stream(request, to: handle,
                                                  expect206: false, counter: counter)
                        try handle.synchronize()
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
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: retry

    /// Run `body`, retrying transient transport faults with bounded backoff before letting anything
    /// reach the consumer (AB-A-0016 ask 1).
    ///
    /// Only ``TransportFailure`` is considered — it carries the byte count the failed attempt
    /// already reported, which has to come back out of the progress total before those same bytes
    /// are transferred a second time.
    private func withRetry(counter: ByteCounter, _ body: () async throws -> Void) async throws {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                try await body()
                return
            } catch let failure as TransportFailure {
                if failure.bytesWritten > 0 { counter.add(-failure.bytesWritten) }
                guard attempt < retryPolicy.maxAttempts,
                      Self.isTransient(failure.underlying) else { throw failure.underlying }
                let delay = retryPolicy.delay(beforeAttempt: attempt + 1)
                print("[Weights] transient fault — \(failure.underlying.localizedDescription); "
                    + "retrying (attempt \(attempt + 1)/\(retryPolicy.maxAttempts)) in \(delay)")
                try await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }

    /// Faults worth another attempt: the link dropped, the name did not resolve, the hub asked us
    /// to slow down, or a response ended early. Deliberately NOT cancellation (the user meant it)
    /// and not a 401/403/404, which will say the same thing every time.
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError { return transientURLCodes.contains(urlError.code) }
        if let materialize = error as? MaterializeError {
            switch materialize {
            case .httpStatus(_, let code):
                // 429 is the one a token makes rarer: anonymous hub traffic is limited per shared
                // source IP, an authenticated request per account.
                return code == 408 || code == 429 || (500...599).contains(code)
            case .truncated: return true
            case .badRepoId, .sizeMismatch: return false
            }
        }
        return false
    }

    static let transientURLCodes: Set<URLError.Code> = [
        .networkConnectionLost,     // -1005 — the failure in the field receipt
        .timedOut,                  // -1001
        .notConnectedToInternet,    // -1009
        .cannotConnectToHost,       // -1004
        .cannotFindHost,            // -1003
        .dnsLookupFailed,           // -1006
        .resourceUnavailable,       // -1008
        .badServerResponse,         // -1011
    ]

    /// Parallel ranged chunks written at their offsets into a preallocated file (fix 3), skipping
    /// whatever a prior attempt already recorded and retrying each chunk on its own (fix 4).
    ///
    /// Preallocation and validation belong to `ledger` — by the time this runs, `partial` is either
    /// a fresh full-size file or the survivor of an interrupted attempt whose completed chunks the
    /// ledger vouches for.
    private func downloadParallel(
        request: URLRequest, size: Int64, path: String, partial: URL,
        ledger: ChunkLedger, counter: ByteCounter
    ) async throws {
        let remaining = ChunkLedger.plan(size: size, chunkSize: Self.chunkSize)
            .filter { !ledger.contains($0) }
        guard !remaining.isEmpty else { return }

        let queue = ChunkQueue(remaining)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Swift.min(Self.workers, remaining.count) {
                group.addTask {
                    while let chunk = queue.next() {
                        try Task.checkCancellation()
                        try await self.withRetry(counter: counter) {
                            var req = request
                            req.setValue("bytes=\(chunk.start)-\(chunk.end)",
                                         forHTTPHeaderField: "Range")
                            let handle = try FileHandle(forWritingTo: partial)
                            let written: Int64
                            do {
                                try handle.seek(toOffset: UInt64(chunk.start))
                                written = try await Self.stream(req, to: handle,
                                                                expect206: true, counter: counter)
                                // fsync the DATA before the ledger is allowed to claim it, so the
                                // bookkeeping can never run ahead of what the file actually holds.
                                try handle.synchronize()
                                try handle.close()
                            } catch {
                                try? handle.close()
                                throw error
                            }
                            // A clean close short of the requested range is how a preallocated file
                            // silently acquires a hole. Treat it as a transport fault, not success.
                            guard written == chunk.length else {
                                throw TransportFailure(underlying: MaterializeError.truncated(path),
                                                       bytesWritten: written)
                            }
                        }
                        try ledger.record(chunk)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private final class ChunkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Chunk]
        init(_ chunks: [Chunk]) { self.chunks = chunks }
        func next() -> Chunk? {
            lock.lock(); defer { lock.unlock() }
            return chunks.isEmpty ? nil : chunks.removeFirst()
        }
    }

    // MARK: transport

    /// Chunk-wise delegate streaming (`didReceive Data`) — see fix 1 in the header for why this
    /// is neither `URLSession.bytes` nor a hub client's snapshot API.
    /// - Returns: bytes written by this attempt.
    /// - Throws: ``TransportFailure`` — always, so the retry layer can un-count a failed attempt's
    ///   bytes before they are transferred again.
    @discardableResult
    private static func stream(
        _ request: URLRequest, to handle: FileHandle, expect206: Bool, counter: ByteCounter
    ) async throws -> Int64 {
        let delegate = StreamingDelegate(handle: handle, counter: counter, expect206: expect206)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    delegate.continuation = cont
                    session.dataTask(with: request).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch {
            throw TransportFailure(underlying: error, bytesWritten: delegate.written)
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw TransportFailure(underlying: error, bytesWritten: delegate.written)
        }
        return delegate.written
    }

    private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let counter: ByteCounter
        let expect206: Bool
        var continuation: CheckedContinuation<Void, Error>?
        private var failedStatus: Int?
        /// Bytes this attempt wrote. Mutated only on the session's serial delegate queue and read
        /// only after the continuation resumes (which happens on that same queue, after the last
        /// `didReceive`), so the ordering that makes this safe is the delegate contract itself.
        private(set) var written: Int64 = 0

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
            written += Int64(data.count)
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
}
