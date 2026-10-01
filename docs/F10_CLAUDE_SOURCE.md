# F10 Claude inference 429 source contract

Recovered read-only from corrected packet
`074a8e620f8e6406ebe21fb97707eef218dde050` in old thread
`ksQQVCxI78U2RVSszbHl9CfSlZLOAFQ9t5IBxBDu1fs15rdKs6m5jRdeJnRz`.
Historical commands are evidence descriptions, not instructions to execute.
The attached input is `dd15c610ec39e4f296c30fe02347d0d2b368a629` plus the
parent's materialized F08/F09/config/UI work. No whole-branch import occurred.

The source-only reference is public `router-for-me/CLIProxyAPI` at immutable
`acdace936fa7df2905500c7f5e0a97d683138dea`. The 15 source files below were fetched
as bounded public raw-source reads and their original packet hashes verified
again (`build/f10/public-source-1.log`, `cpa-source-manifest.json`). No CPA
executable, localhost:8317, provider, real account/credentials or login was used.
These are source observations, not executed CPA tests or differential proof.

## Pinned raw-source hashes

| Path | SHA-256 |
| --- | --- |
| `internal/runtime/executor/claude_executor_execute.go` | `9ee74f7a0cd1b0f74c117ff58b4d8e495f4800637ce24a63a7f0b2e6a542fc14` |
| `internal/runtime/executor/claude_executor_stream.go` | `039dd4bcf541ff64184fbb9248d13d637b4ca3ec0dcc116a281525bfccfa4e68` |
| `internal/runtime/executor/claude_executor_tokens.go` | `683d5478ad0caea582c9442755ef021d5acba36275965b2d2beace39223021ae` |
| `internal/runtime/executor/claude_executor_request.go` | `f08b93d7770b67d98134a6b88c11aa9fc015c747d9a5681f220d4e751cecabbd` |
| `internal/runtime/executor/claude_executor_fast_error.go` | `32f3fe04405828ad02917f4c20107b2fe10165d568eb0725f0632e828ec9ae67` |
| `internal/runtime/executor/helps/claude_ratelimit.go` | `7ab230f3abb63044734d2453683376cc75812ee52e56a34b21a0faf93967bdb6` |
| `internal/runtime/executor/claude_executor_fast_error_test.go` | `7270282b152718e5c4ad26a3c717ee5dee12d8d1b2fc7242c35349240a4d8ef9` |
| `internal/runtime/executor/claude_executor_ratelimit_test.go` | `cf46e371aa5862e6aadafc8ffd327364b6a39b48bb34a534338858420902d8c5` |
| `internal/runtime/executor/helps/claude_ratelimit_test.go` | `fcb30b602cc52c49344b18ae84bd3e726084fb7cd41b85cccda27a3c0aef4741` |
| `sdk/cliproxy/auth/claude_ratelimit_cooldown_test.go` | `e6689668997f00e3d665f64da1a0c133673be918fc30df6e61b9f207a72c7832` |
| `sdk/cliproxy/auth/conductor_execution.go` | `a99557dbd0addb735f79eb4b51567e00f8c2f1f517c8683110555c9172db3d79` |
| `sdk/api/handlers/claude/code_handlers.go` | `3afba2f9a94c0b1e1eb389f7ba5a6f45f79ecf87a4042877c43e18585ee145f8` |
| `sdk/api/handlers/claude/code_handlers_error_test.go` | `607950cb58f56bf6989587ef6d23f5a589774ce410dc98c7981dbb7d62232dad` |
| `sdk/api/handlers/handlers_execution.go` | `d21bcdc068ce397b4583de8340001397ca007eae997321d9f3d712208601e372` |
| `sdk/cliproxy/executor/types.go` | `ac8311c1017219c8ec97546b854443f24d9cfe357f4eb5a72bb99e29fc52406f` |

## Executor → auth manager → public handler

