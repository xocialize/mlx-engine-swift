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
///
/// The request-only form. It still works unchanged; from 1.46.0 it is wrapped into an
/// `ExternalShrinkRequestHandler` that ignores the reason. A tenant whose right answer depends on
/// WHY it is asked registers the request form instead.
public typealias ExternalShrinkHandler = @Sendable (_ requestedBytes: UInt64) async -> UInt64

/// One request from the engine to an external tenant to give memory back, with the reason
/// (contract 1.46.0, AB-A-0097). The obligations are `ExternalShrinkHandler`'s: `update` the
/// declaration before returning; the return value is advisory; the call is bounded by
/// `ExternalTenantPolicy.shrinkTimeout`.
public struct ExternalShrinkRequest: Sendable, Equatable, Hashable {
    /// Why the engine is asking. What is worth shedding differs (AB-R-0303 / AB-R-0304).
    public enum Reason: Sendable, Equatable, Hashable {
        /// A package is being admitted and needs room: a fresh load (`prepare`, or a run that
        /// loads its package), or a run on a resident package whose reserve no longer fits the
        /// declared budget. The alternative to the tenant's bytes is evicting or refusing a
        /// model, so dropping caches is worth it. Covers both the declared-byte pass and the
        /// R-MEM-1 real-pressure pass of that admission.
        case admission
        /// A run on an ALREADY-resident package found the process over the R-MEM-1 ceiling
        /// while the declared accounting fits (1.45.0). The engine evicts nothing on this path,
        /// and nothing is being loaded: the tenant should shed only what it will not
        /// immediately need again. A cache it re-uploads on its next frame buys nothing.
        case runUnderRealPressure
    }

    /// The deficit the engine is trying to close: bytes over the budget (declared pass) or over
    /// the R-MEM-1 ceiling (real-pressure passes). The tenant may release more, less, or nothing.
    public let requestedBytes: UInt64
    public let reason: Reason
    /// The package being admitted or run, when there is one.
    public let package: PackageID?

    public init(requestedBytes: UInt64, reason: Reason, package: PackageID? = nil) {
        self.requestedBytes = requestedBytes
        self.reason = reason
        self.package = package
    }
}

/// The request form of the shrink handler (contract 1.46.0): as `ExternalShrinkHandler`, but
/// given the whole `ExternalShrinkRequest`, so the tenant can decide what to shed by the reason.
public typealias ExternalShrinkRequestHandler =
    @Sendable (_ request: ExternalShrinkRequest) async -> UInt64

extension ExternalShrinkRequest {
    /// The legacy form, wrapped: the reason and package are dropped, `requestedBytes` passed.
    static func wrap(_ handler: ExternalShrinkHandler?) -> ExternalShrinkRequestHandler? {
        guard let handler else { return nil }
        return { request in await handler(request.requestedBytes) }
    }
}

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
/// (`onShrinkRequest`, either form), and `withdraw`. The tenant's own module never imports the engine — the
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
    public func setShrinkHandler(_ handler: ExternalShrinkHandler?) {
        state.setHandler(ExternalShrinkRequest.wrap(handler))
    }

    /// Install, replace, or clear (`nil`) the request-form handler (1.46.0): it receives the
    /// reason the engine is asking. Replaces a handler installed in either form.
    @_disfavoredOverload
    public func setShrinkHandler(_ handler: ExternalShrinkRequestHandler?) {
        state.setHandler(handler)
    }

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
    private var _handler: ExternalShrinkRequestHandler?
    private var _withdrawn = false

    init(id: String, footprint: ExternalFootprint, handler: ExternalShrinkRequestHandler?) {
        self.id = id
        self._footprint = footprint
        self._handler = handler
    }

    var footprint: ExternalFootprint { lock.withLock { _withdrawn ? .zero : _footprint } }
    var handler: ExternalShrinkRequestHandler? { lock.withLock { _withdrawn ? nil : _handler } }
    var isWithdrawn: Bool { lock.withLock { _withdrawn } }

    func update(_ footprint: ExternalFootprint) {
        lock.withLock { if !_withdrawn { _footprint = footprint } }
    }

    func setHandler(_ handler: ExternalShrinkRequestHandler?) {
        lock.withLock { if !_withdrawn { _handler = handler } }
    }

    func withdraw() {
        // Drop the handler outside the lock: releasing it may run arbitrary deinit code.
        let released: ExternalShrinkRequestHandler? = lock.withLock {
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
enum ExternalShrinkCall {
    static func run(_ handler: @escaping ExternalShrinkRequestHandler,
                    request: ExternalShrinkRequest,
                    timeout: Duration) async -> UInt64? {
        let race = Race()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UInt64?, Never>) in
            race.arm(continuation)
            let work = Task {
                let released = await handler(request)
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
