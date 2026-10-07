import Foundation
import MLX

/// Engine-owned policy for MLX's **Metal buffer-recycling pool** (ENGINE-NEEDS N5).
///
/// MLX recycles every freed GPU buffer into a process-global cache that is effectively
/// unbounded by default and never returns memory to the OS. Interactive consumers (chat:
/// llm + embed + tts per turn, each run with new tensor shapes) ratchet the pool by GBs per
/// interaction — it reads as a never-released leak in Activity Monitor (the MLXCompanion
/// 43 GB staircase, 2026-07-05). The engine owns the GPU and the memory budget, so the pool
/// policy lives here beside the governor: `MLXServeEngine` applies the resolved limit **at
/// init**, and if that write fails, retries it before the first package load or run
/// (`GPUCacheLimitState`, AB-A-0130).
///
/// **Precedence is last-write-wins on the process-global setting.** The engine writes at
/// construction; a host that sets `MLX.Memory.cacheLimit` (or the legacy
/// `MLX.GPU.set(cacheLimit:)`) *after* constructing the engine overrides it, and the engine
/// never re-asserts. A host that set a limit *before* constructing the engine gets overwritten
/// (pass `.unmanaged` to keep a pre-set value). Hosts that bounded the pool themselves as a
/// workaround can drop that line once they construct the engine with the default policy.
public struct GPUCacheConfiguration: Sendable, Equatable {

    /// How to bound the pool.
    public enum Limit: Sendable, Equatable {
        /// Derive from the governor's budget: `min(2 GB, 5% of budget)`. The default —
        /// keeps hot-path buffer reuse while everything beyond the cap returns to the OS.
        /// (2 GB suits chat-scale apps; the 5% arm keeps small-budget engines proportional.)
        case automatic
        /// A fixed cap in bytes. `0` disables buffer recycling entirely (correct for one-shot
        /// batch tools, too slow for interactive loops); `UInt64(Int.max)` is effectively
        /// unlimited while still counting as "managed".
        case bytes(UInt64)
        /// Opt out: the engine never touches the process-global setting (MLX's own default —
        /// unbounded — or whatever the host set stays in effect).
        case unmanaged
    }

    /// The pool cap policy. Applied once at engine init.
    public var limit: Limit
    /// Trim (drop) the pool after every engine-driven eviction. Default off — packages
    /// already `clearCache()` in `unload()`, so this is belt-and-braces for hosts that want
    /// eviction to also return pooled transients immediately.
    public var trimAfterEvict: Bool
    /// Trim the pool after every N `run`s — successful or thrown (a burst-shaped host's
    /// "drop the pool between interactions" knob). `nil` (default) or values < 1 disable it.
    public var trimEveryRuns: Int?
    /// Trim the pool when a run ends in `CancellationError` and the cancelled package's
    /// resolved transient activation peak (`QuantFootprint.peakActivationBytes` / the
    /// `FootprintConfigured` hint) is at least this many bytes. A cancelled long run abandons
    /// a pool full of large one-off buffers (the LTX 2.3 multi-GB mid-denoise case — V1 in the
    /// run-lifecycle program), and a cancel is already latency-insensitive, so unlike the other
    /// trim knobs this defaults **on** (1 GiB). `nil` disables it; the `.unmanaged` preset
    /// disables it along with everything else.
    public var trimAfterCancelBytes: UInt64?

    public init(limit: Limit = .automatic,
                trimAfterEvict: Bool = false,
                trimEveryRuns: Int? = nil,
                trimAfterCancelBytes: UInt64? = 1_073_741_824) {  // 1 GiB
        self.limit = limit
        self.trimAfterEvict = trimAfterEvict
        self.trimEveryRuns = trimEveryRuns
        self.trimAfterCancelBytes = trimAfterCancelBytes
    }

    /// The whole-feature opt-out: no limit write, no trims (including cancel hygiene).
    public static let unmanaged = GPUCacheConfiguration(limit: .unmanaged,
                                                        trimAfterCancelBytes: nil)

    /// The byte cap `limit` resolves to against a governor budget; `nil` = leave the
    /// process-global setting untouched.
    public func resolvedLimitBytes(budgetBytes: UInt64) -> UInt64? {
        switch limit {
        case .unmanaged:
            return nil
        case .bytes(let bytes):
            return bytes
        case .automatic:
            return min(2_147_483_648, budgetBytes / 20)  // min(2 GB, 5% of budget)
        }
    }
}

