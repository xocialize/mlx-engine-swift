# Contributing to MLXEngine

> **Stub. TODO: expand each section before opening the repo to contributors.**

MLXEngine is community-released and built to be extended. A contribution is a
**package** — a `ModelPackage` declaring a `PackageManifest` — that registers one or
more capabilities. The bar for merging is the **C0–C13 conformance checklist** — a
reviewable pass/fail, not a taste call.

## Before you start
- Your port must already be **parity-locked** (numerically correct vs. its
  reference). Parity is the porting process's job, not conformance.
- Read [Concepts](docs/concepts.md) and [Contributing a Package](docs/contributing-a-package.md).

## The conformance gate (C0–C13)
TODO: link the authoritative checklist. Run the `MLXServeConformance` harness to
self-check before submitting. Reviewers will reference C-levels directly.

## Weight origin requirement (process, not code)
- Weights should originate from **HF mlx-community** for Tier 1/2 (single-stack
  LLM/VLM/audio) ports. Record **source repo + pinned revision** in your PR.
- This is a *contribution requirement*, enforced by review + the
  `provenance-lint` check — **not** a runtime gate. The engine's runtime gates
  are license (C7/C8) and SHA256 integrity only.
- **Tier-3 pipelines** (T2V/T2I/3D): TODO — state the carve-out [CONFIRM].

## License (two layers — both must be permissive)
- **Weight license** (C7): the checkpoint, `weightLicense: SPDXLicense`, `.permissiveOnly`.
- **Port-code license** (C8): your contribution itself.
- A rejection will name which layer and which license failed.

## Contract versioning
- The capability enum and C-levels are **additive-only** at minor versions;
  consumers must `@unknown default`. Breaking changes are major + deprecation window.
- Declare the conformance-spec version you target (C0).

## PR process
TODO: branch naming, review routing (CODEOWNERS), CI expectations
(ci / conformance / provenance-lint), and the PR template fields.
