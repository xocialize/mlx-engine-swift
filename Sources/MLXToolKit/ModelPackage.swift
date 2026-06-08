/// A constructed, engine-owned **model unit** — the runtime embodiment of a package. One
/// `ModelPackage` backs **N capability surfaces** (Lance → four); the registry routes every
/// surface call for those capabilities to this single instance, so the model loads once and
/// a T2I→T2V chain is two calls against the same resident model.
///
/// Inversion of control — the core value proposition: the **engine** constructs it from a
/// `PackageConfiguration`, holds the reference, pages it in with `load()`, drives `run(_:)`,
/// and reclaims it with `unload()`. A package never self-instantiates into global residency,
/// never runs a private queue, and never holds compute outside a scheduled call (C13). Because
/// the engine owns the lifecycle, a runaway package cannot destabilize the pipeline.
///
/// **Isolation makes C13 structural, not aspirational.** The lifecycle methods are isolated to
/// `InferenceActor`, the engine's single execution-serialization domain, so "runs only inside
/// the serialization domain, no private queue" is enforced by the compiler. In return the
/// author gets a guarantee: the engine never calls these methods concurrently — no internal
/// locking required.
///
/// V1 uses **erased dispatch**: one `run(_:)` over `any CapabilityRequest`. The canonical
/// request/response *structs* (`TTSRequest` / `TTSResponse`, …) stay strongly typed where it
/// matters — on the wire and at the call site; only the registry-facing seam is erased.
@InferenceActor
public protocol ModelPackage: AnyObject, Sendable {
    /// Init-time configuration (C9): weights id, quant, backend preference, memory budget.
    /// Stable for the session, distinct from the per-request envelope.
    associatedtype Configuration: PackageConfiguration

    /// The static, registrable blueprint. Read at registration / eligibility time — before any
    /// instance exists — so it is `nonisolated`.
    nonisolated static var manifest: PackageManifest { get }

    /// Cheap construction. Weights are SHA256-verified on disk but **not** paged into compute
    /// memory yet — residency is `load()`'s job. Does no inference and grabs no compute (C13).
    nonisolated init(configuration: Configuration)

    /// Page the working set into the placed `MemoryPool`. The engine calls this on admission;
    /// it is lazy (not at construction) and may be called again after an `unload()` to bring an
    /// evicted package back. Should be idempotent when already resident.
    func load() async throws

    /// Release the working set under memory pressure. The instance survives and can be
    /// `load()`-ed again later. Cooperative eviction (C13).
    func unload() async

    /// Run one call for one of this package's capabilities. Dispatch on `request.capability`,
    /// downcast to the concrete canonical request, and return the matching canonical response.
    /// Throw `PackageError.unsupportedCapability` for a capability this package does not back,
    /// and `PackageError.notLoaded` if invoked before residency.
    ///
    /// Runs inside the engine's `InferenceActor`. **Must honor cancellation:** call
    /// `try Task.checkCancellation()` at natural yield points (per generated token, per decoded
    /// frame) so the `MemoryGovernor` can preempt a long generation to reclaim memory. A
    /// governor-initiated cancellation is the engine's signal to **requeue** the request — not a
    /// failure the caller sees; genuine errors propagate to the caller unchanged.
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse
}
