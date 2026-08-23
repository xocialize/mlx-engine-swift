import Foundation
import Testing
import MLXHubMetadata
import MLXToolKit
@testable import MLXServeCore

// Chunk-granular resume + bounded retry (AB-A-0016).
//
// The field failure these cover: one dropped connection 21 minutes into a ~60 GB pack discarded
// ~28 GB of a ~35 GB file, because a preallocated partial with no record of which chunks landed is
// indistinguishable from a complete file full of zero-holes. The ledger is that record; these tests
// pin every decision it makes, plus the two transport behaviors reachable without a live server.
//
// What is NOT proven here: resume across a real interrupted HTTPS transfer with ranged requests.
// That needs a server that honors `Range` and can drop mid-stream; the requester has a ready
// validation bed (a 35 GB pull + Network Link Conditioner) and it is the honest place for it.

private let chunk: Int64 = 64 << 20

private func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chunk-resume-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private struct StubListing: HubMetadataProviding {
    let entries: [HubFileEntry]
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] { entries }
}

// MARK: - Plan

@Test func chunkPlanCoversTheFileExactlyAndInclusively() {
    let exact = ChunkLedger.plan(size: chunk * 2, chunkSize: chunk)
    #expect(exact.count == 2)
    #expect(exact[0] == Chunk(start: 0, end: chunk - 1))
    #expect(exact[1] == Chunk(start: chunk, end: chunk * 2 - 1))

    let ragged = ChunkLedger.plan(size: chunk + 10, chunkSize: chunk)
    #expect(ragged.count == 2)
    #expect(ragged[1] == Chunk(start: chunk, end: chunk + 9))
    #expect(ragged.reduce(0) { $0 + $1.length } == chunk + 10)
}

// MARK: - Ledger lifecycle

@Test func prepareOnACleanSlatePreallocatesAndStartsEmpty() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.safetensors.partial")
    let source = URL(string: "https://hub.test/org/repo/resolve/main/w.safetensors")!

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 2)
    #expect(ledger.completedBytes == 0)
    let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
    #expect(size?.int64Value == chunk * 2)
    #expect(!ledger.isComplete(for: chunk * 2))
}

@Test func recordedChunksSurviveAndResumeOnTheNextAttempt() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.safetensors.partial")
    let source = URL(string: "https://hub.test/org/repo/resolve/main/w.safetensors")!

    let first = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
    try first.record(Chunk(start: 0, end: chunk - 1))
    try first.record(Chunk(start: chunk, end: chunk * 2 - 1))
    first.suspend()   // the interrupted case: handle closed, sidecar KEPT

    #expect(ChunkLedger.resumableBytes(partial: partial, source: source, size: chunk * 3)
            == UInt64(chunk * 2))

    let second = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
    #expect(second.completedBytes == chunk * 2)
    #expect(second.contains(Chunk(start: 0, end: chunk - 1)))
    #expect(!second.contains(Chunk(start: chunk * 2, end: chunk * 3 - 1)))
    #expect(!second.isComplete(for: chunk * 3))
    try second.record(Chunk(start: chunk * 2, end: chunk * 3 - 1))
    #expect(second.isComplete(for: chunk * 3))
}

@Test func finishRemovesTheSidecarAndSuspendKeepsIt() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.bin.partial")
    let source = URL(string: "https://hub.test/f")!
    let sidecar = ChunkLedger.sidecar(for: partial)

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk)
    try ledger.record(Chunk(start: 0, end: chunk - 1))
    ledger.suspend()
    #expect(FileManager.default.fileExists(atPath: sidecar.path))

    let reopened = try ChunkLedger.prepare(partial: partial, source: source, size: chunk)
    reopened.finish()
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
}

// MARK: - Validation: every way a ledger must be refused

@Test func aPartialOfTheWrongSizeInvalidatesTheLedger() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.bin.partial")
    let source = URL(string: "https://hub.test/f")!

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 2)
    try ledger.record(Chunk(start: 0, end: chunk - 1))
    ledger.suspend()

    // The repo was re-quantized: same path, different size. Nothing may be reused.
    #expect(ChunkLedger.resumableBytes(partial: partial, source: source, size: chunk * 3) == 0)
    let fresh = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
    #expect(fresh.completedBytes == 0)
}

