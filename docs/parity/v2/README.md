# CPA conformance scope v2: Devin replacement

This is a **new user-selected release scope**, not an improvement claim against
the historical v1 scope. CPA remains pinned to
`acdace936fa7df2905500c7f5e0a97d683138dea`; the assembled MIMIC base remains
`c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.

## Scope and history

Active matrix: `test/parity/v2/manifest.json`, scope ID
`cpa-provider-parity-v2-devin`. Wire schema stays at version 1; release-scope
version is 2.

- **37 required rows:** 22 retained requirements, unchanged from v1, and
  15 required Devin rows.
- **Gemini, Antigravity and Copilot: `out_of_scope`.** They are not implemented,
  passing, or skipped coverage in this scope. They are absent from the active
  capability list, so they neither run nor block this scoped release.
- Exclusion metadata is checked: an excluded provider cannot also have an
  active row, and its state cannot be relabeled `passed`.
- The historical v1 matrix, fixture bytes, README, baseline report and frozen
  `build/parity-handoff-v1/` snapshot remain unchanged. Its manifest SHA-256 is
  `5c26b8a2a844c2914edd807bdeb8a9df85d7347b519225844ed9ab0e31650ac7`.
- V1's **25-row baseline is historical evidence for v1 only**. Do not compare
  its denominator, percentages or totals with v2 as parity progress.
- No Gemini/Antigravity code, driver, registration or previous runtime result
  is integrated into this release scope. A model family offered through Devin
  does not imply integration of that family's native provider backend.

## Commands

The runner gains additive manifest selection. With no `--manifest`, it still
selects v1; the release job must explicitly select v2:

```sh
gleam format --check src test
gleam test
gleam run -m parity/runner -- check --manifest test/parity/v2/manifest.json

# Expected NONZERO on the assembled base; Devin scenarios are unsupported.
gleam run -m parity/runner -- baseline scripts/parity/baseline-drivers.json \
  --manifest test/parity/v2/manifest.json

# Expected NONZERO with the example's missing CPA executable driver.
gleam run -m parity/runner -- release scripts/parity/baseline-drivers.json \
  --manifest test/parity/v2/manifest.json

# Actual scoped release job, once both reviewed executable drivers are provided:
gleam run -m parity/runner -- release /absolute/path/to/drivers.json \
  --manifest test/parity/v2/manifest.json
