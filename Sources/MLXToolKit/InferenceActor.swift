/// The engine's single **execution-serialization domain**. All `ModelPackage` inference runs
/// here, so concurrent callers across heterogeneous models don't contend for the GPU/ANE
/// uncoordinated (architecture §1.2).
///
/// Isolating `ModelPackage`'s lifecycle methods to this global actor is what turns C13's
/// "runs only inside the serialization domain, holds no private queue" from a reviewer
/// judgment call — invisible until concurrent load — into a **compiler-enforced** property.
/// In exchange the package author gets a guarantee: the engine never calls `load` / `run` /
/// `unload` concurrently, so a package needs no internal locking.
///
/// V1 is a single serialization point (one logical compute resource). Per-`MemoryPool`
/// concurrency (e.g. Metal GPU and CoreML ANE progressing in parallel) is a V2 refinement
/// that does not change the package-facing contract.
@globalActor
public actor InferenceActor {
    public static let shared = InferenceActor()
    private init() {}
}
