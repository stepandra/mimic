# Claude policy source snapshot v1

Repository: <https://github.com/router-for-me/CLIProxyAPI>.
Immutable pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
MIMIC base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.

This is an inventory of **source behavior**, not a measurement of Claude,
Claude Code, TLS fingerprints, account entitlements, or model availability.
CPA comments describing captures are CPA's evidence claims, not MIMIC captures.
The source references include future/experimental model names; they do not
establish that an operator can use those models.

## Inspected source paths and tests

All paths below are relative to CPA at the pinned commit.

| Area | Implementation inspected | Relevant pinned tests |
|---|---|---|
| Buffered/native/translated execution | `internal/runtime/executor/claude_executor_execute.go`: `Execute`; request thinking, forced tools, sampling, cache placement/TTL, native-vs-translated response route | `claude_messages_passthrough_test.go`: direct Messages caller shape, exact API-key betas, OAuth session/body alignment |
| Streaming | `claude_executor_stream.go`: `ExecuteStream`; same request preparation, native passthrough, terminal tracking, usage | `claude_executor_stream_terminal_test.go`: disconnect after terminal is not failure, native and translated |
| Count tokens | `claude_executor_tokens.go`: separate actual HTTP endpoint and field pruning, not estimation | `claude_executor_beta_policy_test.go`: advisor count-token beta |
| Request/betas | `claude_executor_request.go`: `claudeCodeCLIBetas`, `claudeCountTokensBetasForCredential`, `disableThinkingIfToolChoiceForced`, `normalizeClaudeSamplingForUpstream`, `withClaudeAdvisorToolBeta`, `applyClaudeHeadersWithNativeProfile` | `claude_executor_beta_policy_test.go`, `claude_executor_beta_passthrough_test.go`: unknown beta preservation; managed gating; advisor order; fast-mode parity; native-only gateway hints |
| Cache/cloak | `claude_executor_cloaking.go`: `shouldEnsureCacheControl`, `ensureCacheControl`, `injectToolsCacheControl`, `injectSystemCacheControl`, `injectMessagesCacheControl`, `upgradeClaudeCacheControlTTL`, `normalizeCacheControlTTL`, `enforceCacheControlLimit` | `claude_executor_subagent_ttl_regression_test.go`: explicit 1h subagents for OAuth and API key, streaming and buffered; default 5m |
| Fingerprint ownership | `claude_fingerprint_policy.go`; API-key defaults caller-owned, explicit CLI profile distinct, OAuth profile branch | `claude_messages_passthrough_test.go`, `claude_executor_native_helper_test.go` |
| Native detection | `helps/claude_client_detection.go`: full signals and narrow helper profiles, not UA-only classification | `claude_executor_native_helper_test.go`: markerless minimal helper, structured streaming helper, 2.1.280 title helper, origin-sensitive request ID |
| Identity/session | `helps/claude_credential_identity.go`: selected-credential rewrite, duplicate-aware user ID; `helps/claude_code_session.go`: session identity | Native session/body alignment tests above; no MIMIC device-pool generation adopted |
| Thinking | `internal/thinking/provider/claude/apply.go`: registry-dependent manual/adaptive thinking, disabled field pruning, budget normalization | MIMIC does not import CPA's registry or guess capability/budget defaults |

Except where fully qualified, executor/test paths in this table are under
`internal/runtime/executor/`.

Direct immutable references:

