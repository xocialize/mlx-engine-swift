import Foundation
import MLX

/// Engine-owned policy for MLX's **wired-memory limit** (NEUROSTREAM-ACTIONS HV1).
///
/// MLX ships a process-global `WiredMemoryManager` actor (mlx-swift ≥0.31) that coordinates the
/// Metal allocator's residency set through tickets; the engine maps its own accounting onto it so
/// wiring reflects the governor's admission decisions instead of running at MLX's wired=0 default:
///
/// - each **resident package's persistent weights** (the `footprintSplit` charge at `prepare()`)
///   → a `.reservation` ticket: participates in limit computation but never holds the limit up
///   while the engine is idle — an idle machine stays fully pageable;
/// - the **one in-flight transient** around `run()`/`stream()` (serialized inference)
///   → an `.active` ticket: while a run is in flight the wired limit rises to
///   Σ persistent + that run's transient, so weights and activations are kept resident under
///   memory pressure exactly when a stall would hit a live Metal command buffer.
///
/// **The ceiling is load-bearing, twice** (probe: `mlxengine-todo/probes/hv1_wired_tickets.out`):
/// `mlx::core::set_wired_limit` **throws** above the device's `recommendedMaxWorkingSetSize`
/// (`allocator.cpp` — the apply is rejected wholesale, not clamped), and the throw routes through
/// MLX's error handler, which **kills the process** unless a scoped handler is installed. And per
/// NEUROSTREAM-TEARDOWN §3.2, wiring most of RAM is a genuine *kernel panic* (IOGPUMemory.cpp:550,
/// wired 83.5% with `memoryPressure=false` — the kernel cannot reclaim wired pages and panics
/// instead of OOM-killing). So the engine's policy clamps every computed limit to
/// `min(recommendedMaxWorkingSetSize, total − osReserve)` with `osReserve = clamp(total/8, 6 GiB,
/// 16 GiB)` — leave 6–16 GB for the OS, never exceed the queried working set — and the engine
/// additionally wraps every ticket call in a scoped error handler so a rejected apply degrades to
/// a logged line and the previous limit (verified surviving in the probe).
///
/// Interactions verified before adoption (same probe):
/// - **`GPUCacheConfiguration` pool cap:** independent knobs. Cached (pooled) buffers remain
///   residency-set members, so the pool competes with weights for wired capacity — bounded by the
///   N5 pool cap (`min(2 GB, 5% of budget)`), and restoring the wired limit does not drain the pool.
/// - **Shrink hysteresis vs eviction timing:** the manager defers shrinks below
///   `shrinkThresholdRatio` (25%) or inside `shrinkCooldown` (1 s) *while active work runs* —
///   an engine eviction mid-run leaves the limit transiently high (bounded by the ceiling,
///   re-computed on the next ticket event ≥1 s later). When the last active ticket ends the
///   baseline restore is immediate — hysteresis never delays the idle→0 transition.
/// - **Legacy coexistence:** consumers still on the deprecated `Memory.withWiredLimit` route form
///   their own policy group; the manager takes the max across groups (no double-count).
public struct WiredLimitConfiguration: Sendable, Equatable {

    /// How the engine coordinates the process-global wired limit.
    public enum Coordination: Sendable, Equatable {
        /// Derive the ceiling from the device profile: `min(recommended working set,
        /// total − clamp(total/8, 6 GiB, 16 GiB))`. The recommended-working-set arm is only
        /// consulted when the profile describes THIS host (fabricated-profile tests must not
        /// inherit host-queried values — the `forDevice` determinism rule).
        case automatic
        /// An explicit wired ceiling in bytes. Still min'd with the queried working set on a
        /// host profile — the allocator rejects anything above it (see type docs).
        case ceiling(bytes: UInt64)
        /// Never create tickets, never touch the wired limit (the pre-0.42 behavior: MLX's
        /// wired=0 default stays in effect).
        case disabled
    }

    /// The coordination policy. Resolved once at engine init.
    public var coordination: Coordination

    public init(coordination: Coordination = .automatic) {
        self.coordination = coordination
    }

    /// The whole-feature opt-out.
    public static let disabled = WiredLimitConfiguration(coordination: .disabled)

    /// Bytes left unwired for the OS: `clamp(total/8, 6 GiB, 16 GiB)`, never more than half of
    /// total (tiny fabricated profiles must not underflow). The 6–16 GB bracket is the teardown
    /// §3.2 guidance; the /8 scaling keeps big machines at the 16 GB end (128 GB → 16 GB) and
    /// small ones at the floor (16 GB → 6 GB, i.e. a 10 GB ceiling ≈ the 50–60% wired fraction
    /// MLX's maintainers suggest for constrained machines).
    static func osReserveBytes(totalMemoryBytes total: UInt64) -> UInt64 {
        min(min(max(total / 8, 6 * 1_073_741_824), 16 * 1_073_741_824), total / 2)
    }