@Test func aDifferentSourceInvalidatesTheLedger() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.bin.partial")
    let source = URL(string: "https://hub.test/org/repo/resolve/main/w.bin")!

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 2)
    try ledger.record(Chunk(start: 0, end: chunk - 1))
    ledger.suspend()

    let other = URL(string: "https://hub.test/org/repo/resolve/v2/w.bin")!
    #expect(ChunkLedger.resumableBytes(partial: partial, source: other, size: chunk * 2) == 0)
}

@Test func aTornFinalLineCostsOneChunkNotTheFile() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.bin.partial")
    let source = URL(string: "https://hub.test/f")!

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
    try ledger.record(Chunk(start: 0, end: chunk - 1))
    try ledger.record(Chunk(start: chunk, end: chunk * 2 - 1))
    ledger.suspend()

    // Simulate a crash mid-append: a third record that never finished its line.
    let sidecar = ChunkLedger.sidecar(for: partial)
    let torn = String("r \(chunk * 2) \(chunk * 3 - 1)".dropLast(4))   // no trailing newline
    let text = try String(contentsOf: sidecar, encoding: .utf8) + torn
    try text.write(to: sidecar, atomically: true, encoding: .utf8)

    // The two complete records survive; only the torn one is lost.
    #expect(ChunkLedger.resumableBytes(partial: partial, source: source, size: chunk * 3)
            == UInt64(chunk * 2))

    // And resuming ON a torn tail must not weld the next record onto the fragment — which would
    // put a malformed line ABOVE the tail and make the round AFTER this one discard everything,
    // costing the whole file for the crash the tolerance was written to survive.
    let resumed = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
    try resumed.record(Chunk(start: chunk * 2, end: chunk * 3 - 1))
    resumed.suspend()
    #expect(ChunkLedger.resumableBytes(partial: partial, source: source, size: chunk * 3)
            == UInt64(chunk * 3))
    #expect(try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
            .isComplete(for: chunk * 3))
}

@Test func aMalformedLineAboveTheEndDiscardsTheWholeLedger() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.bin.partial")
    let source = URL(string: "https://hub.test/f")!

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 3)
    try ledger.record(Chunk(start: 0, end: chunk - 1))
    try ledger.record(Chunk(start: chunk, end: chunk * 2 - 1))
    ledger.suspend()

    let sidecar = ChunkLedger.sidecar(for: partial)
    var lines = try String(contentsOf: sidecar, encoding: .utf8).components(separatedBy: "\n")
    lines[3] = "something else wrote this"      // not a torn tail — a foreign writer
    try lines.joined(separator: "\n").write(to: sidecar, atomically: true, encoding: .utf8)

    #expect(ChunkLedger.resumableBytes(partial: partial, source: source, size: chunk * 3) == 0)
}

@Test func aRangeOutsideThePlanIsRefusedRatherThanStitched() throws {
    let dir = scratch()
    let partial = dir.appendingPathComponent("w.bin.partial")
    let source = URL(string: "https://hub.test/f")!

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: chunk * 2)
    ledger.suspend()

    let sidecar = ChunkLedger.sidecar(for: partial)
    // A plausible-looking range that is not one of ours: half a chunk, unaligned.
    let text = try String(contentsOf: sidecar, encoding: .utf8) + "r 17 4194304\n"
    try text.write(to: sidecar, atomically: true, encoding: .utf8)

    #expect(ChunkLedger.resumableBytes(partial: partial, source: source, size: chunk * 2) == 0)
}

// MARK: - Transport behavior reachable offline