/// The process's FIRST MLX call can fail in a `swift test` runner ("Failed to load the default
/// metallib") while every later call succeeds and GPU work runs (AB-A-0130). Make that first call a
/// harmless read, so the failure never lands on a write the engine depends on.
enum MLXFirstTouch {
    static func warmUp() { _ = try? MLX.withError { _ = Memory.activeMemory } }
}

/// The engine's pool-cap write and its outcome (AB-A-0130).
///
/// One failed attempt at init is not the last word. In a `swift test` runner the write can be the
/// process's first MLX touch, which fails, while GPU work runs regardless, and an unapplied cap lets
/// the pool grow without bound (23 GB in ForgeCore's live tests). So `MLXServeEngine` warms MLX up
/// before the write, retries a failed write before the next package load or run (`applyIfPending`),
/// and records the cap only once a write lands. Lock-protected, so the engine's `nonisolated`
/// readers see the latest outcome without hopping the actor.
final class GPUCacheLimitState: @unchecked Sendable {
    enum Outcome: Equatable {
        /// `.unmanaged` policy: the engine never writes.
        case unmanaged
        /// The engine's write landed.
        case applied(UInt64)
        /// A write failed; the next GPU work retries it first.
        case pending(UInt64)
        /// A host wrote its own cap after the engine's failed write. Last write wins
        /// (`GPUCacheConfiguration`), so the engine stopped retrying.
        case yielded
    }

    /// Where `gpuPoolSnapshot()` takes its limit from, per outcome.
    enum SnapshotLimit: Equatable {
        /// The cap the engine applied (never re-read from MLX — see `GPUPoolSnapshot.current`).
        case applied(UInt64)
        /// MLX's own default. mlx-swift's getter would echo the engine's FAILED write: its setter
        /// stores the value before calling into MLX, so the getter is not evidence.
        case mlxDefault
        /// The live getter: nothing the engine wrote is in it.
        case live
    }

    /// MLX's process-global cap, behind a seam so the retry logic is testable without a GPU.
    struct Writer: Sendable {
        /// Write the cap; false when MLX refused (it throws inside `withError`).
        var write: @Sendable (Int) -> Bool
        /// mlx-swift's memoized getter value. It echoes the last WRITE, applied or not, which is
        /// exactly what tells a host's later write from the engine's own failed one.
        var memoizedLimit: @Sendable () -> Int?

        static let mlx = Writer(
            write: { bytes in (try? MLX.withError { Memory.cacheLimit = bytes }) != nil },
            memoizedLimit: { try? MLX.withError { Memory.cacheLimit } })
    }

    private let lock = NSLock()
    private var outcome: Outcome
    private var warnedUnapplied = false
    private let writer: Writer
    private let warn: @Sendable (String) -> Void

    init(intendedBytes: UInt64?, writer: Writer = .mlx,
         warn: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.writer = writer
        self.warn = warn
        guard let cap = intendedBytes else {
            outcome = .unmanaged
            return
        }
        outcome = writer.write(Self.clamped(cap)) ? .applied(cap) : .pending(cap)
    }

