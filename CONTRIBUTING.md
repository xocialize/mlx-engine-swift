# Contributing to MLXEngine

> ## 🚧 Not accepting contributions yet
>
> MLXEngine develops in the open, but **pull requests are not being accepted at this stage and
> will be closed.** The conformance gate below is the intended contributor agreement, documented
> now so it's visible. The runtime itself is shipped and consumable (v0.45.1, contract 1.33.0,
> 47 published packages) — what is still moving is the *contract*, which takes additive minor
> bumps as capabilities and conformance levels land (C14 and its INF gate, for instance, landed
> back in 1.27.0).
> This notice will be lifted once the contract settles.
>
> *(Stub. TODO: expand each section before opening the repo to contributors.)*

MLXEngine is community-released and built to be extended. A contribution is a
**package** — a `ModelPackage` declaring a `PackageManifest` — that registers one or
more capabilities. The bar for merging is the **C0–C14 conformance checklist** — a
reviewable pass/fail, not a taste call.

## Before you start
- Your port must already be **parity-locked** (numerically correct vs. its
  reference). Parity is the porting process's job, not conformance.
- Read [Concepts](docs/concepts.md) and [Contributing a Package](docs/contributing-a-package.md).

## The conformance gate (C0–C14)
The checklist lives at [docs/conformance-c0-c13.md](docs/conformance-c0-c13.md) (filename kept
at `c0-c13` because other repos link it). Run the `MLXServeConformance` harness — plus the
offline MAT / CAN gates and, if your package has an `MLXNN.Module` graph, the C14 INF gate from
`MLXServeConformanceNN` — to self-check before submitting. Reviewers reference C-levels directly.

## Weight origin requirement (process, not code)
- Weights should originate from **HF mlx-community** for Tier 1/2 (single-stack
  LLM/VLM/audio) ports. Record **source repo + pinned revision** in your PR.
- This is a *contribution requirement*, enforced by review + the
  `provenance-lint` check — **not** a runtime gate. The engine's remaining runtime gates are device
  eligibility (C10) and per-file **size** verification on materialized weights; licenses (C7/C8) are
  classified and reported, and only block under opt-in `.blocking` enforcement. Hash-level (SHA256)
  integrity is not implemented yet.
- **Tier-3 pipelines** (T2V/T2I/3D): TODO — state the carve-out [CONFIRM].

## License (two layers — both must be declared)
- **Weight license** (C7): the checkpoint, `weightLicense: SPDXLicense`.
- **Port-code license** (C8): your contribution itself, `portCodeLicense` — distinct from C7.
- **Declaration is the requirement** (contract 1.28.0). A license outside the engine's policy no
  longer blocks loading by default; it is recorded as a `LicenseAdvisory` naming the layer and SPDX
  id, which a host can surface to users. Whether it is *acceptable* is a review call — declare
  honestly and justify it in the PR.
- A host may opt into `licenseEnforcement: .blocking`, which rejects outright and names the failing
  layer. Assume that stricter posture if you want the package usable everywhere.

## Contract versioning
- The capability enum and C-levels are **additive-only** at minor versions;
  consumers must `@unknown default`. Breaking changes are major + deprecation window.
- Declare the conformance-spec version you target (C0).

## PR process
TODO: branch naming, review routing (CODEOWNERS), CI expectations
(ci / conformance / provenance-lint), and the PR template fields.