    /// The ceiling this configuration resolves to against a device total, or `nil` when
    /// coordination is disabled. `recommendedBytes` is the queried working set when the profile
    /// is this host and Metal is reachable, `nil` otherwise (fabricated profiles stay pure
    /// arithmetic — deterministic on every machine).
    func resolvedCeilingBytes(totalMemoryBytes: UInt64, recommendedBytes: UInt64?) -> UInt64? {
        switch coordination {
        case .disabled:
            return nil
        case .ceiling(let bytes):
            return min(bytes, recommendedBytes ?? bytes)
        case .automatic:
            let headroom = totalMemoryBytes - Self.osReserveBytes(totalMemoryBytes: totalMemoryBytes)
            return min(headroom, recommendedBytes ?? headroom)
        }
    }
}

/// The engine's `WiredMemoryPolicy`: sum the active ticket sizes over the baseline, clamped to
/// the resolved ceiling. `canAdmit` stays the protocol default (always true) — **admission is the
/// `MemoryGovernor`'s job**; the manager's admission gate would otherwise double-gate loads
/// against a capacity model the governor already owns (and could park `prepare()` forever).
///
/// `Hashable` supplies the policy-group `id`: engines resolving the same ceiling share one group,
/// so their tickets sum (and a re-constructed engine rejoins its predecessor's group rather than
/// forking a competing one).
struct EngineWiredLimitPolicy: WiredMemoryPolicy, Hashable, Sendable {
    /// Resolved at engine init (see `WiredLimitConfiguration.resolvedCeilingBytes`).
    let ceilingBytes: Int
    /// On host profiles, re-clamp to the *live* queried working set at every computation:
    /// `recommendedMaxWorkingSetSize` moves when `iogpu.wired_limit` is set by an admin
    /// (teardown §3.2), and an apply above the live value is rejected by the allocator.
    /// Always false for fabricated profiles (keeps the policy a pure function in tests).
    let clampToLiveRecommended: Bool

    func limit(baseline: Int, activeSizes: [Int]) -> Int {
        var ceiling = ceilingBytes
        if clampToLiveRecommended, let live = GPU.maxRecommendedWorkingSetBytes() {
            ceiling = min(ceiling, live)
        }
        return min(baseline + activeSizes.reduce(0, +), ceiling)
    }
}

/// Guards against double-`end()` when task cancellation races normal completion (the same
/// pattern as mlx-swift's `WiredMemoryTicket.withWiredLimit`, re-implemented here because the
/// engine must scope an MLX error handler around the ticket calls *only* — never around the run
/// body, whose own MLX errors must keep their normal routing).
private final class TicketEndOnce: @unchecked Sendable {
    private var ended = false
    private let lock = NSLock()
    func tryMark() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if ended { return false }
        ended = true
        return true
    }
}

/// The engine's log-and-continue handler for a rejected wired-limit apply (the C++ throw for a
/// limit above the live working set — see `WiredLimitConfiguration` docs). The manager keeps the
/// previous limit; inference proceeds with less (or no) wiring, which is exactly the pre-HV1
/// baseline behavior.
let noteWiredApplyFailure: @Sendable (String) -> Void = { message in
    print("[WiredLimit] apply rejected (kept previous limit): \(message)")
}

/// Cancellation-safe `.active` ticket pairing around one run: start before the body, end exactly
/// once on return, throw, or cancel. `nil` ticket (coordination disabled) runs the body directly.
func withActiveWiredTicket<R: Sendable>(
    _ ticket: WiredMemoryTicket?,
    _ body: () async throws -> R
) async rethrows -> R {
    guard let ticket else { return try await body() }
    _ = await withErrorHandler(noteWiredApplyFailure) { await ticket.start() }
    let once = TicketEndOnce()
    return try await withTaskCancellationHandler {
        do {
            let result = try await body()
            if once.tryMark() {
                _ = await withErrorHandler(noteWiredApplyFailure) { await ticket.end() }
            }
            return result
        } catch {
            if once.tryMark() {
                _ = await withErrorHandler(noteWiredApplyFailure) { await ticket.end() }
            }
            throw error
        }
    } onCancel: {
        Task {
            if once.tryMark() {
                _ = await withErrorHandler(noteWiredApplyFailure) { await ticket.end() }
            }
        }
    }
}