    var current: Outcome {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// The cap in effect from the engine's own write, or nil.
    var applied: UInt64? {
        if case .applied(let bytes) = current { return bytes }
        return nil
    }

    var snapshotLimit: SnapshotLimit {
        switch current {
        case .applied(let bytes): return .applied(bytes)
        case .pending: return .mlxDefault
        case .unmanaged, .yielded: return .live
        }
    }

    /// Retry a failed write; called before every package load or run. A no-op once the cap is
    /// applied, yielded, or unmanaged. If the retry fails too, GPU work goes ahead with MLX's
    /// default pool limit, and that is worth one line: its only symptom is a phys staircase that
    /// reads as a package leak.
    func applyIfPending() {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending(let cap) = outcome else { return }
        let intended = Self.clamped(cap)
        if let memo = writer.memoizedLimit(), memo != intended {
            outcome = .yielded
            return
        }
        if writer.write(intended) {
            outcome = .applied(cap)
        } else if !warnedUnapplied {
            warnedUnapplied = true
            warn(String(format: "[GPUCache] the MLX pool cap (%.2f GB) could not be applied; GPU work "
                         + "proceeds under MLX's default pool limit, so the pool can grow without "
                         + "bound (AB-A-0130)", Double(cap) / 1_000_000_000))
        }
    }

    private static func clamped(_ bytes: UInt64) -> Int { bytes > UInt64(Int.max) ? Int.max : Int(bytes) }
}

/// A point-in-time reading of MLX's process-global GPU buffer accounting, exposed on the
/// engine so consumers get observability **without importing MLX**. The interesting
/// relationship (per turn): `phys_footprint ≈ app baseline + activeBytes + cacheBytes`.
/// A growing `cacheBytes` with flat `activeBytes` is the recycling pool ratcheting (bounded
/// by `cacheLimitBytes` under a managed policy); `activeBytes` climbing across turns means
/// something retains live tensors — that IS a leak, and no cache limit will fix it.
public struct GPUPoolSnapshot: Sendable, Equatable, CustomStringConvertible {
    /// Live tensor bytes (weights + in-flight intermediates).
    public let activeBytes: UInt64
    /// The recycling pool — saturates at `cacheLimitBytes` under a managed policy.
    public let cacheBytes: UInt64
    /// Process-lifetime high-water mark of active + cache.
    public let peakBytes: UInt64
    /// The currently effective pool cap (process-global — reflects the engine's policy OR a
    /// later host write, whichever came last).
    public let cacheLimitBytes: UInt64

    public init(activeBytes: UInt64, cacheBytes: UInt64, peakBytes: UInt64,
                cacheLimitBytes: UInt64) {
        self.activeBytes = activeBytes
        self.cacheBytes = cacheBytes
        self.peakBytes = peakBytes
        self.cacheLimitBytes = cacheLimitBytes
    }

    /// The live process-global reading, or `nil` when the process can't initialize MLX's
    /// Metal device (the allocator getters are the first MLX touch in some CI/test runner
    /// processes — `withError` scopes that failure to a nil instead of the aborting handler).
    ///
    /// Pass `cacheLimitBytes` when the effective pool cap is already known (the engine knows
    /// what it wrote). MLX's `Memory.cacheLimit` *getter* is not a plain read: a cold first
    /// access performs a set-to-current-and-restore swap on the process-global limit — which
    /// the allocator can observe mid-run — and warm reads rely on mlx-swift's internal
    /// memoization behind a serial queue. A known value avoids depending on either. `nil`
    /// keeps the live read (an `.unmanaged` engine has no better source).
    ///
    /// `peakBytes` reads `Memory.peakMemory` — safe, but harness authors beware: that
    /// property's *setter* ignores the assigned value and resets the peak to zero
    /// (`Memory.peakMemory = 0` is the reset idiom; the non-deprecated
    /// `GPU.resetPeakMemory()` is equivalent).
    public static func current(cacheLimitBytes: UInt64? = nil) -> GPUPoolSnapshot? {
        try? MLX.withError {
            GPUPoolSnapshot(
                activeBytes: UInt64(max(0, Memory.activeMemory)),
                cacheBytes: UInt64(max(0, Memory.cacheMemory)),
                peakBytes: UInt64(max(0, Memory.peakMemory)),
                cacheLimitBytes: cacheLimitBytes ?? UInt64(max(0, Memory.cacheLimit)))
        }
    }

    /// The reading while an engine's own cap write has not landed (AB-A-0130). The limit reported is
    /// MLX's default pool cap, which is its memory limit (`MetalAllocator` starts with
    /// `max_pool_size_ = block_limit_`), read through `Memory.memoryLimit` — a plain
    /// `mlx_get_memory_limit`, unlike the `cacheLimit` getter, which would echo the failed write.
    static func currentUnderMLXDefaultLimit() -> GPUPoolSnapshot? {
        try? MLX.withError {
            GPUPoolSnapshot(
                activeBytes: UInt64(max(0, Memory.activeMemory)),
                cacheBytes: UInt64(max(0, Memory.cacheMemory)),
                peakBytes: UInt64(max(0, Memory.peakMemory)),
                cacheLimitBytes: UInt64(max(0, Memory.memoryLimit)))
        }
    }

    public var description: String {
        func gb(_ bytes: UInt64) -> String {
            String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
        return "gpu(active: \(gb(activeBytes)), cache: \(gb(cacheBytes)), "
            + "peak: \(gb(peakBytes)), limit: \(gb(cacheLimitBytes)))"
    }
}
