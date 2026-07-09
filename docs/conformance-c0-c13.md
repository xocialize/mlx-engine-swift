# Conformance — C0–C13

The contributor gate. Each item is a reviewable pass/fail; a reviewer points at the C-level,
not an opinion. Most declarative items are made once on the `PackageManifest`.

| # | Item |
|---|---|
| C0 | Contract version declared (`manifest.contractVersion`) |
| C1 | Capability registration (≥1 canonical case; each surface independent) |
| C2 | Canonical schema conformance (I/O matches the capability schema + output artifact) |
| C3 | Canonical artifact I/O (`Image`/`Audio`/`Video`, serialized round-trip) |
| C4 | Mode-as-parameter (modes ride the envelope, never separate surfaces) |
| C5 | metaData hygiene (package-specific only; no should-be-canonical params smuggled) |
| C6 | Specialty declaration (governed vocabulary, multi-valued + strength; never a surface) |
| C7 | Weight license gate (`manifest.license.weightLicense`, passes `.permissiveOnly`) |
| C8 | Port-code license gate (`manifest.license.portCodeLicense`; distinct from C7) |
| C9 | PackageConfiguration (init-time, Codable; distinct from request params) |
| C10 | Requirements manifest (footprint per quant, backends, OS, chip floor) |
| C11 | MCPBridge introspection (each surface exposes a valid introspectable schema) |
| C12 | Forward-compat discipline (`@unknown default` on capability switches) |
| C13 | Runtime governance cooperation (engine-owned lifecycle; `@InferenceActor`-isolated; cancellation-honoring; cooperatively evictable; no private queue) |

C13's "runs only in the serialization domain / no private queue" is **compiler-enforced** by
`ModelPackage`'s `@InferenceActor` isolation; its eviction/cancellation behavior needs runtime
testing. "Cooperatively evictable" is refined by **R-MEM-1** (architecture.md): a package is
evictable iff `unload()` releases its full working set *and* the engine's admission-time,
pressure-aware eviction can reclaim it before the next heavy load — so heavy models swap (queue-shaped)
rather than stack. R-MEM-1's eviction *trigger* (declared bytes vs. real pressure) is now wired — the
admission path reads actual `phys_footprint` — so the remaining open item is **mid-run** preemption +
the cooperative-cancellation contract C13 names (a *running* inference still can't be stopped), not the
admission-time trigger or the package's `unload()` obligation.

*The authoritative checklist (pass/fail criteria, failure modes) lives in the `mlx-swift-integration` skill.*

---

## Handoff — the MAT gate is not yet documented in this docs set

> **TODO (noted 2026-07-09, post engine v0.24.0 / contract 1.17.0).** Since v0.19.0 the C0–C13
> checklist has an **executable adjunct**: the **MAT gate** (MAT-1..5, offline) — every package's
> own test suite proves its first-run weight-materialization declarations via
> `MLXServeConformance.MaterializationConformance.check(…)`. v0.24.0 extended its vocabulary so
> **bundled-weights** packages (checkpoints vendored in the SPM bundle, nothing to download) are
> first-class: network sources must be *missing* on a fresh machine, bundled sources must be
> *present*. None of that is written up in this shipped `docs/` set yet.
>
> Until someone gives these placeholder docs a pass, the ground truth is:
> - `Sources/MLXToolKit/WeightSources.swift` + `Sources/MLXToolKit/BundledWeightSources.swift`
>   (the `WeightSourcing` / `BundledWeightSourcing` declarations)
> - `Sources/MLXServeConformance/MaterializationConformance.swift` (the gate itself, MAT-1..5)
> - `EngineeringDocs/MLXEngineDocs/conformance.md` → MAT-gate section (internal write-up)
> - the `mlx-swift-integration` skill, `references/porting-conformance.md` §4 (package-author
>   requirements; reference implementations: MLXLTX2 = network, mlx-realesrgan-swift = bundled)
>
> When writing the public section: cover the four package-author requirements (declare / execute
> with `WeightDownloadProgress` / prove offline / prewarm the store view), the explicit-directory
> escape hatch (never touches the network), and the bundled-vs-network fresh-machine semantics.
