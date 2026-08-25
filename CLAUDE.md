# mlx-engine-swift — area contract

The engine — MLXToolKit (contract), MLXServeCore (governor/materialization/admission),
MLXEngineUI (DesignScaffold-conformant panels). `docs/model-registry.md` is the living registry;
the README status block is lint-enforced against ContractVersion + the newest tag.

## Bridge identity

**AREA-ID: `mlx-engine`** (aliases: `MLXEngine`, `mlxengine`, `engine`) — work in this directory answers for that
identity on the bridge. **Session start: `bridge assume mlx-engine`** — owed asks, open
tasks, and the context pack in one command. Assumption is informational, never a
lock: a stale last-assumed age in `bridge areas` means nobody is home, and you take
over by assuming. File answers/asks under this id; the roster validates recipients.
