# Contributing a package

A contribution is one `ModelPackage` (the engine-owned model unit) declaring a
`PackageManifest`, registering one or more capability surfaces. The merge bar is the
**C0–C14 conformance checklist** — a reviewable pass/fail, not a taste call.

## Workflow

1. Confirm the port is **parity-locked** (that's the `mlx-porting` job, not conformance).
2. Enumerate capabilities → which canonical surfaces does the model expose?
   (`flux2-klein-swift` → `textToImage` + `imageEdit`; one checkpoint, two surfaces)
3. Map each surface to its canonical schema.
4. Identify modes → per-request `Mode` tags; confirm none are masquerading as surfaces.
5. Conform a `ModelPackage`: `nonisolated init(configuration:)`, `@InferenceActor`
   `load()` / `unload()` / `run(_:)`. No compute in `init`; honor `Task` cancellation in `run`.
6. Build its `PackageManifest`: license (both layers), provenance, requirements, specialties,
   one `ToolDescriptor` per surface.
7. Write the package's `Configuration` (a `PackageConfiguration`) — init-time, distinct from the
   request envelope. `StandardConfiguration` covers the common knobs.
8. Publish with `PackageRegistration.of(MyPackage.self)`.
9. Run the `MLXServeConformance` harness; walk [C0–C14](conformance-c0-c13.md). Every box or a
   documented waiver.

## License (two layers — both must be declared)

- **Weight license** (C7): the checkpoint (`weightLicense`).
- **Port-code license** (C8): your contribution (`portCodeLicense`).

Declaring both, accurately, is the requirement. Since contract 1.28.0 the engine does **not** refuse
to load a license outside its policy by default — it records a `LicenseAdvisory` (naming the layer and
the SPDX id) that a host can surface. Whether a non-permissive license is *acceptable* is a review
decision, so state the license honestly and say in your PR why it is shippable. A host running
`licenseEnforcement: .blocking` will still reject it outright, which is the behavior to assume if you
want your package usable everywhere.

## Weight provenance (process requirement)

Weights should originate from HF **mlx-community** for Tier 1/2 ports; record source repo +
pinned revision in your PR. This is enforced by review + `provenance-lint`, not a runtime gate.
