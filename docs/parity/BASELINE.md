# Measured local baseline and remaining gates

## Provenance

- Assembled base verified before implementation:
  `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
- Required implementation files and both assembled ledgers existed and were read.
- CPA evidence pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
- All fixture data is synthetic. No native captures, provider requests,
  real credential directories, or live verification were used.
- The initial empty checkout was replaced only after coordinator instruction
  using `jj git fetch --remote local` and `jj new` from the confirmed base.
  No primary checkout changes or mutating Git commands were used.

## Local results

| Gate | Result |
|---|---|
| Original assembled tests before new lab tests | 179 passed |
| Gleam formatting | Passed |
| Gleam suite including lab gate regressions | 193 passed |
| Matrix/fixture schema `check` | Passed; not capability evidence |
| Python offline transport regressions | 7 passed |
| MIMIC `baseline` | Exit 1: **3 of 25 required rows mock-tested** |
| `release` using empty CPA driver config | Exit 1: **0 of 25 required rows release-passed** |
| Actual CPA executable differential run | **Not run: no CPA driver/executable supplied** |
| Live provider verification | **Not run** |

The denominator is the explicit 25 required rows in manifest v1, not all CPA
features or all combinations of providers/protocols/auth/backend modes.
The release failure above tests missing-driver blocking; it is **not** an
observation of CPA behavior.

Measured fail-closed report excerpt (artifact path omitted, other fields
unchanged). A successful MIMIC mock does not override a missing CPA driver:

```json
{
  "id": "claude-messages",
  "required": true,
  "source_evidence": "reviewed",
  "mock_tested": {"status": "passed"},
  "cpa_mock_tested": {"status": "blocked", "reason": "empty driver argv"},
  "differential": {"status": "blocked", "reason": "CPA: empty driver argv"},
  "live_verified": "not_run",
  "passed_in_selected_mode": false,
  "fixture_sha256": "2f409e3e6e6ce9427a353c6270d5a270cf99644609dfbedc903e65744c93c7f5"
}
```

### Actual localhost observations

The shipped driver starts a synthetic upstream and the *actual assembled*
ingress in a separate BEAM process for each probe.

| Fixture | Authenticated result |
|---|---|
| `messages-v1` | HTTP 200; expected native body, credential substitution, unauthorized request rejected before upstream |
| `chat-v1` | HTTP 200; translated upstream Messages request and expected text/usage/finish semantics |
| `models-v1` | HTTP 404 |
| `count-v1` | HTTP 404 |
| `responses-v1` | HTTP 404 |
| `compact-v1` | HTTP 404 |
| `codex-alias-v1` | HTTP 404 |
| `gemini-v1` | HTTP 404 |
| `gemini-models-v1` | HTTP 404 |
| `restart-v1` | Two independent driver/BEAM processes; stored synthetic credentials loaded without reseeding; two credential values isolated; real ingress forwarding after restart |

Chat's response text is an array of text blocks on this base. The narrow mock
semantic assertion permits the equivalent string or text-block form; **raw
response bytes are retained for differential comparison**, not normalized.
No claim is made that CPA emits the same representation.

The persistence result covers `mimic/auth/storage` and credential use by the
test boot path. It is **not** evidence that a provider OAuth login, managed
fleet refresh, or session cache persists correctly.

### Explicit blockers

The following are versioned fixture contracts and required checks, **not yet
executable provider scenarios in the shipped baseline driver**:

- Responses SSE and WS, compact semantics and native Codex continuation;
- tools/results, reasoning replay, supported/rejected multimodal forms;
- stream terminal/disconnect/cancel and no replay after partial delivery;
- expired-token/refresh/singleflight and refresh failure handling;
- credential-scoped session reuse, revocation and restart;
- quota/reset/failover across multiple actual accounts;
- native Kimi versus generic compatibility, xAI API versus Grok Build;
- Antigravity wrapper semantics and provider-specific mock adapters.

These return `unsupported` or failed checks, never pass. Provider-stream unit
tests are useful additional evidence, but they must be connected to real
localhost drivers before satisfying these rows.

The starting runtime audit additionally reported managed HTTPS rejection,
one-credential fleet ownership, unsupported Codex login, and unsupported Gemini
codec. Those are coordinator-supplied starting facts, **not remeasured by this
lab's buffered ingress probes**. They remain open and are not negated by green
unit tests.

## Pinned source review

Reviewed source locations (public source read, not executable measurements):

- [CPA route registration](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/api/server_routes.go#L60-L127):
  models, Messages/count_tokens, Responses HTTP/WS/compact, direct Codex aliases,
  Gemini models/actions.
- [Gemini API key preparation](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/gemini_executor.go#L84-L95):
  `x-goog-api-key`, no inference of a CLI OAuth adapter.
- [Gemini URL construction](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/gemini_executor.go#L179-L194)
  and [API-key refresh no-op](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/gemini_executor.go#L728-L734).
- [Kimi refresh](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/kimi_executor.go#L942-L1007)
  and [xAI refresh](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/xai_executor_auth.go#L15-L74)
  confirm distinct credential flows; full native backend applicability remains
  `pending` in the manifest.

Other source links in the manifest are pinned investigation targets, explicitly
`pending` rather than claims of reviewed support. Gemini CLI Code Assist OAuth
is excluded from CPA-required scope, per the Gemini stream's source finding.

## Next integration step

Coordinator: merge only the three owned namespaces, wire the exact separate
CI hooks from [README.md](README.md), and have adapter owners supply the
driver implementations. Read the per-row source state before treating a
fixture as the final CPA contract. Re-run against the **assembled new runtime**
and the pinned CPA executable in a no-egress environment.

Reports and raw plan/results are under ignored `build/parity-results/`; archive
them from CI before disposing the workspace. No report can be imported to bypass
fresh execution. No release parity or live parity has been established.
