# Conformance — C0–C14

The contributor gate. Each item is a reviewable pass/fail; a reviewer points at the C-level,
not an opinion. Most declarative items are made once on the `PackageManifest`.

*(Filename kept at `conformance-c0-c13.md` when C14 landed — it is linked from three other repos'
docs. Rename it only in a pass that fixes those links too.)*

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
| C14 | Inference mode (the loaded model graph reports `training == false`; a package with no module graph declares the exemption) |

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

**C14 — inference mode** (added 2026-07-25, contract 1.27.0). `MLXNN.Module.training` defaults to
**`true`**. In that state `BatchNorm.callAsFunction` normalizes by the *current batch's* statistics
and **overwrites** the checkpoint's `running_mean`/`running_var` on every forward
(mlx-swift `Source/MLXNN/Normalization.swift`) — so inference runs on per-input statistics, the
trained statistics are never read, and repeated calls on one loaded instance drift. `Dropout` is the
same hazard class and is **not** identity-safe: it short-circuits only at `p == 0` or `!training`,
so a port carrying its upstream `p` randomly zeroes activations at inference. Norms without running
statistics (`LayerNorm`, `RMSNorm`, `GroupNorm`) never read `training` and are unaffected.

Neither failure is visible to eyeball validation, and none of C0–C13 asked. The motivating defect
(mlx-birefnet-swift, 2026-07-25): the matte still *looked* like a matte while the PROD fast tier
over-segmented by 68 % (foreground fraction 0.42 vs the PyTorch oracle's 0.25) and end-to-end logits
cosine against the oracle was **0.264**; one `model.train(false)` at the pipeline construction choke
point took it to **0.99999**.

C14 has an **executable adjunct**, the **INF gate**
(`MLXServeConformance.InferenceModeConformance`):
- **INF-1 inference mode** — every `Module` reachable from the package's **loaded** graph reports
  `training == false`. Any module in training mode fails, inert ones included: `train(_:)` is
  recursive, so a stray `Linear` proves the call never covered that subtree. An *empty* graph fails
  too, so "I ran the gate before `load()`" cannot read as a pass.
- **INF-2 posture declaration** — a package with no module graph (a functional port whose norms read
  `running_mean`/`running_var` straight out of the weight dict — DDColor, LaMa, EdgeTAM, the FLUX.2
  VAE — or a non-MLX package) declares `.notApplicable(reason:)`. The exemption is falsifiable: it
  fails if the walk observed modules anyway.

Because INF-1 needs the loaded graph, this gate is **not weight-free** — unlike MAT and CAN-1 it runs
in the package's live gate lane (post-`load()`), where STR-4..7 run. The package conforms to
`InferenceModeInspectable` in one line (only it knows where its models live), using the shared
`Module` walk from the **`MLXServeConformanceNN`** product — split out so `MLXServeConformance`
stays MLX-free for `mlx-audio-polish-swift` (the non-MLX capability seam) and for functional ports.

**Presence of inference mode on the real graph is the criterion.** Not output plausibility — a port
can look fine purely because its weights make batch statistics ≈ running statistics, which is luck.
And not the presence of `.train(false)` in source — the call may sit on a path this configuration
never takes.

The live counterpart is **INF-3 idempotence** (`MLXEngineTestKit.InferenceModeBench`, the `[INF]`
line): two `run()` calls on ONE loaded instance must produce identical output. INF-3 catches the
failure *class* rather than the known mechanism — statistic drift, live `Dropout`, and anything
training-mode-sensitive not yet met — and is what would have caught BiRefNet without anyone knowing
`BatchNorm` was the mechanism.

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
