// ChunkLedger.swift — which ranged chunks of an in-flight `.partial` are durably complete.
//
// The problem it solves (AB-A-0016, field receipt 2026-08-22). `WeightMaterializer` resumed at
// FILE granularity: a file already on disk at its listed size is skipped, everything else restarts
// from zero. On a ~60 GB pack that meant a single transient drop 21 minutes in, while pulling a
// ~35 GB transformer, discarded ~28 GB of transferred bytes — twice in one afternoon on one machine.
//
// The reason the partial could not simply be kept is structural, not incidental:
// `downloadParallel` preallocates the full-size file up front and writes ≥64 MB chunks at their
// offsets, so **a half-filled partial is byte-indistinguishable from a complete file with holes of
// zeros** — and the final size guard would wave it straight through, producing a corrupt weight file
// that loads as garbage. Deleting on error was the only safe behavior *absent bookkeeping*. This is
// the bookkeeping; the delete then becomes unnecessary rather than merely unsafe to remove.
//
// Format — a text sidecar next to the partial, `<file>.partial.ranges`:
//
//     mlxengine-chunk-ledger v1
//     size 37580963840
//     url https://huggingface.co/org/repo/resolve/main/model.safetensors
//     r 0 67108863
//     r 67108864 134217727
//
// Append-only, one `r` line per completed chunk, `fsync`'d before the next chunk starts, and
// written only AFTER that chunk's bytes are themselves `fsync`'d — so the ledger is never ahead of
// the data it describes. A torn final line (power loss mid-append) costs that one chunk, not the
// file: lines are appended whole under a lock, so a malformed line can only be the last one and is
// dropped on parse. A malformed line anywhere else means something else wrote the file, and the
// whole ledger is discarded.
//
// Validation is `(url, size)`. That is deliberately the same pair the pre-existing file-level
// resume already trusts — a repo re-quantized under the same revision defeats both identically, and
// inventing a stronger claim here (an etag the tree API does not give us) would be a claim we cannot
// keep.

import Foundation

/// One ranged chunk of a file, inclusive of both bounds — the `Range:` header's own convention.
struct Chunk: Hashable, Sendable {
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }
}

/// Records completed chunks of one `.partial` file. Shared across the download workers, so every
/// mutation takes the lock.
final class ChunkLedger: @unchecked Sendable {

    private static let header = "mlxengine-chunk-ledger v1"

    private let sidecar: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var completed: Set<Chunk>

    private init(sidecar: URL, handle: FileHandle?, completed: Set<Chunk>) {
        self.sidecar = sidecar
        self.handle = handle
        self.completed = completed
    }

    /// The sidecar path for a partial file.
    static func sidecar(for partial: URL) -> URL { partial.appendingPathExtension("ranges") }

    // MARK: opening

    /// Bring the `(partial, sidecar)` pair into a known state and return the ledger for it.
    ///
    /// Either both survive a prior attempt and validate — in which case the partial is kept and the
    /// completed chunks are returned for the caller to skip — or both are reset and the partial is
    /// preallocated to `size`. There is no third outcome: a partial without a ledger is exactly the
    /// unverifiable file described in the header.
    static func prepare(partial: URL, source: URL, size: Int64) throws -> ChunkLedger {
        let sidecar = sidecar(for: partial)
        if let resumed = parse(sidecar: sidecar, partial: partial, source: source, size: size),
           !resumed.isEmpty {
            // REWRITE rather than append. If the prior run died mid-append, the file ends in a torn
            // fragment that `parse` tolerated by dropping — but seeking to the end and appending
            // would weld the next record onto that fragment ("…r 134217728 2013r 0 67108863"),
            // producing a malformed line ABOVE the tail, which the next parse discards wholesale.
            // The crash the tolerance exists for would then still cost the whole file. Writing the
            // validated set back canonically closes that off; it is a few hundred bytes.
            try write(header: sidecar, source: source, size: size, chunks: resumed)
            let handle = try FileHandle(forWritingTo: sidecar)
            try handle.seekToEnd()
            return ChunkLedger(sidecar: sidecar, handle: handle, completed: resumed)
        }

        try? FileManager.default.removeItem(at: sidecar)
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let preallocate = try FileHandle(forWritingTo: partial)
        try preallocate.truncate(atOffset: UInt64(size))
        try preallocate.close()

        try write(header: sidecar, source: source, size: size, chunks: [])
        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.seekToEnd()
        return ChunkLedger(sidecar: sidecar, handle: handle, completed: [])
    }

