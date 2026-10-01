# Pinned CPA source drift — no silent upgrade

**Decision: retain unmodified CPA `acdace936fa7df2905500c7f5e0a97d683138dea`.**
The later source `97f244b8ddb9cbf564b6e6faab0159102cca8617` is a frozen
comparison from the foundation review, not today's HEAD or the running service.
Changing the reference needs a new reviewed source/fixture contract and F03
qualification; it cannot rewrite historical **0/37**.

Both public codeload archives were downloaded again during this recovery, with
normal TLS, no ambient proxy/credential discovery, 60-second socket timeouts,
32 MiB archive / 128 MiB expanded limits, safe regular-file-only extraction and
exact archive digest checks. No source was built or executed.

| Role | Revision | Archive SHA256 | Regular files |
| --- | --- | --- | ---: |
| Contract pin | `acdace936fa7df2905500c7f5e0a97d683138dea` | `56c970726edbd07591b77c1b6be18f733368f8a2f52a2f0931c928b30c13b540` | 1663 |
| Comparison only | `97f244b8ddb9cbf564b6e6faab0159102cca8617` | `4292170dba8bc8933248c6e292e015b20bef9dfa4f9efb8c5197ae50f566a988` | 1687 |

- [Historical archive](https://codeload.github.com/router-for-me/CLIProxyAPI/tar.gz/acdace936fa7df2905500c7f5e0a97d683138dea)
- [Compared archive](https://codeload.github.com/router-for-me/CLIProxyAPI/tar.gz/97f244b8ddb9cbf564b6e6faab0159102cca8617)

Actual whole-tree SHA256 comparison found **164 changed paths**:
25 added, 1 removed, 138 modified. The regenerated local ledger is
`build/f01-source/changed-files.json`, SHA256
`8d4a724fe5ab2fb78cd51621e5dae9a920b5165ed72ec183350bc6bd923d06b0`.
This is an ignored reproducible source-analysis artifact, not portable runtime
evidence. Its serialization differs from the old foundation ledger; the actual
path counts agree. Fifteen of the current catalog's 54 files changed.

## Bounded semantic review actually repeated

| Changed source | Inspected difference | Consequence |
| --- | --- | --- |
| `helps/kimi_responses.go` | Later `NormalizeKimiResponsesInput` reorders matching parallel tool outputs ahead of intervening non-tool items after a complete batch | Absent at the historical pin; no backdated normalization requirement |
| `devin_executor.go` | Later stream defers `interaction.created` until real content and suppresses pre-content failure payload events for bootstrap HTTP errors | Creation/error timing is pin-specific |
| `codex_executor_stream.go` | Executor-aware payload config, emitted-payload accounting and empty-stream handling changed; identity-confuse/expose plumbing removed | Sparse/empty stream expectations need a new version, not fixture rewriting |
| `conductor_refresh.go` | Later refresh jobs carry registration epochs, avoid duplicate jobs, reject stale epochs and warn about lost refreshed-auth persistence | Do not backdate protection into historical expiry/shared-waiter proof |
| `server_routes.go` | Core routes retained; later Home Codex model formatting adds configurable max context length | Route continuity does not prove discovery metadata equivalence |

Other changed catalog files were hash-inventoried, **not semantically
requalified in this recovery**:

- `internal/client/codex/optimize-multi-agent-v2/optimize_multi_agent_v2.go`
- `internal/runtime/executor/claude_executor_request.go`
- `internal/runtime/executor/codex_executor_execute.go`
- `internal/runtime/executor/kimi_executor.go`
- `internal/runtime/executor/openai_compat_executor.go`
- `internal/runtime/executor/xai_executor_request.go`
- `sdk/api/handlers/handlers_stream.go`
- `sdk/api/handlers/model_execution.go`
- `sdk/cliproxy/auth/conductor_execution.go`
- `sdk/cliproxy/service_executors.go`

Source anchors for the comparison remain pinned:

- [Kimi input normalization](https://github.com/router-for-me/CLIProxyAPI/blob/97f244b8ddb9cbf564b6e6faab0159102cca8617/internal/runtime/executor/helps/kimi_responses.go#L73-L188)
- [Devin deferred creation](https://github.com/router-for-me/CLIProxyAPI/blob/97f244b8ddb9cbf564b6e6faab0159102cca8617/internal/runtime/executor/devin_executor.go#L493-L526)
- [Codex emitted-payload accounting](https://github.com/router-for-me/CLIProxyAPI/blob/97f244b8ddb9cbf564b6e6faab0159102cca8617/internal/runtime/executor/codex_executor_stream.go#L358-L479)
- [Refresh job epochs](https://github.com/router-for-me/CLIProxyAPI/blob/97f244b8ddb9cbf564b6e6faab0159102cca8617/sdk/cliproxy/auth/conductor_refresh.go#L325-L386)
- [Home model settings](https://github.com/router-for-me/CLIProxyAPI/blob/97f244b8ddb9cbf564b6e6faab0159102cca8617/internal/api/server_routes.go#L748-L773)

## Limits

This is neither an exhaustive semantic audit of all 164 paths nor any build,
inference, TLS fingerprint, native workflow or benchmark result. Upstream
source comments describing their measurements are quotes, not measurements
obtained by MIMIC/F01.

F01 cannot attribute the source/build/config of `https://localhost:8317`.
F02 supplies containment; F03 qualifies the actual CPA reference; F04 owns
explicitly authorized budgeted live execution. Provider peers/shared harness
own differential assertions; coordinator owns destination admission. None of
the unresolved [stronger source obligations](SOURCE_MAP.md#L139) becomes resolved
because a later source revision adds nearby code.