```

New reports identify `scope_id`, `manifest_path`, the manifest SHA-256, explicit
`excluded_providers`, and the selected scope's denominator. Source, MIMIC mock,
CPA mock, differential and live states stay independent. An exclusion is never
added to a pass count. CI changes are still coordinator proposals only.

### V2 validation on the assembled base

| Check | Observed result |
|---|---|
| Formatting and `gleam test` | Passed; **199 tests** |
| Existing real-localhost Python regressions | **7 passed** |
| V1 default and explicit v2 schema checks | Exit 0 |
| V2 mock baseline | **3/37 required rows mock-tested**, exit 1 |
| V2 strict release with empty CPA driver | **0/37 release-passed**, exit 1 |
| All 15 Devin rows | `unsupported`, therefore BLOCKED |
| Excluded providers | Reported `out_of_scope`; no active rows or executions |
| Frozen v1 snapshot | Manifest and all 34 source hashes unchanged |

The three narrow mock successes are Messages, Chat translation and synthetic
credential persistence. This is a result within **v2's own scope**, not a
comparison with v1. The strict run tests missing-CPA-driver blocking; no actual
CPA executable, live service or newly implemented Devin adapter was exercised.
Known intentional differences and source applicability remain blocking.

## Devin required matrix

All rows use **`auth_mode: session_token`**, lifetime **permanent**, upstream
**`devin_connect_rpc`**. Acquisition methods have separate fixtures; they are
not different rotating OAuth token lifetimes.

| Row | Input / capability | Source contract or remaining investigation |
|---|---|---|
| `devin-auth-pkce` | PKCE acquisition, then Chat | S256/state binding; JSON code/verifier exchange; permanent session-token persistence |
| `devin-auth-import` | Manual import, then Messages | Prefix normalization; no OAuth code exchange; permanent persistence |
| `devin-chat-http` | Chat buffered | Translate to Interactions, encode protobuf/Connect, decode buffered response |
| `devin-messages-http` | Messages buffered | Separate input protocol, same native backend; no generic fallback |
| `devin-responses-http` | Responses buffered | Shared Responses translation; usage and output semantics |
| `devin-responses-sse` | Responses SSE | Native Connect frame stream to ordered client SSE |
| `devin-tools` | Responses tool/result turns | Call/result IDs, argument fragments and native tool fields |
| `devin-thinking` | Messages thinking/signatures | Model effort, opaque signature bytes/type and replay |
| `devin-multimodal` | Inline images and unsupported forms | Inline data support; CPA omission versus explicit MIMIC rejection is a known intentional difference, not parity |
| `devin-models` | Discovery | Scoped synthetic catalog, provenance and model UID/effort resolution; no live updater |
| `devin-count-estimate` | Messages count | **Estimate**: `floor(byte_length(executor req.Payload) / 4)`; no native count RPC |
| `devin-stream-lifecycle` | Responses lifecycle | Trailer errors, truncated frames, disconnect/cancel, no post-delivery retry |
| `devin-persisted-isolation` | Chat and restart | Permanent token, account/session/cascade scope, revocation and no reseeding |
| `devin-status-quota` | Status enrichment then Chat | Unary protobuf status/quota observation; **not token rotation** |
| `devin-429-failover` | Chat and restart | HTTP Retry-After, reset/cooldown, bounded failover and account isolation |

Every absent/unsupported Devin scenario is **BLOCKED**. The shipped baseline
driver returns `unsupported` for these scenario fixtures. They are required
contracts, not implemented adapter tests or proof of ingress coverage.
`source_status: reviewed` records inspected CPA code only. Rows still marked
`pending` and checks requiring source applicability remain blocking review work.
No Devin WebSocket or compact support is asserted.

## Pinned source findings

- [Authenticator](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/auth/devin.go#L38-L112):
  `RefreshLead` is nil, PKCE/headless manual token import supported.
- [Authorization and token exchange](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/devin/devin_auth.go#L88-L150):
  `/auth/cli/continue`; JSON POST `/auth/cli/token`, response `token`.
- [Wire authentication](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/devin_executor.go#L97-L123):
  `Basic <token>-<token>`, Connect version 1, no default User-Agent; chat and
  unary headers differ.
- [Binary native request](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/devin_executor.go#L380-L450)
  and [native path/frame constants](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/devin_wire.go#L29-L53):
  `/exa.api_server_pb.ApiServerService/GetChatMessage`, not Devin sessions REST.
- [Status refresh](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/devin_executor.go#L142-L226)
  and [unary status RPC](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/devin/user_status.go#L334-L376):
  `application/proto`, permanent credential unchanged, account/quota enrichment.
- [Count estimate](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/devin_executor.go#L229-L235):
  byte-length heuristic, never an exact tokenizer measurement. Translation can
  change executor payload bytes; do not use the caller's JSON length blindly.
- [Image extraction](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/devin_executor.go#L1749-L1805)
  and [content extraction](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/devin_executor.go#L2007-L2050):
  remote image/audio parts without text are omitted by CPA. Explicit rejection
  required by MIMIC's implementation rules is a deliberate difference. The
  strict differential remains blocked for that case; there is no silent waiver.

HTTP-version applicability is a separate source/execution gate. A successful
MIMIC H1 loopback test does **not** establish CPA/native H1 parity. Source
observations about a net/http transport are not an executed CPA differential.
No TLS fingerprint, H2 fidelity or live compatibility is inferred.

## Driver contract addendum and binary safety

The [v1 driver contract](../CONTRACT.md#test-driver-contract-v1) and executable
skeleton remain valid. Universal `assembled_ingress: true` is still mandatory
and may be emitted only after a real client-facing route request. A runtime
library scenario does not close it.

- The three buffered Devin rows share `http-v2.json`. Select exactly the entry
  in `requests_by_protocol` matching the plan's `input_protocol`.
- Each acquisition fixture specifies `acquisition_mode`; never invent an
  expiration or refresh-token grant for a permanent session token.
- `restart` must use an independent process and existing state without reseeding.
- Preserve binary Connect/protobuf bytes as an explicit base64 field inside
  the observations JSON string. Do not coerce invalid UTF-8 into text.
- **Base64 is NOT redaction.** Devin's real protobuf request body contains the
  session token as well as the authentication header. Raw/base64 observations
  are permitted **only for known synthetic fixture credentials and content**.
  Real request bytes must never enter reports, captures, logs or grounding
  packs. This runner remains an offline synthetic lab, not a live-capture tool.
- Assert synthetic-only provenance before emitting binary observations. Inspect
  all token-bearing metadata/fields, not just HTTP headers. Unknown credential
  provenance must fail closed before persistence; do not log it to diagnose.
- Keep native backend/credential/transport distinctions and all required
  assertions. A reviewed source link or an unsupported scenario cannot pass.

## Handoff boundary

V2 changes only owned parity namespaces. The only existing implementation file
changed is `test/parity/runner.gleam`, to add selection and scope-tagged reports;
the frozen v1 copy is not rewritten. The handoff includes a separate source
manifest and diff against v1. No production namespace or root build/CI changes.
