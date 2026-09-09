# MLXEngineTestKit

The reusable **validation harness** for category testing apps (image / video / audio / think / 3D).
Lean by design — SwiftUI + `MLXServeCore` + `MLXToolKit` only, **no third-party frameworks, no `mlx-swift`
dependency** — and composable: adopt the seams you need, extend per-package. Not part of the shipping
`MLXEngineUI`; opt-in (`.product(name: "MLXEngineTestKit", package: "mlx-engine-swift")`).

Built because the gap audit (LTX video app + image app, 2026-06-30) found the same seams missing per
category app. These are the shared implementations so each app stops re-inventing them.

## What's here (the six seams)

| Seam | API |
|---|---|
| Memory split readout + transient reserve | `EngineMemoryView(snapshot:run:)` — budget · resident · **transientReserve** · available · real phys + pressure, and the measured floor/activation/peak split |
| Peak sampler | `MemorySampler` — 150 ms `phys_footprint` poll (reuses `HostMemory.physFootprint`) |
| Phase-tagged trace | `PhaseTrace` — `mark("denoise")` → `peakByPhase` attribution (proves per-stage eviction) |
| Reusable run harness | `ValidationHarness.run(...)` → `ValidationRun` (evict→register→prepare(timed)→run(timed)→capture; sampler + heartbeat + security-scoped grants). Generalized from the retired proving-ground app's `runFlow`. |
| Admissibility / tier seam | `AdmissibilityTiers.check(...)` + `AdmissibilityTierView` — "does this variant fit a 16/32/64/128 GB Mac?" (pure; reuses `MemoryGovernor.footprintSplit`) |
| Headless autorun | `HeadlessAutorun.request(prefix:)` — env-driven GUI-less single run for scriptable `xcodebuild` measurement |

Plus the per-plane live benches: `StreamingBench` → `StreamingRun` (`[STR]`),
`CancellationRun` (`[CAN]`), `InferenceModeRun` (`[INF]`), and — contract 1.39.0 —
`LiveTranscriptionBench` → `LiveTranscriptionRun` (`[LIV]`): time-to-first-chunk, chunk cadence,
and **commitment lag** (`processedSeconds − committedThrough`, the provisional window a caption UI
renders as unsettled) over a real `engine.transcribeLive()` session, with the LIV-2/4/5 verdicts
from the same drive. Latency is a bench, not a gate.

Model-store grant (the seventh seam) is already in `MLXEngineUI` (`ModelStorageModel`) — reuse it.

## Minimal adoption

```swift
import MLXEngineTestKit

// 1. Run a package through the harness (uniform timing + split capture):
let r = try await ValidationHarness.run(engine: engine, registration: P.registration,
            configuration: cfg, capability: .matting, request: req, heartbeatLabel: "matting")
print(r.run.splitLogLine("birefnet"))          // [birefnet] SPLIT floor=… peak=… act=… engine=… reserve=…

// 2. Show the memory + split readout:
EngineMemoryView(snapshot: await engine.memory, run: r.run)

// 3. Tier check (the BiRefNet "does best fit 16 GB?" question):
AdmissibilityTierView(title: "best @2048",
    verdicts: AdmissibilityTiers.check(requirements: P.manifest.requirements,
                                       quant: .fp16, transientHint: 17_900_000_000))
```

Keep it lean: a package that needs a bespoke seam adds it in its own app screen and, if it generalizes,
promotes it here. See the `mlxengine-implementation` skill, topic 7 (smoke-testing) for the per-category
harness checklist this implements.
