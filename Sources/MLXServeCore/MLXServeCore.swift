import MLXToolKit

// MLXServeCore — the runtime coordinator. SCAFFOLDING PLACEHOLDER for this phase.
//
// MLXToolKit now defines the package-facing contract: `ModelPackage` (the engine-owned model
// unit), its `PackageManifest` blueprint, `PackageRegistration` (manifest + license-gated
// factory), and the `InferenceActor` serialization domain its lifecycle methods are isolated
// to. This target drives them. It will own:
//   - ToolRegistry (actor): indexes each surface in a manifest independently (one model, N
//     surfaces) and resolves a capability call to the single constructed ModelPackage.
//   - Admission: run the license gate on the manifest, SHA256-verify weights (HubAssetSource),
//     then call PackageRegistration.makePackage to construct — never the package itself (C13).
//   - InferenceActor scheduling: serialize run(_:) onto the compute resources; under memory
//     pressure, cancel an in-flight run to evict and REQUEUE the request (a governor-initiated
//     CancellationError is retried, not surfaced; genuine errors propagate to the caller).
//   - MemoryGovernor (watermark ladder) + MemoryPool placement; load()/unload() drive residency.
//   - MCPBridge (capability-as-tool exposure) over each manifest surface.
//   - Model Manager + DeviceProfile (manifest.requirements ⊆ device.capabilities).
//
// It is intentionally minimal until MLXToolKit is locked.
public enum MLXServeCore {
    /// The contract version this build coordinates against.
    public static let contractVersion = ContractVersion.current
}
