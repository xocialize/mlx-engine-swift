<!-- Stub PR template. TODO: refine before launch. -->

## What does this package add?
<!-- Capabilities registered (e.g. Lance → textToImage, textToVideo, imageAnalysis, videoAnalysis). One model may register N surfaces. -->

## Weight provenance (required)
- **Source repo:** <!-- e.g. mlx-community/<name>-<quant> -->
- **Pinned revision / commit:** <!-- exact revision -->
- **Tier:** <!-- 1 / 2 / 3 -->
- **Tier-3 carve-out applies?** <!-- yes/no + justification if yes [CONFIRM policy] -->

## License (both layers)
- **Weight license (SPDX):**
- **Port-code license (SPDX):**
- [ ] Both pass `.permissiveOnly`

## Conformance (C0–C13)
- [ ] Ran the `MLXServeConformance` harness locally
- [ ] C0 contract version declared
- [ ] C1 capability registration (each surface independent)
- [ ] C2 canonical schema conformance (correct canonical output type)
- [ ] C3 canonical artifact I/O (serialized round-trip)
- [ ] C4 modes are request parameters, not surfaces
- [ ] C5 metaData hygiene (no should-be-canonical params smuggled)
- [ ] C6 specialty from governed vocabulary
- [ ] C7 / C8 license gates pass
- [ ] C9 PackageConfiguration (init-time, distinct from request params)
- [ ] C10 requirements manifest
- [ ] C11 MCPBridge introspection
- [ ] C12 `@unknown default` forward-compat
- [ ] C13 runtime governance cooperation (accepts engine instantiation/ownership; runs only in scheduled InferenceActor calls; cooperatively evictable; no private queue/pinned compute)

## Notes for reviewers
<!-- Anything that needed a judgment call, especially metaData vs schema decisions. -->