- [Request/beta/sampling](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_request.go#L179-L650)
- [Forced tools and sampling](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_request.go#L776-L845)
- [Header/native/count distinctions](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_request.go#L1061-L1455)
- [Cache defaults and TTL](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_cloaking.go#L1499-L1820)
- [Cache host selection](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_cloaking.go#L2000-L2200)
- [Native detector/versioned helpers](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/claude_client_detection.go#L22-L140)
- [Selected-credential metadata](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/claude_credential_identity.go#L265-L305)

## Model × version × auth × request-kind policy

| Source model/version scope | Native Messages | Translated Messages | Count tokens | Auth/turn distinctions |
|---|---|---|---|---|
| All models; pinned executor | Forced `any`/`tool` removes thinking and only `output_config.effort`; preserve other output extensions. Active thinking removes top_k, invalid temperature/top_p; otherwise temperature wins over top_p | Same forced-tool rule; remove temperature and top_p regardless of thinking; top_k only with active thinking | Actual `/v1/messages/count_tokens?beta=true`; no fabricated count | OAuth selected credential supplies account/device/session; API key never gets OAuth identity |
| Haiku; helper shapes in 2.1.220/258/280 source | Effort beta gated off; preserve supplied tool/thinking content | Same explicit beta gate, not an invented effort-to-budget conversion | Separate count profile, no inference defaults copied | Helper profile suppresses effort/display/extended-TTL flags; MIMIC rejects explicit 1h helper cache rather than stripping TTL |
| Legacy Claude 3 family | CPA CLI profile uses legacy system placement | CPA can cloak/rebuild system; MIMIC does not | Separate count profile | MIMIC records model class but preserves caller content; no inferred capability flags |
| Opus/Sonnet 4 family | Caller-owned explicit thinking/display/effort | CPA registry controls adaptive/budget conversion; MIMIC expects already translated Claude JSON | Same endpoint/profile split | Explicit display removes redact-thinking conflict; disabled/forced thinking gates display beta |
| Opus 5.5 / Fable 5.1 / Sonnet 5, source Code 2.1.280 | CPA CLI profile derives progress-display, binding, clear-at; Sonnet 5 excludes automatic mid-conversation-tool-changes | CPA cloak can add these and per-turn flags; MIMIC does **not** auto-infer this profile | These inference defaults are not the count baseline | Names are source predicates, not verified model availability; explicit extensions preserved |
| Unknown/future model or client version | Preserve explicit JSON/extensions, no optimistic capability inference | Explicit sampling/cache selection only; no synthetic native classification | Count endpoint remains distinct | Unmanaged beta order preserved; unsupported shapes/layouts fail explicitly |
| Native 2.1.220 count profile | N/A | N/A | Code, optional OAuth, interleaved-thinking, context-management, token-counting, in that order | Native supplied beta list is caller-owned with credential/conflict gates; translated mode explicitly selects the small baseline and retains unmanaged extras |
| Subagent vs conversation | Native explicit cache layout preserved | Automatic placement only when opted in and no explicit markers | No automatic placement | Subagent without explicit 1h removes extended-TTL; explicit valid 1h pairs beta even for API key. New 1h injection requires operator-approved OAuth policy |

### Managed/unmanaged betas and cache ordering

CPA has a managed-beta set and a CLI ordered baseline, but caller-owned mode is
not the same as CLI mode. MIMIC implements a managed set for the explicit
translated count profile; it does not blindly filter unknown flags. Header flags
precede body-lifted flags, duplicates collapse at first occurrence. OAuth is
inserted after leading `claude-code`, otherwise first. API key removes OAuth.
Advisor is placed before CPA's known trailer boundaries; speed=fast adds its
protocol beta. Explicit thinking display conflicts with redact-thinking.

Cache evaluation order is tools → system → messages. Explicit layouts validate
at ≤4 markers and never 1h after 5m. CPA may delete/downgrade invalid markers;
MIMIC deliberately rejects instead. Opted-in translated default placement is
last system, or last non-deferred tool if no cacheable system, plus last eligible
user/assistant turn. Assistant trailing thinking is skipped; final system-string
special case is retained. Existing explicit markers suppress all default
placement. Generated controls use `type` then optional `ttl`; user extensions
and explicit controls are preserved. Native placement is never auto-selected.

## Deliberately unsupported / not inferred

- Full CLI cloak, billing tags/CCH signing, fake user IDs, device pools, MCP alias
  rewriting, fallback-model substitution, diagnostics injection, and registry
  thinking-budget conversion are not enabled.
- No transport impersonation or claim of native header/TLS/compression parity.
  The existing strict HTTP/SSE pump uses identity encoding.
- No OAuth profile/usage/telemetry companion network calls. Imported account and
  organization metadata remains private and refreshed through existing v4 fences.
  Unknown mandatory companion workflows require explicit operator approval.
- No native-client detector from caller Authorization, user-agent, body identity,
  or four copied source signals. Trust is an integration/operator decision.

## Source SHA256 snapshot

These are fetched file-byte hashes, not executed CPA test results. Retrieve with
`https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/<pin>/<path>`.

```
f08b93d7770b67d98134a6b88c11aa9fc015c747d9a5681f220d4e751cecabbd  internal/runtime/executor/claude_executor_request.go
9ee74f7a0cd1b0f74c117ff58b4d8e495f4800637ce24a63a7f0b2e6a542fc14  internal/runtime/executor/claude_executor_execute.go
039dd4bcf541ff64184fbb9248d13d637b4ca3ec0dcc116a281525bfccfa4e68  internal/runtime/executor/claude_executor_stream.go
683d5478ad0caea582c9442755ef021d5acba36275965b2d2beace39223021ae  internal/runtime/executor/claude_executor_tokens.go
341ab01e3798ef32f35e290405fc8b19e516cfca499328ab61bd1f16292d7618  internal/runtime/executor/claude_executor_cloaking.go
0354485b45cbe3e0b62ae9f7f76c7fefba99cfe3fa064656a3c03f75cad25529  internal/runtime/executor/claude_fingerprint_policy.go
c172ee33995eb47ec7e7df7807a5a336e2239079b11006a1ef2d3239bdeb8c48  internal/runtime/executor/claude_executor_beta_policy_test.go
428a4d01e7813e66dd03c4526330618a946e01313d9f6d466862b321fd060f36  internal/runtime/executor/claude_executor_beta_passthrough_test.go
b2f0b47554b35a6097f982584818c666cc9a24d232e7b1871a2f8ac8dabe9c20  internal/runtime/executor/claude_executor_native_helper_test.go
541acb20954fcaf86e090a03dd99b4be44554ee0eca706e1da330815df052b44  internal/runtime/executor/claude_executor_stream_terminal_test.go
2bb71cef6ed19f6190499768ef2dc2d18fb60d0fcd36507a339be0edcd45aa8f  internal/runtime/executor/claude_executor_subagent_ttl_regression_test.go
471ff71fdbbec9df05bb5156dcdbb7ef766d3272e24d49a0fb5fd05e9216d3cb  internal/runtime/executor/claude_messages_passthrough_test.go
465a77c4ec045c6962b1a160e6e51da780d132d2fbbf6fb72d03bb57315464a9  internal/runtime/executor/helps/claude_client_detection.go
40cb43f38cf1668f0b1f3d3d3484be8a16183f82baa0e3f3e28128421ed8c48a  internal/runtime/executor/helps/claude_credential_identity.go
83a53f393e05ed839d6c98a2749bd32636d978db4e0973e426de742c2b6aeba0  internal/runtime/executor/helps/claude_code_session.go
386191ce14321b6d7b7f4041946d0dbd8b65a94953b2740e4282797344fde59c  internal/thinking/provider/claude/apply.go
```