@Test func aFullyRecordedLedgerFinishesTheFileWithoutFetchingAnything() async throws {
    let root = scratch()
    let size = UInt64(chunk * 2)
    let listing = StubListing(entries: [HubFileEntry(path: "big.bin", size: size)])
    // Nothing is served here: any real fetch would fail, so completing proves nothing was fetched.
    let endpoint = URL(fileURLWithPath: "/nonexistent-hub-root")

    let store = ModelStore(root: root)
    let destination = try #require(store.directory(for: "org/big")).appending(path: "big.bin")
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partial = destination.appendingPathExtension("partial")
    let source = endpoint.appending(path: "org/big/resolve/main/big.bin")

    let ledger = try ChunkLedger.prepare(partial: partial, source: source, size: Int64(size))
    for planned in ChunkLedger.plan(size: Int64(size), chunkSize: chunk) { try ledger.record(planned) }
    ledger.suspend()

    let materializer = WeightMaterializer(listing: listing, endpoint: endpoint,
                                          token: nil, retryPolicy: .none)
    try await materializer.materialize([WeightSource(role: "main", repo: "org/big")], into: root)

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(!FileManager.default.fileExists(atPath: ChunkLedger.sidecar(for: partial).path))
}

@Test func aFailedParallelDownloadKEEPSThePartialAndItsLedger() async throws {
    let root = scratch()
    let size = UInt64(chunk * 2)
    let listing = StubListing(entries: [HubFileEntry(path: "big.bin", size: size)])
    let endpoint = URL(fileURLWithPath: "/nonexistent-hub-root")   // every fetch fails

    let materializer = WeightMaterializer(listing: listing, endpoint: endpoint,
                                          token: nil, retryPolicy: .none)
    await #expect(throws: (any Error).self) {
        try await materializer.materialize([WeightSource(role: "main", repo: "org/big")], into: root)
    }

    let store = ModelStore(root: root)
    let destination = try #require(store.directory(for: "org/big")).appending(path: "big.bin")
    let partial = destination.appendingPathExtension("partial")

    // The regression this pins: 1.36.0 and earlier deleted both on failure, which is what turned a
    // 21-minute transfer into a full re-pull.
    #expect(FileManager.default.fileExists(atPath: partial.path))
    #expect(FileManager.default.fileExists(atPath: ChunkLedger.sidecar(for: partial).path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

// MARK: - Retry classification

@Test func transientFaultsRetryAndPermanentOnesDoNot() {
    for code in [URLError.Code.networkConnectionLost, .timedOut, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
        #expect(WeightMaterializer.isTransient(URLError(code)), "\(code) should retry")
    }
    // A user-cancelled run means it: retrying would be the opposite of what was asked.
    #expect(!WeightMaterializer.isTransient(CancellationError()))
    #expect(!WeightMaterializer.isTransient(URLError(.fileDoesNotExist)))

    #expect(WeightMaterializer.isTransient(WeightMaterializer.MaterializeError.httpStatus("f", 429)))
    #expect(WeightMaterializer.isTransient(WeightMaterializer.MaterializeError.httpStatus("f", 503)))
    #expect(WeightMaterializer.isTransient(WeightMaterializer.MaterializeError.truncated("f")))
    // 401/403/404 say the same thing every time; retrying only delays the real message.
    #expect(!WeightMaterializer.isTransient(WeightMaterializer.MaterializeError.httpStatus("f", 401)))
    #expect(!WeightMaterializer.isTransient(WeightMaterializer.MaterializeError.httpStatus("f", 404)))
    #expect(!WeightMaterializer.isTransient(WeightMaterializer.MaterializeError.sizeMismatch("f")))
}

@Test func backoffAdvancesThenHoldsAtTheLastStep() {
    let policy = WeightMaterializer.RetryPolicy.default
    #expect(policy.maxAttempts == 4)
    #expect(policy.delay(beforeAttempt: 2) == .seconds(15))
    #expect(policy.delay(beforeAttempt: 3) == .seconds(45))
    #expect(policy.delay(beforeAttempt: 4) == .seconds(120))
    // Past the declared ladder the last step repeats rather than trapping.
    #expect(policy.delay(beforeAttempt: 9) == .seconds(120))
    #expect(WeightMaterializer.RetryPolicy.none.delay(beforeAttempt: 2) == .zero)
}
