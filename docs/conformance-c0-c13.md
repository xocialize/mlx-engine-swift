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

**C11 is scoped to introspectability, not MCP wire compatibility** (decided 2026-07-22). A surface
satisfies C11 by publishing a complete, honest `ToolDescriptor` — a bridge can enumerate the tool,
its parameters and kinds, and its I/O types from the manifest alone. `ParameterSchema` is an
MCP-*like* subset: no value constraints (`minimum`/`maximum`/`enum`/`default`), opaque
`object`/`array`, and **no declared JSON encoding for the binary artifact kinds**
(`image`/`audio`/`video`/`mesh`). Closing that gap is purely additive and is done **at integration
time, when a non-LLM MCP consumer actually exists** (in practice alongside `MCPBridge`, whose schema
layer it is) — so nothing is reserved for it in the contract. The `llm` surface is unaffected: its
structured output and tool-use ride FoundationModels' `GenerationSchema`, which is full JSON Schema.

C13's "runs only in the serialization domain / no private queue" is **compiler-enforced** by
`ModelPackage`'s `@InferenceActor` isolation; its eviction/cancellation behavior needs runtime
testing. "Cooperatively evictable" is refined by **R-MEM-1** (architecture.md): a package is
evictable iff `unload()` releases its full working set *and* the engine's admission-time,
pressure-aware eviction can reclaim it before the next heavy load — so heavy models swap (queue-shaped)
rather than stack. R-MEM-1's eviction *trigger* (declared bytes vs. real pressure) is now wired — the
admission path reads actual `phys_footprint` — and **mid-run preemption + requeue landed too**
(run-lifecycle program V3, engine 0.26.0: user cancel = cancel the `Task` wrapping `engine.run()`,
surfaces `CancellationError` → classify `.cancelled`; governor preemption requeues — see
`docs/run-lifecycle.md`). The cancellation-honoring half of C13 has an **executable adjunct**: the
**CAN gate** (`MLXServeConformance.CancellationConformance`, CAN-1..3, offline) — the same
relationship the MAT gate has to `WeightSourcing`. CAN-1: a pre-cancelled `run()` surfaces
`CancellationError` (entry checkpoint first, before validation). CAN-2: the outcome is
cancelled-not-failed in the capability's canonical shape (the error rethrown unwrapped, or
`FinishReason.cancelled` on a partial response). CAN-3: a manifest that implies long runs
(video/audio generation, or ≥ 2 GB declared peak activation) declares its checkpoint cadence
(per step / chunk / token / frame / layer, per `RunPhase`; per-step `RunProgress` reporting is
accepted evidence). The live counterpart is `MLXEngineTestKit.CancellationBench` (the `[CAN]`
timed cancel-latency probe; Xcode-app harness only).

*The authoritative checklist (pass/fail criteria, failure modes) lives in the `mlx-swift-integration` skill.*

---

## Handoff — the MAT and CAN gates are only summarized in this docs set

> **TODO (noted 2026-07-09, post engine v0.24.0 / contract 1.17.0).** Since v0.19.0 the C0–C13
> checklist has an **executable adjunct**: the **MAT gate** (MAT-1..5, offline) — every package's
> own test suite proves its first-run weight-materialization declarations via
> `MLXServeConformance.MaterializationConformance.check(…)`. v0.24.0 extended its vocabulary so
> **bundled-weights** packages (checkpoints vendored in the SPM bundle, nothing to download) are
> first-class: network sources must be *missing* on a fresh machine, bundled sources must be
> *present*. Contract 1.24 then flipped the EXECUTION side: the engine now downloads the missing
> sources itself before `load()` (`SelfMaterializing` opts a package out) — the declarations the
> gate checks are unchanged. None of that is written up in this shipped `docs/` set yet.
>
> Until someone gives these placeholder docs a pass, the ground truth is:
> - `Sources/MLXToolKit/WeightSources.swift` + `Sources/MLXToolKit/BundledWeightSources.swift`
>   (the `WeightSourcing` / `BundledWeightSourcing` declarations)
> - `Sources/MLXServeConformance/MaterializationConformance.swift` (the gate itself, MAT-1..5)
> - `EngineeringDocs/MLXEngineDocs/conformance.md` → MAT-gate section (internal write-up)
> - the `mlx-swift-integration` skill, `references/porting-conformance.md` §4 (package-author
>   requirements; reference implementations: MLXLTX2 = network, mlx-realesrgan-swift = bundled)
>
> The **CAN gate** (engine ≥ 0.27.0, summarized above) has the same shape: ground truth is
> `Sources/MLXServeConformance/CancellationConformance.swift` (CAN-1..3),
> `Sources/MLXEngineTestKit/CancellationRun.swift` (the live `[CAN]` bench),
> `EngineeringDocs/MLXEngineDocs/conformance.md` → CAN-gate section, and the
> `mlx-swift-integration` skill's cancellation-conformance section.
>
> When writing the public section: cover the four package-author requirements (declare / execute
> with `WeightDownloadProgress` / prove offline / prewarm the store view), the explicit-directory
> escape hatch (never touches the network), and the bundled-vs-network fresh-machine semantics.
