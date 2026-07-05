import Foundation
import MLX

/// Engine-owned policy for MLX's **Metal buffer-recycling pool** (ENGINE-NEEDS N5).
///
/// MLX recycles every freed GPU buffer into a process-global cache that is effectively
/// unbounded by default and never returns memory to the OS. Interactive consumers (chat:
/// llm + embed + tts per turn, each run with new tensor shapes) ratchet the pool by GBs per
/// interaction — it reads as a never-released leak in Activity Monitor (the MLXCompanion
/// 43 GB staircase, 2026-07-05). The engine owns the GPU and the memory budget, so the pool
/// policy lives here beside the governor: `MLXServeEngine` applies the resolved limit **once,
/// at init**.
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
    /// Trim the pool after every N successful `run`s (a burst-shaped host's "drop the pool
    /// between interactions" knob). `nil` (default) or values < 1 disable it.
    public var trimEveryRuns: Int?

    public init(limit: Limit = .automatic,
                trimAfterEvict: Bool = false,
                trimEveryRuns: Int? = nil) {
        self.limit = limit
        self.trimAfterEvict = trimAfterEvict
        self.trimEveryRuns = trimEveryRuns
    }

    /// The whole-feature opt-out: no limit write, no trims.
    public static let unmanaged = GPUCacheConfiguration(limit: .unmanaged)

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
    public static func current() -> GPUPoolSnapshot? {
        try? MLX.withError {
            GPUPoolSnapshot(
                activeBytes: UInt64(max(0, Memory.activeMemory)),
                cacheBytes: UInt64(max(0, Memory.cacheMemory)),
                peakBytes: UInt64(max(0, Memory.peakMemory)),
                cacheLimitBytes: UInt64(max(0, Memory.cacheLimit)))
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
