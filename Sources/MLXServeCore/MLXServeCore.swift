import MLXToolKit

// MLXServeCore — the runtime coordinator.
//
// FIRST SLICE LANDED: `MLXServeEngine` (see MLXServeEngine.swift) — a registry + admission path
// that runs the two-layer license gate at registration and lazily constructs + loads + routes a
// `ModelPackage` by capability (inversion of control, C13). Proven driving the real Qwen3.5 `llm`
// package from the test app.
//
// MLXToolKit defines the package-facing contract: `ModelPackage` (the engine-owned model unit),
// its `PackageManifest` blueprint, `PackageRegistration` (manifest + license-gated factory), and
// the `InferenceActor` serialization domain its lifecycle methods are isolated to. This target
// drives them. Still TODO here:
//   - ToolRegistry (actor): indexes each surface in a manifest independently (one model, N
//     surfaces) and resolves a capability call to the single constructed ModelPackage.
//   - Admission: run the license gate on the manifest, then call PackageRegistration.makePackage
//     to construct — never the package itself (C13). Weight integrity is the hub client's
//     responsibility (xet chunk hashes / ETag verification in swift-huggingface); the engine
//     verifies presence, not content.
//   - InferenceActor scheduling: serialize run(_:) onto the compute resources. LANDED (V3,
//     run-lifecycle program): under memory pressure the governor cancels an in-flight run as a
//     last resort and the engine REQUEUES the request (its own CancellationError is retried,
//     bounded by PreemptionPolicy.maxRequeues; a user cancel — cancelling the Task wrapping
//     engine.run() — surfaces as .cancelled; genuine errors propagate to the caller).
//   - MemoryGovernor (watermark ladder) + MemoryPool placement; load()/unload() drive residency.
//   - Model Manager + DeviceProfile (manifest.requirements ⊆ device.capabilities).
//
// NOT an engine component (decided 2026-07-26): capability-as-tool protocol exposure. An MCP
// bridge is an external utility APP that consumes this engine — it enumerates surfaces via
// registeredCapabilities / packages(for:) / manifest(for:) and invokes run(_:package:). Keeping it
// out keeps the engine protocol-agnostic and its dependency surface small.
//
// It is intentionally minimal until MLXToolKit is locked.
public enum MLXServeCore {
    /// The contract version this build coordinates against.
    public static let contractVersion = ContractVersion.current
}
