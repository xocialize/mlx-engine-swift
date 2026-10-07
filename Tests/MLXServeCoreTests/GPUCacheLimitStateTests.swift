//
//  GPUCacheLimitStateTests.swift
//  MLXServeCoreTests
//
//  AB-A-0130 — in a `swift test` runner the engine's init-time pool-cap write was the process's
//  first MLX touch and failed, GPU work ran anyway, and the pool grew to 23 GB while
//  `gpuPoolSnapshot()` reported the cap. These drive the write's state machine against a stand-in
//  for MLX, so the retry, the precedence and the reporting are provable without a GPU.
//

import Foundation
import Testing
@testable import MLXServeCore

/// MLX's process-global cap, as the engine sees it: the first `failures` writes fail (the
/// first-touch metallib miss), and the getter keeps mlx-swift's memo semantics — it echoes every
/// write, applied or not.
private final class FakeMLXCap: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var allocatorLimit: Int?
    private var memo: Int?
    private var writeCount = 0
    private var warningLines: [String] = []

    init(failures: Int) { failuresLeft = failures }

    var writer: GPUCacheLimitState.Writer {
        GPUCacheLimitState.Writer(write: { self.write($0) }, memoizedLimit: { self.read { $0.memo } })
    }

    /// What the allocator actually holds, how many writes reached it, and what was warned.
    var applied: Int? { read { $0.allocatorLimit } }
    var writes: Int { read { $0.writeCount } }
    var warnings: [String] { read { $0.warningLines } }

    func warn(_ line: String) { lock.lock(); warningLines.append(line); lock.unlock() }

    /// A host's own write after engine construction, which lands.
    func hostWrites(_ bytes: Int) {
        lock.lock()
        memo = bytes
        allocatorLimit = bytes
        lock.unlock()
    }

    private func write(_ bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        memo = bytes                                  // mlx-swift stores this BEFORE calling MLX
        guard failuresLeft == 0 else {
            failuresLeft -= 1
            return false
        }
        allocatorLimit = bytes
        return true
    }

    private func read<T>(_ body: (FakeMLXCap) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

private let cap: UInt64 = 2_147_483_648

private func state(_ fake: FakeMLXCap, intended: UInt64? = cap) -> GPUCacheLimitState {
    GPUCacheLimitState(intendedBytes: intended, writer: fake.writer, warn: { fake.warn($0) })
}

@Test func aWriteThatLandsAtInitIsApplied() {
    let fake = FakeMLXCap(failures: 0)
    let limit = state(fake)
    #expect(limit.current == .applied(cap))
    #expect(limit.applied == cap)
    #expect(limit.snapshotLimit == .applied(cap))
    limit.applyIfPending()
    #expect(fake.writes == 1)                         // nothing left to retry
}

// The swift-test case: the init write fails, GPU work is about to run, and the retry lands the
// cap. Until it does, nothing claims a cap — not `applied`, and not the snapshot, even though the
// getter (the memo) already says 2 GiB.
@Test func aFailedInitWriteIsRetriedBeforeGPUWorkAndOnlyThenRecorded() {
    let fake = FakeMLXCap(failures: 1)
    let limit = state(fake)
    #expect(limit.current == .pending(cap))
    #expect(limit.applied == nil)
    #expect(limit.snapshotLimit == .mlxDefault)
    #expect(fake.applied == nil)

    limit.applyIfPending()
    #expect(limit.current == .applied(cap))
    #expect(limit.applied == cap)
    #expect(fake.applied == Int(cap))
    #expect(fake.writes == 2)
    #expect(fake.warnings.isEmpty)
}

// Last write wins: a host that wrote its own cap after the engine's failed write keeps it, and the
// engine stops retrying rather than re-asserting.
@Test func aHostWriteAfterAFailedEngineWriteWins() {
    let fake = FakeMLXCap(failures: 1)
    let limit = state(fake)
    fake.hostWrites(500_000_000)
    limit.applyIfPending()
    #expect(limit.current == .yielded)
    #expect(fake.applied == 500_000_000)
    #expect(fake.writes == 1)
    #expect(limit.snapshotLimit == .live)
    #expect(limit.applied == nil)
}

// A retry that keeps failing leaves GPU work under MLX's default limit. It says so once, not per run.
@Test func aRetryThatKeepsFailingWarnsOnceAndStaysPending() {
    let fake = FakeMLXCap(failures: 10)
    let limit = state(fake)
    for _ in 0..<3 { limit.applyIfPending() }
    #expect(limit.current == .pending(cap))
    #expect(fake.warnings.count == 1)
    #expect(fake.warnings.first?.contains("2.15 GB") == true)
    #expect(fake.warnings.first?.contains("AB-A-0130") == true)
}

@Test func anUnmanagedEngineNeverWrites() {
    let fake = FakeMLXCap(failures: 0)
    let limit = state(fake, intended: nil)
    limit.applyIfPending()
    #expect(limit.current == .unmanaged)
    #expect(fake.writes == 0)
    #expect(limit.snapshotLimit == .live)
}
