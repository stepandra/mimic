# F09 Claude source boundary

Source-only pin: `router-for-me/CLIProxyAPI` at
`acdace936fa7df2905500c7f5e0a97d683138dea`. Initial MIMIC base:
`dae5652093fd4f4d31d07e9383955d0ce54af963` (F08); underlying upstream-requested
base `ca86b531`. No F11 feature is adopted.

`CLAUDE_POLICY_SOURCE_V1.md` is historical and unchanged. Its count table must
not be read as the whole CPA count route: custom origins use local estimation
in CPA; the first-party count executor does NOT run the Messages-only
forced-tool, sampling or default-cache helpers.

## Evidence labels

| Label | Meaning |
| --- | --- |
| source | Immutable CPA bytes inspected; no CPA execution |
| mock | Synthetic loopback upstream, actual `gateway.start` and endpoint response |
| diff | Separately authored ordered source-derived expectations vs MIMIC, not executable CPA differential parity |
| native | Not performed; no synthetic fixture is a native capture |
| live | Not performed; extra upstream CPA check and live authorization required |

No Foundation `https://localhost:8317`, real login/discovery, native binary,
credential copying, billing signing, telemetry, entitlement inference, or live
inference was used. “Measured” in CPA comments is CPA's claim, not our result.

## Whole route trace

All paths below are at the immutable pin above. Implementation was read, not
inferred from test names.