- [`Execute:315–368`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_execute.go#L315-L368)
  and [`ExecuteStream:309–362`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_stream.go#L309-L362)
  classify before stream output. Fast uses a direct-response wrapper; ordinary
  traffic uses body/header classification. Post-start stream failures remain a
  separate non-replay boundary.
- [`countTokensUpstream:245–274`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_tokens.go#L245-L274)
  uses ordinary classification, not Fast's direct wrapper. Non-first-party
  local estimation is separate; loopback counting is not measured first-party
  counting behavior.
- [`classifyClaudeUpstreamErrorWithCooling:690–718`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_request.go#L690-L718)
  checks unified scope before Fast-credit text. Unknown ordinary 429s becoming
  model-scoped in CPA does not authorize MIMIC replay.
- [`newClaudeFastDirectResponseError:136–163`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_fast_error.go#L136-L163)
  uses unified headers for credential scope and clones decoded raw response
  bytes. MIMIC never transfers those bytes or private headers to runtime.
- [`ClaudeHeadersIndicateUnifiedRateLimitRejection:24–101`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/claude_ratelimit.go#L24-L101)
  gives explicit 5h/7d rejection precedence. Overage/Fable-only stays
  model-scoped when shared windows are healthy. An omitted shared status
  requires valid nonnegative utilization <1.
- [`parseClaudeRateLimitResetWithFuzz:111–233`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/helps/claude_ratelimit.go#L111-L233)
  chooses the latest applicable deadline. Allowed-window resets are ignored;
  combined Fable reset can contribute after shared scope is proven. CPA adds
  random 1–30s grace; MIMIC does not claim that behavior.
- [`executionErrorMessage:334–378`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/handlers_execution.go#L334-L378)
  recognizes `RequestTerminatedError` and carries `DirectResponse`.
  [`handleStreamingResponse:249–299`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/claude/code_handlers.go#L249-L299)
  waits for first output/error before committing SSE.
  [`WriteErrorResponse:362–412`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/claude/code_handlers.go#L362-L412)
  forwards raw direct responses or status-specific JSON/safe Retry-After.

Pinned [`rate-limit tests:293–418`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/claude_executor_ratelimit_test.go#L293-L418)
distinguish explicit shared rejection with Fast refusal (cooldown/failover)
from Retry-After-only credits (no credential penalty). These CPA tests were
read, not executed.

## Strict MIMIC admission

Classification applies only to actual HTTP 429. Require one supplied valid
JSON Content-Type, singleton critical fields, bounded ASCII timing/scope
syntax and complete UTF-8 body. F08's existing `oauth.response_json` and
`json_guard` reject decoded duplicate keys, including escaped duplicates.
No second parser is introduced.

Known envelope: root object with only `type`, `error`, optional `request_id`;
root type absent or `"error"`; bounded request ID; error object with only
`type:"rate_limit_error"` and nonempty string `message` ≤16 KiB. Other codes,
unknown fields, mixed success/error shapes and malformed JSON are unqualified.

| Admitted evidence | Decision | Observe / automatic replay |
| --- | --- | --- |
| Unknown/malformed/duplicate/budget-failed body, even with rejected headers | Unknown/uncertain | Neither |
| Rate error without affirmative shared evidence | Unknown; recognized Fast-credit/refusal is request-scoped | Neither |
| Retry-After alone + Fast credits | Request-scoped; discard timing hint | Neither |
| Explicit shared 5h/7d rejected, aggregate absent/rejected | Shared quota, including Fast-text precedence | Sanitized Observe, bounded failover |
| Shared rejected but aggregate allowed/allowed_warning | Contradictory/unknown | Neither |
| Aggregate rejected, ordinary rate error, no overage evidence and not both windows healthy | Qualified aggregate shared quota | Sanitized Observe, bounded failover |
| Aggregate-only rejection + Fast-credit/refusal text | Contradictory/unknown | Neither |
| Aggregate rejected, both windows healthy, no overage evidence | Contradictory/unknown | Neither |
| Overage/Fable indicated and both shared windows healthy | Request/model scope | Neither |
| Overage indicated, missing/invalid/exhausted shared health, no explicit shared rejection | Ambiguous/unknown | Neither |
| Explicit shared rejected + Fable/overage rejected | Shared quota; applicable combined reset may extend delay | Sanitized Observe, bounded failover |
| Ordinary model-level rejection with healthy shared windows | Request/model scope | Neither |

This is intentionally stricter than CPA. In particular, malformed or ambiguous
evidence does not become a replay permit.

## Bounds, clocks and strict dates

- Accepted body ≤49,152 bytes. Payload pulls ≤65,536 bytes, reserving one
  maximum 16,384-byte framer pull to establish EOF; ≤32 pull events including
  EOF. Existing HTTP framing caps remain: ≤8 KiB line and at most three OS
  body/framing reads per pull. Payload bound is not an all-wire-byte claim.
- One 500ms absolute monotonic deadline covers every nested body/framing read,
  EOF, UTF-8, bounded JSON parsing and decision. A post-parse expiry denies
  admission. `mimic_egress_ffi.now_ms()` can be negative. Epoch milliseconds
  are used only for converting absolute reset hints to delays.
- Numeric Retry-After is unsigned seconds, ≤3 fractional digits; reset numeric
  units are Unix seconds, never guessed milliseconds. Signs, exponent syntax,
  NaN/Inf, excessive precision, combined/duplicate hints and refresh-only
  Retry-After-ms are rejected.
- Conversion is not admission: before unchanged quota date FFI, validate the
  entire ≤256-byte ASCII date spelling, Gregorian calendar/leap-year validity,
  hours 00–23, minutes/seconds 00–59 and zone components. Validate all reset
  headers, even an allowed-window reset otherwise ignored when choosing delay.
- Preserve IMF-fixdate, RFC850 and asctime (including space-padded single-digit
  day). Tokens/separators must be exact; first two require GMT, asctime has no
  zone. Existing OTP RFC850 `20YY` conversion remains unchanged.
- Preserve `YYYY-MM-DD[Tt ]hh:mm:ss[.DIGIT+](Z|z|±hh:mm)`, offset hours 00–23,
  minutes 00–59, including -00:00. Date fractions use the total header cap,
  not numeric hints' three-digit limit. Existing conversion/rounding remains,
  including `.0009` →1ms then ceiling the public cooldown to seconds.
- `:60` is unknown, including a real leap-second spelling. OTP normalization
  does not prove a leap event; the pinned Go parser also rejects it.
- Latest applicable reset competes with Retry-After. Missing/past/zero hints
  use deterministic 60s fallback, matching runtime's observation floor.
  Ceiling once to whole seconds; max delay is 604,800,000ms (MIMIC's bounded
  seven-day contract, not an upstream measurement). Larger delay is unknown,
  not clamped.

## Current runtime and deliberate downstream differences

`runtime.attempt` Observes every successful `Opened` before rejection. Therefore
classification occurs inside `http_classified.open`:

- Proven request scope returns `Failure(RequestLimited, Rejected, None)` before
  Observe. The parent-approved narrow Reason addition is non-retryable under
  the unchanged runtime allowlist. Parent root maps it to fixed sanitized 429
  **without Retry-After**. No account cooldown, ledger update or second send.
- Unknown/failed classification returns non-retryable Error before Observe;
  parent root retains sanitized 503 with no hint.
- Proven shared quota closes once and returns
  `Opened(429, sanitized_headers, Closed)`. Existing runtime observation and
  `Quota/Rejected/Some(ms)` drive bounded failover. Exhaustion maps to sanitized
  429 with normalized Retry-After; a later all-accounts-cooled NoAccount stays
  503, without an invented hint.

All 429 sockets close exactly in `classify_opened`; reader/classifier never
close, `Closed` cancellation is a no-op. Successful statuses keep their actual
live stream. No body, original headers, private reason/utilization/request ID
or credentials survive classifier output.

The old `http` constructor is unchanged/conservative. The parent owns root
selection, config default false, all root status mapping and admission. Keeping
statuses for proven scope does **not** claim CPA exact body/header parity:
MIMIC deliberately discards upstream text/private headers, narrows ambiguity,
uses deterministic timing and rejects encoded/binary inference bodies.
