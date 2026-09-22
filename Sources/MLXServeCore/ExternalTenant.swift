import Foundation

/// The bytes a non-package GPU tenant holds, in the engine's own persistent + transient split
/// (contract 1.43.0). `persistentBytes` is held between uses — a layer-texture cache, pooled
/// working textures — and counts in residency exactly like a package's weights.
/// `transientBytes` is what one use of the tenant adds on top — upload staging, readback — and
/// is reserved IN ADDITION to the packages' one serialized transient, never folded into its max
/// (see `MLXServeEngine.registerExternalTenant`).
public struct ExternalFootprint: Sendable, Equatable, Hashable {
    public var persistentBytes: UInt64
    public var transientBytes: UInt64

    public init(persistentBytes: UInt64 = 0, transientBytes: UInt64 = 0) {
        self.persistentBytes = persistentBytes
        self.transientBytes = transientBytes
    }

    public var totalBytes: UInt64 { persistentBytes &+ transientBytes }
    public static let zero = ExternalFootprint()
}

/// Asked by the engine to give memory back (contract 1.43.0). `requestedBytes` is the deficit the
/// engine is trying to close — the tenant may release more, less, or nothing. Before returning,
/// the handler MUST `update` the tenant's declaration to what it now holds: the engine re-reads
/// the DECLARATION afterwards, and that is the only number it admits against. The returned value
/// is advisory (it is logged when it disagrees with the declaration, never trusted over it).
///
/// Bounded by `ExternalTenantPolicy.shrinkTimeout`: a handler still running at the deadline is
/// cancelled and treated as having released nothing it has not declared.
public typealias ExternalShrinkHandler = @Sendable (_ requestedBytes: UInt64) async -> UInt64

/// How the engine treats external GPU tenants (contract 1.43.0).
public struct ExternalTenantPolicy: Sendable, Equatable {
    /// How long ONE shrink request may take before the engine stops waiting for it. A
    /// cache-drop is milliseconds; the default leaves room for a handler that hops to the main
    /// actor behind a frame, and caps what an unresponsive handler can cost an admission.
    public var shrinkTimeout: Duration

    public init(shrinkTimeout: Duration = .seconds(2)) {
        self.shrinkTimeout = shrinkTimeout
    }
}

/// A non-package tenant of the GPU sharing this process with the engine — e.g. a Metal layer
/// compositor (contract 1.43.0, AB-R-0289 / AB-R-0292). Returned by
/// `MLXServeEngine.registerExternalTenant(id:persistentBytes:transientBytes:onShrinkRequest:)`.
///
/// The handle is the WHOLE seam: numbers in (`update`), a closure for the engine to call
/// (`onShrinkRequest`), and `withdraw`. The tenant's own module never imports the engine — the
/// app layer that owns both holds this handle and bridges them.
///
/// Thread-safe and synchronous: `update` takes a lock, not an actor hop, so it can be called from
/// a render thread in the same frame the allocation happens, in any order with runs in flight.
/// The engine reads the declaration fresh at every accounting step. Dropping the last reference
/// withdraws the tenant, like `withdraw()`.
public final class ExternalTenant: Sendable {
    /// The label the tenant was registered under (keys `MemorySnapshot.externalTenants`).
    public let id: String
    let state: ExternalTenantState

    init(state: ExternalTenantState) {
        self.id = state.id
        self.state = state
    }

    deinit { state.withdraw() }

    /// Declare what the tenant holds NOW. Replaces the previous declaration; takes effect at the
    /// engine's next accounting step. Growth is never refused — the engine cannot refuse an
    /// allocation it does not make — it is accounted from the next admission on. A no-op after
    /// `withdraw()`.
    public func update(persistentBytes: UInt64, transientBytes: UInt64) {
        state.update(ExternalFootprint(persistentBytes: persistentBytes,
                                       transientBytes: transientBytes))
    }

    /// Declare what the tenant holds NOW (the struct form).
    public func update(_ footprint: ExternalFootprint) { state.update(footprint) }

    /// Install, replace, or clear (`nil`) the handler the engine calls to ask for memory back.
    public func setShrinkHandler(_ handler: ExternalShrinkHandler?) { state.setHandler(handler) }

    /// The current declaration (`.zero` once withdrawn).
    public var footprint: ExternalFootprint { state.footprint }

    public var isWithdrawn: Bool { state.isWithdrawn }

    /// Remove the tenant: its bytes stop counting immediately and its shrink handler is released.
    /// Idempotent.
    public func withdraw() { state.withdraw() }
}

/// The lock-guarded state the engine and the handle share. The engine holds THIS, never the
/// handle, so the app dropping its handle is what ends the tenancy.
final class ExternalTenantState: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var _footprint: ExternalFootprint
    private var _handler: ExternalShrinkHandler?
    private var _withdrawn = false

    init(id: String, footprint: ExternalFootprint, handler: ExternalShrinkHandler?) {
        self.id = id
        self._footprint = footprint
        self._handler = handler
    }

    var footprint: ExternalFootprint { lock.withLock { _withdrawn ? .zero : _footprint } }
    var handler: ExternalShrinkHandler? { lock.withLock { _withdrawn ? nil : _handler } }
    var isWithdrawn: Bool { lock.withLock { _withdrawn } }

    func update(_ footprint: ExternalFootprint) {
        lock.withLock { if !_withdrawn { _footprint = footprint } }
    }

    func setHandler(_ handler: ExternalShrinkHandler?) {
        lock.withLock { if !_withdrawn { _handler = handler } }
    }

    func withdraw() {
        // Drop the handler outside the lock: releasing it may run arbitrary deinit code.
        let released: ExternalShrinkHandler? = lock.withLock {
            _withdrawn = true
            _footprint = .zero
            defer { _handler = nil }
            return _handler
        }
        _ = released
    }
}

/// One shrink request raced against its deadline. Whichever finishes first resumes the waiting
/// admission; a handler that outlives the deadline is cancelled and its eventual answer ignored —
/// the engine never awaits it, which is what keeps an unresponsive tenant from hanging admission.
enum ExternalShrinkRequest {
    static func run(_ handler: @escaping ExternalShrinkHandler, requested: UInt64,
                    timeout: Duration) async -> UInt64? {
        let race = Race()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
            race.arm(continuation)
            let work = Task {
                let released = await handler(requested)
                race.finish(released)
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if race.finish(nil) { work.cancel() }
            }
            race.onFinish { timer.cancel() }
        }
    }

    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt64?, Never>?
        private var done = false
        private var cleanup: (@Sendable () -> Void)?

        func arm(_ continuation: CheckedContinuation<UInt64?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        /// Runs `body` once the race is decided (immediately if it already is).
        func onFinish(_ body: @escaping @Sendable () -> Void) {
            let runNow: Bool = lock.withLock {
                if done { return true }
                cleanup = body
                return false
            }
            if runNow { body() }
        }

        /// Decide the race; returns whether THIS call decided it.
        @discardableResult
        func finish(_ value: UInt64?) -> Bool {
            let (won, continuation, cleanup) = lock.withLock {
                () -> (Bool, CheckedContinuation<UInt64?, Never>?, (@Sendable () -> Void)?) in
                guard !done else { return (false, nil, nil) }
                done = true
                defer { self.continuation = nil; self.cleanup = nil }
                return (true, self.continuation, self.cleanup)
            }
            guard won else { return false }
            continuation?.resume(returning: value)
            cleanup?()
            return true
        }
    }
}