    /// Write a whole, canonical sidecar — header plus one line per chunk, atomically.
    private static func write(header sidecar: URL, source: URL, size: Int64,
                              chunks: Set<Chunk>) throws {
        var text = "\(header)\nsize \(size)\nurl \(source.absoluteString)\n"
        for chunk in chunks.sorted(by: { $0.start < $1.start }) {
            text += "r \(chunk.start) \(chunk.end)\n"
        }
        try text.write(to: sidecar, atomically: true, encoding: .utf8)
    }

    /// Bytes a prior attempt left recoverable, without touching anything — used while enumerating,
    /// so the progress denominator counts what will actually be transferred rather than restarting
    /// a resumed 35 GB file's fraction at zero.
    static func resumableBytes(partial: URL, source: URL, size: Int64) -> UInt64 {
        let chunks = parse(sidecar: sidecar(for: partial), partial: partial,
                           source: source, size: size) ?? []
        return UInt64(chunks.reduce(0) { $0 + $1.length })
    }

    /// Parse and validate a sidecar against its partial. Returns nil when anything does not line
    /// up — a missing file, a wrong-size partial, a different source, an unparseable body.
    private static func parse(sidecar: URL, partial: URL, source: URL, size: Int64) -> Set<Chunk>? {
        // The partial must be exactly the preallocated size; anything else is not the file this
        // ledger describes.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
              (attributes[.size] as? NSNumber)?.int64Value == size,
              let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }

        var lines = text.components(separatedBy: "\n")
        // An append is a whole line ending in "\n", so a trailing fragment can only be a torn last
        // write. Drop it; anything malformed further up was not written by us.
        if let last = lines.last, last.isEmpty { lines.removeLast() } else if !lines.isEmpty {
            lines.removeLast()
        }

        var iterator = lines.makeIterator()
        guard iterator.next() == header,
              let sizeLine = iterator.next(), sizeLine == "size \(size)",
              let urlLine = iterator.next(), urlLine == "url \(source.absoluteString)"
        else { return nil }

        let planned = Set(plan(size: size))
        var completed: Set<Chunk> = []
        while let line = iterator.next() {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "r",
                  let start = Int64(parts[1]), let end = Int64(parts[2]) else { return nil }
            let chunk = Chunk(start: start, end: end)
            // Only chunks from the deterministic plan count: a range that is not one of ours means
            // the file was written by something else, and stitching it would be a guess.
            guard planned.contains(chunk) else { return nil }
            completed.insert(chunk)
        }
        return completed
    }

    /// The ranged-chunk size, defined **here and only here**.
    ///
    /// It is deliberately not a second constant next to the downloader: a ledger written under one
    /// value and read under another would decompose the same file differently, every recorded range
    /// would fail the "is this one of ours" check, and every resume would silently degrade to a
    /// full re-pull — the exact failure this file exists to prevent, reintroduced by a stale copy.
    static let chunkSize: Int64 = 64 << 20

    /// The fixed chunk decomposition of a file — deterministic, so a ledger written by one run is
    /// readable by the next.
    static func plan(size: Int64, chunkSize: Int64 = ChunkLedger.chunkSize) -> [Chunk] {
        var chunks: [Chunk] = []
        var offset: Int64 = 0
        while offset < size {
            chunks.append(Chunk(start: offset, end: Swift.min(offset + chunkSize, size) - 1))
            offset += chunkSize
        }
        return chunks
    }

    // MARK: recording

    func contains(_ chunk: Chunk) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completed.contains(chunk)
    }

    var completedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return completed.reduce(0) { $0 + $1.length }
    }

    /// Record a chunk whose bytes are already `fsync`'d. Durable before it returns, so the ledger
    /// can never claim more than the file holds.
    func record(_ chunk: Chunk) throws {
        lock.lock(); defer { lock.unlock() }
        completed.insert(chunk)
        guard let handle else { return }
        try handle.write(contentsOf: Data("r \(chunk.start) \(chunk.end)\n".utf8))
        try handle.synchronize()
    }

    /// Whether every planned chunk is recorded — the honest completeness guard for a preallocated
    /// file, whose *size* proves nothing.
    func isComplete(for size: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Set(Self.plan(size: size)).isSubset(of: completed)
    }

    /// Close and remove the sidecar — the file is done and the bookkeeping has no further claim.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: sidecar)
    }

    /// Release the file handle but LEAVE the sidecar: the download failed and this is the resume
    /// state the next attempt reads.
    func suspend() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// Drop any resume state for a partial (used by the sequential path, which keeps none).
    static func discard(partial: URL) {
        try? FileManager.default.removeItem(at: sidecar(for: partial))
    }
}