1. [`sdk/api/handlers/claude/code_handlers.go:79-139`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/claude/code_handlers.go#L79-L139):
   Messages reads raw data, rewrites DD model IDs, and dispatches by `stream`.
   Count has its own handler calling `ExecuteCountWithAuthManager`; buffered
   and streaming response handlers are at lines 176-344. A returned count
   payload is NOT evidence that every executor used an upstream endpoint.
2. [`claude_executor_execute.go:20-310`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_execute.go#L20-L310):
   resolves credential/origin and source/response formats; translation,
   registry-thinking, cloak/payload rules, max-token defaults, forced tools,
   sampling, cache cap/TTL, beta lifting, identity/sanitization/CCH and headers
   precede send. Native response format uses JSON; translated buffered response
   formats can need upstream SSE. This is NOT MIMIC's native-only root route.
3. [`claude_executor_stream.go:22-302`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_stream.go#L22-L302):
   same Messages preparation sequence with streaming transport. It is not a
   distinct beta/sampling policy. Stream termination and transport are F14/F10,
   respectively, not changed by F09.
4. [`claude_executor_tokens.go:23-131`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_tokens.go#L23-L131):
   `shouldUseClaudeUpstreamTokenCount` requires a nonempty selected credential
   and first-party Anthropic base. Otherwise translation/thinking/sanitization
   precede local estimation. **MIMIC does not implement this estimator.**
5. [`claude_executor_tokens.go:134-298`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_tokens.go#L134-L298):
   real `/v1/messages/count_tokens?beta=true`; translation/model-thinking,
   optional system relocation/obfuscation, cache cap and TTL repair, beta lift
   with token-counting, tool alias/sanitization, conditional three-field prune,
   mid-system validation, headers/send, returned `input_tokens`. It never calls
   Messages forced-tool/sampling/default-cache preparation.
6. [`sdk/translator/registry.go:124-196`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/translator/registry.go#L124-L196):
   absent translation preserves payload except selected model and optional
   plugin normalizers. It does NOT prove native count deletes `max_tokens` or
   `stream`. Those two deletions in MIMIC are explicit compatibility policy.

## Predicate and lossy-policy map

Executor paths in this table are under `internal/runtime/executor/`.
`request.go`, `cloaking.go` and `tokens.go` abbreviate the corresponding
`claude_executor_*.go` filenames listed in the byte inventory below.

| Source implementation | F09 behavior / explicit difference |
| --- | --- |
| `claude_executor_request.go:179-303` `claudeCodeCLIBetas` | Full CLI baseline NOT synthesized. Includes source-only model predicates, not capabilities proven for an account. |
| `request.go:286-295,408-425`, `cloaking.go:319-336,437-464` | Full supplied-model Haiku lexical predicate gates effort; descriptive `Model` classes are NOT CPA's legacy-system allowlist, progress capability catalog, or registry. No automatic progress, per-turn, clear-at or inline-tool beta inference. |
| `request.go:419-447,1114-1289` | Header betas precede body-lifted flags, first occurrence wins; unknown flags preserved. Selected API key removes OAuth beta; selected OAuth inserts it after leading code, otherwise first. No credential-prefix detection. |
| `request.go:610-645,1129-1175,1194-1254` `withClaudeAdvisorToolBeta` | Advisor need sees original requested flags/tools; insert in the selected header/count baseline before nine known trailers, append protocol/extras afterward, then apply final removal gates without repositioning advisor. |
| `request.go:430-478,1193-1204` | Nonempty string display excludes redact-thinking; trim/case source predicates for speed=fast and advisor. Fast follows explicit speed in Messages and caller-owned native count, not the translated small count baseline. No display synthesis. |
| `request.go:514-543,1135-1141,1212-1228`; `tokens.go:182-185` | Explicit translated count chooses Code, optional OAuth, interleaved, context-management, token-counting, then advisor before unmanaged extras. Native count appends token-counting as an extra after caller-owned protocol flags, NOT an inferred CLI baseline. |
| `request.go:776-845` | Messages forced `any`/`tool` removes thinking and only effort; preserve other output extensions. Active thinking trims/case-folds predicate: invalid temperature/top_p and top_k removed; otherwise temperature wins over top_p. Translated Messages removes temperature/top_p. Count skips this entire stage. |
| `request.go:1227-1262` | Explicit turn/model conflict gates; MIMIC additionally removes forced-tool effort/display beta, a stricter conflict policy, not exact CPA post-removal effort semantics. Trusted Helper is NOT CPA's body/version detector. |
| `cloaking.go:1499-1770,2000-2190` | Explicit opted-in translated placement only without existing markers. Last system or last non-deferred tool; rolling eligible turn, assistant thinking tail skipped; final string-system special case. Preserve explicit controls/extensions. |
| `cloaking.go:1562-1657,1770-1999` | CPA can upgrade/drop TTL, delete excess markers, downgrade 1h after 5m. MIMIC rejects invalid layouts rather than repairing, never upgrades existing caller markers; injection requires explicit approved OAuth policy, never scopes/overage/query-source inference. |
| `tokens.go:201-212` | CPA removes metadata/context_management/diagnostics for direct Anthropic or CLI profile. MIMIC's declared real compatible endpoint contract removes these AND stream/max_tokens at every configured origin. This is NOT fidelity to CPA's custom-origin estimator. |
| `helps/claude_credential_identity.go:265-314` | Existing selected OAuth account/device/session rewrite retained; duplicate-aware JSON-in-string extensions preserved. No device pool, API-key-derived ID, fake account or fingerprint. Count has no metadata injection. |
| `claude_fingerprint_policy.go:23-43,112-131` | CPA real OAuth selects CLI profile implicitly, optional API key CLI opt-in. MIMIC does NOT infer profile, OAuth lifecycle from a token prefix, entitlement, or capabilities. |
| `helps/claude_client_detection.go:137-180` | No native detector adopted. Root trust is operator policy plus selected context, not incoming UA/X-App/beta/identity signals. |
| `internal/thinking/provider/claude/apply.go:72-270` and `helps/thinking.go` | Registry-validated adaptive/manual/disabled/auto conversion and budget clamping are unsupported. Caller-provided Claude JSON preserved except declared Messages forced-tool/sampling rule. No guessed budget/default/max_tokens; disabled body pruning from a registry route is NOT claimed. |

F09 leaves the conservative Claude 429 wrapper unchanged. Identity encoding,
API-key header on custom origins, no cloak/CCH/MCP/diagnostics/telemetry and
real count instead of estimation are declared MIMIC differences, not hidden
native fidelity.

### Parent-locked stage-order evidence

The initial F09 implementation and golden expectations collapsed header,
profile and lifted-body stages. Parent review corrections follow actual source
order rather than special-casing one beta list. Existing full-file hashes below
were independently re-fetched and verified in the parent. Exact LF-preserving
excerpts were written under ignored `build/f09-review/source/`:

| Source excerpt, same immutable pin | SHA-256 |
| --- | --- |
| `claude_executor_request.go:286-295` full-model Haiku versus separate canonicalization | `2e938d9cda7fd5d6299ab616671c1f256c860862e8aadb89d168182dcf27aa30` |
| `claude_executor_request.go:408-439` effort support predicate | `44379e24d078319c29ce4ad3769e8cb8a49a8426bc421105db1df9f7bee46fd9` |
| `claude_executor_request.go:514-557` credential-specific count baseline | `3856e1cf281a7ed0d2571ec959a5f05497f45a8a03f473f6e05f736cce11b2fc` |
| `claude_executor_request.go:610-650` advisor insertion/removal | `28ec0a0165be9ec38b46a8e2ba761577a8d9d7090393450089aa8c6dddf8f8b4` |
| `claude_executor_request.go:1129-1254` selected baseline → advisor → protocol/extras → final filters | `2a2aa187ead654ca1c6200a79c715b1971cd1ba0628548c3b47bdbc94a05d51b` |
| `claude_executor_tokens.go:180-186` mandatory count flag appended to lifted extras | `c11b1e7d29f990082943f58dd884a5a576ce3ac4260447dab323ad2221939f02` |

Source header and body input stages remain separate until append. MIMIC still
explicitly splits comma-containing body-array entries, whereas pinned source
`claudeRequestedBetas`/`extractAndRemoveBetas` trims each body entry without
that split. This existing normalization choice is not raw source fidelity.
MIMIC's stricter forced-tool/selected-Helper and selected-API-key OAuth removal
gates remain explicit policy, not claims to implement CPA's client detector.

Additional whole-boundary inspection: `claude_executor.go:66-109` delegates
signature sanitation to `internal/signature` and drops empty web-search domain
arrays; `claude_executor_auth.go` may synthesize account identity or fetch a
profile. Neither lossy sanitation nor that credential discovery/identity path
is adopted. MIMIC preserves caller signatures/tool extensions and uses the
already selected F08 runtime identity. These are further explicit differences.

## Fetched byte SHA-256

Fetched with `curl --fail --silent --show-error --location` from
`https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/<pin>/<path>`.
Ignored local copies: `build/f09/source/`. These hashes are source identity,
not executed reference/test/native results.

```text
073f3aff49aaed90fad354364adc182fd33211eb35a30e1419c64f2dde9d3a4b  internal/runtime/executor/claude_executor.go
11f029919b9540203de09610267beed8a8afbb2cb57900e5642a274198dad70e  internal/runtime/executor/claude_executor_auth.go
f08b93d7770b67d98134a6b88c11aa9fc015c747d9a5681f220d4e751cecabbd  internal/runtime/executor/claude_executor_request.go
9ee74f7a0cd1b0f74c117ff58b4d8e495f4800637ce24a63a7f0b2e6a542fc14  internal/runtime/executor/claude_executor_execute.go
039dd4bcf541ff64184fbb9248d13d637b4ca3ec0dcc116a281525bfccfa4e68  internal/runtime/executor/claude_executor_stream.go
683d5478ad0caea582c9442755ef021d5acba36275965b2d2beace39223021ae  internal/runtime/executor/claude_executor_tokens.go
341ab01e3798ef32f35e290405fc8b19e516cfca499328ab61bd1f16292d7618  internal/runtime/executor/claude_executor_cloaking.go
0354485b45cbe3e0b62ae9f7f76c7fefba99cfe3fa064656a3c03f75cad25529  internal/runtime/executor/claude_fingerprint_policy.go
465a77c4ec045c6962b1a160e6e51da780d132d2fbbf6fb72d03bb57315464a9  internal/runtime/executor/helps/claude_client_detection.go
40cb43f38cf1668f0b1f3d3d3484be8a16183f82baa0e3f3e28128421ed8c48a  internal/runtime/executor/helps/claude_credential_identity.go
83a53f393e05ed839d6c98a2749bd32636d978db4e0973e426de742c2b6aeba0  internal/runtime/executor/helps/claude_code_session.go
d6f171bb2eb4c677c50f52734767faec4016ad37c8076cd21caf5c013f2fd96f  internal/runtime/executor/helps/thinking.go
386191ce14321b6d7b7f4041946d0dbd8b65a94953b2740e4282797344fde59c  internal/thinking/provider/claude/apply.go
3afba2f9a94c0b1e1eb389f7ba5a6f45f79ecf87a4042877c43e18585ee145f8  sdk/api/handlers/claude/code_handlers.go
0f18ae15b747324782555645b1c86f50641ead85ead9e471a449b9bbef126044  sdk/translator/registry.go
c172ee33995eb47ec7e7df7807a5a336e2239079b11006a1ef2d3239bdeb8c48  internal/runtime/executor/claude_executor_beta_policy_test.go
428a4d01e7813e66dd03c4526330618a946e01313d9f6d466862b321fd060f36  internal/runtime/executor/claude_executor_beta_passthrough_test.go
471ff71fdbbec9df05bb5156dcdbb7ef766d3272e24d49a0fb5fd05e9216d3cb  internal/runtime/executor/claude_messages_passthrough_test.go
```
