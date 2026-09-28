# Codex / ChatGPT provider adapter

## Provenance and ownership

- Verified assembled MIMIC base:
  `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
- CPA reference: <https://github.com/router-for-me/CLIProxyAPI/tree/acdace936fa7df2905500c7f5e0a97d683138dea>.
- New implementation owns `src/mimic/providers/codex/**` and `test/codex_*`.
  No root CLI/types/build/route changes, credential manager, HTTP transport,
  SSE parser, WS framing, refresh scheduler, or fleet implementation is duplicated.
- All fixtures are **synthetic**, including token strings, ID-token payloads,
  encrypted reasoning placeholders and usage numbers. They are not captures.
- The pinned model metadata is a small **source-derived metadata subset**,
  not live discovery, a measured catalog, or proof of account entitlement.

### Inspected pinned source

| CPA paths under the pinned revision | Applied observation |
| --- | --- |
| `internal/auth/codex/openai_auth.go`, `pkce.go`, `jwt_parser.go`, `openai_auth_test.go` | Codex client ID, login scope/options, form grants, JWT routing metadata, refresh-token reuse |
| `internal/runtime/executor/codex_executor_execute.go`, `codex_executor_request.go`, cache tests | ChatGPT backend targets, OAuth account header, separate compact, required streaming, scoped cache/session identity |
| `internal/translator/codex/openai/responses/codex_openai-responses_request.go` and tests | Input string expansion, unsupported field removal, system/developer normalization, built-in web-search aliases |
| `internal/runtime/executor/codex_executor_reasoning.go`, signature tests | Opaque encrypted reasoning replay must retain scope and tool relationships |
| `internal/runtime/executor/codex_executor_tokens.go` | Local tokenizer count is an estimate; MIMIC does **not** emit it as provider usage |
| `internal/runtime/executor/codex_executor_terminal.go`, retry tests | Account quota vs transient rate limiting, reset units/layout, context/reasoning/continuation/auth errors |
| `internal/runtime/executor/codex_websockets_connection.go`, `codex_websockets_duplex.go`, executor/duplex/spawn-agent tests | WS `response.create` retains `previous_response_id`; standalone create does not inherit one |
| `internal/client/codex/models/models.go`, models/capability tests, `internal/registry/models/codex_client_models.json` | Native client catalog shape, exact-ID metadata, transport/capability filtering |
| `internal/api/server_routes.go` | `/v1/responses`, `/responses`, `/backend-api/codex/responses`, compact and model route intent |

## Executable local policy path

The tracked Codex adapter now imports the separately owned provider runtime.
The base alone does not contain those modules: merge the runtime snapshot first,
or use the approved ignored integration overlay described in
[`codex-validation.md`](codex-validation.md). No foreign runtime files are in
this Codex delta. The current integration uses runtime **v4** plus shared
Responses **v2**. The latest combined run passed **291 tests**:
179 base, 52 Codex, and 60 shared Responses. This is not a release or assembled
ingress claim. All earlier frozen snapshots remain unchanged.

```sh
gleam format --check src test
gleam test
gleam run -m mimic/providers/codex/scenario
state_dir=$(mktemp -d "$PWD/build/codex-local.XXXXXX")
gleam run -m mimic/providers/codex/local -- "$state_dir"
```

The scenario uses in-process mock token/backend endpoint functions and the shared
HTTP/SSE codec. It exercises PKCE exchange, rotation, native request validation,
SSE terminal/usage/reasoning preservation, trusted-history replay, HTTP-receipt
rejection on WS, compact decoding and retry guards. It opens no sockets.

`local` is a second executable scenario: it uses the actual runtime credential
store, fleet and HTTP transport against an actual loopback Mist server. It checks
origin/path, provider account and Authorization headers, validated SSE terminal,
safe A=401/B=200 failover with correct prepared-plan provenance, account-pinned
HTTP full-history replay observed on the wire, compact decoding, invalid
account/status rejection, cancellation, no uncertain-send replay and zero leases.
It does not claim assembled ingress or physical WebSocket conformance.

## Exact coordinator integration hooks

### OAuth and runtime

`oauth.begin_login(config, now_ms)` produces an opaque pending login and
`oauth.authorization_url(login)` supplies the browser URL. Config must contain
explicit HTTPS auth endpoints (loopback HTTP allowed for local tests) and an HTTP
loopback callback. `oauth.published_config()` returns pinned public endpoint
data but performs no network operation.

The callback owner must atomically take/delete a pending login **before** calling
`oauth.exchange_request(config, login, callback_query, now_ms)`, including failed
attempts. This pure adapter cannot enforce concurrent one-time consumption by
itself. State, PKCE, expiration, duplicate fields and config changes are checked.
Do not reuse the generic Claude scope/login options for Codex.

`oauth.refresh_request(config, refresh_token)` returns a form POST plan.
The runtime executes token POSTs with verified TLS, approved origin, bounded
body/time and no redirects; never pass token POST bodies through recorder/corpus.
`oauth.decode_tokens(status, body, previous, now_ms)` returns
`Tokens(auth.Credential, account_id)` or a sanitized domain error. A present
malformed token field fails; an omitted refresh token/account hint retains the
previous value. Rotation must persist atomically **before use**.

Map the account hint to runtime
`OAuthData.private_metadata = [#("chatgpt_account_id", account_id)]`.
`Context.account` is the internal credential/account ID, **not** ChatGPT's ID.
Do not persist `id_token`, email, or plan data. JWT payload decoding only obtains
the routing hint from a trusted token endpoint; it is not signature verification
and must never authenticate a client. A changed account on refresh is rejected.

The runtime owns token storage, one-time callback state, refresh singleflight,
invalid-grant fencing, expiry scheduling, fleet selection and HTTP transport.
API-key OpenAI Chat Completions support does not constitute Codex OAuth.

Runtime-v4 refresh semantics are audited explicitly:

- Unknown transport outcome, arbitrary 5xx, malformed token success, or
  error-looking HTTP 200 maps to `RefreshUnavailable`: retain the durable
  recovery fence, never automatically repeat a possibly rotated grant.
- Only an unambiguous structured HTTP 429 rejection (`rate_limit_exceeded`
  code / `rate_limit_error` type, no contradictory code/type or token fields)
  maps to `RefreshRateLimited`. Missing Retry-After uses the runtime fallback;
  malformed, negative or duplicate values retain the recovery fence. Positive
  delays are not upper-clamped by the adapter.
- `RefreshRetryable` is never inferred from an HTTP number or generic failure.
  The injected trusted transport may supply it only with affirmative no-send
  or non-execution proof.
- Status/metadata reads do not clear recovery. Explicit replacement/relogin
  writes are required. A recovery fence does not assert that a token was revoked.
- Duplicate JSON keys, including escaped-equivalent and nested keys, are
  rejected at the OAuth boundary before parsed data can authorize any action.
  This also covers successful token responses and decoded account claims.
  The bounded lexical guard delegates syntax/value decoding to the existing
  JSON parser and uses per-object dictionaries; it is not another provider codec.

These are synthetic parser/runtime contract tests, not measured live Codex OAuth
responses. Runtime owns durable state, clocks and exact-generation CAS; the
provider has no parallel scheduler or sidecar.

### Request preparation

After ingress authentication and shared Responses request decoding, call:

```text
request.prepare(
  body: ir.Value,
  Context(
    Scope(tenant/client-key-id, internal-credential-id, chatgpt-account-id,
          resolved-model, client-session),
    access-token,
    configured-user-agent,
    Option(runtime-owned-WS-connection-generation)
  ),
  Route(Responses | Compact, Http | Websocket, native-intent),
  Option(session.Continuation),
  model.reasoning_efforts
) -> Result(Prepared, String)
```

`Prepared` contains target, ordered headers, JSON tree, derived identity,
internal `credential_id` and
pending tool-call IDs and kinds. It is ephemeral **secret-bearing** outbound data, not a
corpus artifact. Runtime converts it to a wire request with its configured
origin. No network origin is selected by this module.

Constructed headers replace—not merge—client credential/account/session headers.
Stable session/cache IDs include authenticated tenant, internal credential ID,
ChatGPT account, model and client session, never rotating access-token bytes.
Client `prompt_cache_key` does not override isolation. Caller-provided user agent
is explicit; no native transport fingerprint or measured version is claimed.

Call `routes.resolve(method, path, upgrade, native_hint)` for intent. Authenticate
all aliases identically. Direct backend aliases imply native intent; generic
Responses aliases require the coordinator's native-client detection. Do not route
Chat Completions through this native classifier. WS intent requires an upgrade;
compact is HTTP-only. Model listing must use the authenticated fleet's exact
available model IDs.

### Continuation safety: intentional HTTP/WS difference

CPA ordinary HTTP execute removes `previous_response_id`; its WS path retains
it in a `response.create`. These are not interchangeable.

- WS incremental input requires a matching opaque receipt (identity, previous
  response ID, pending tool IDs **and kinds**, connection generation).
  `session.completed_ws` records a runtime-owned generation that changes on
  socket replacement. HTTP receipts and old-socket receipts cannot authorize
  WS continuation. Cross-tenant/account/model/session, credential failover,
  missing and cancelled receipts fail. Standalone create never inherits an old
  response ID. WS `generate:false` warmup intent is preserved and type-checked;
  HTTP removes `generate` as in the pinned executor.
- HTTP continuation requires matching receipt **and complete retained history**.
  Runtime calls `session.completed` only after validating a provider terminal
  through the shared codec, then `session.retain_history` with complete previous
  input plus actual provider output. The adapter appends new input, checks tool
  pairing and removes the now-unneeded previous ID.
- Incremental-only HTTP requests fail explicitly. A client-supplied Boolean or
  JSON “full history” assertion is never proof. This is intentionally safer than
  CPA's unconditional strip and is not claimed as identical behavior.
- `session.cancel` invalidates the receipt. Runtime must additionally cancel the
  actual HTTP/WS handle and avoid publishing late terminal state after cancellation.
- Runtime owns receipt retention, eviction and synchronization; there is no
  second provider session store here.

### Catalog and errors

`models.decode(payload, provenance)` accepts an explicitly supplied native
catalog and preserves unknown metadata. `models.pinned()` supplies a minimal
pinned subset. `models.available(catalog, enabled_ids, ws_enabled, lite_enabled)`
intersects exact IDs and implementation capability: no implicit available models,
WS preference is masked without WS transport, lite models are excluded without
lite support. This adapter does not claim to implement Responses-lite/code mode.
Use a full operator-supplied catalog when the installed client requires metadata
not included in the pinned subset. Native-client catalog acceptance is unverified.

`errors.classify(status, headers, body, now_ms)` produces sanitized categories.
Quota `resets_at` uses epoch seconds, relative reset and numeric Retry-After use
seconds; public cooldowns are milliseconds. Account quota is distinct from model
capacity and transient rate limiting.
Only explicit non-executing rejections may be retried, and only before client
output/cancellation. 5xx/disconnects are uncertain, not automatic replay permission.
Runtime remains the sole retry/failover scheduler.

Always pass the **original upstream transport status** to classification. An
in-band terminal quota error over a 200 response must not be relabeled 429 before
classification: it may have executed, so even before output it is not safe to
retry. HTTP-date Retry-After parsing reuses the shared quota FFI primitive;
expired dates clamp to zero and malformed/duplicate values yield no parsed delay.

### Runtime bridge

`adapter.http(config, ca_file)` uses `providers/transport.http`; it constructs
Host and byte-accurate Content-Length with the configured runtime origin.
`adapter.prepare` imports the actual runtime contract and rejects non-OAuth,
WS, Responses-lite, unpinned incremental requests and streaming compact.
`adapter.registration(model)` advertises only HTTP buffer/stream, tools and
scoped continuation; compact is a distinct operation.
`adapter.refresh(config, send)` returns the runtime's `Refresh` callback with a
runtime-supplied token transport. `adapter.material(tokens)` builds the minimal
private metadata envelope.

Ordinary `/responses` is upstream SSE even for a buffered client request.
`adapter.prepare_native` and `adapter.capture` expose the preparation boundary
for composition. Associate each prepared plan with its actual runtime account;
safe failover may generate more than one plan. Never consume the oldest plan
without matching `runtime.Response.account`.

`response.consume(opened, prepared)` is buffered-only and uses the runtime pull API, shared HTTP
status/media checks and shared incremental SSE codec, cancels the handle on every
exit, and returns a typed `Terminal`. It rejects a prepared plan from a different
internal credential. `Completed` contains the native response and a scoped HTTP
receipt; `Unsuccessful` retains incomplete/failed/cancelled native documents,
details and reported usage without a receipt; `RemoteError` retains provider
error data, which must be sanitized before diagnostics. Transport/protocol faults
remain sanitized errors. `new`/`feed`/`finish_terminal` support incremental
**buffered** composition; `finish` is a success-only convenience accessor.
The source-compatible shared `feed` is atomic per chunk and is not the
streaming-forward path.

`response.forward(opened, prepared, emit)` delegates to the shared HTTP pump
using `feed_partial`. Each valid prefix is emitted once before handling a later
malformed frame, including both frames arriving in one TCP chunk. No additional
pull occurs before emission. Since runtime has returned upstream headers,
forwarding errors carry `Started` delivery and cannot authorize failover/replay;
upstream, protocol, downstream-failure and cancel cleanup use runtime ownership.
This path returns protocol outcome, not a full-history continuation receipt.
Coordinator streaming receipt retention remains a separate integration hook.

Receipts are created only from events returned by successful shared-codec feed
and exposed only after clean EOF. The complete input plus terminal output is
validated with shared `pair_input` before retaining history; reusing an already
consumed call ID cannot create a receipt that will fail on its next replay.
The former Codex pairing implementation/types were removed in favor of shared
`responses.PendingCall`, `pair_input`, document and compact validation.

For WS message composition, use shared `websocket.create`, provider preparation,
then shared `websocket.encode_create`; use `websocket.receive` for every complete
upstream message. Only its validated completed terminal may seed
`session.completed_ws`. Tests compose these APIs and prove incremental input,
scoped connection receipts and one-shot cancellation. This is not RFC6455
transport or a routed WS service.

For now the shared HTTP transport's header-only rejection hook handles 401/429;
other classified bodies cannot trigger invisible retry after headers commit.
Do not relay arbitrary error bodies or token endpoint bodies to clients.

Runtime v2 adds ownership transfer through `runtime.adopt(stream)`. The
coordinator must call it synchronously from Mist's chunk-process initializer
before the old request owner exits. The Codex-local scenario does not exercise
this assembled-ingress handoff; it remains an explicit integration gate.

## Deliberate limitations and pending gates

- HTTP/SSE/terminal/compact and WS **message** composition are locally tested
  against the exact shared v2 snapshot. Native compact preserves absent output
  and rejects null/non-array output. Physical Codex/runtime WS transport, route assembly,
  live upstream acceptance and full conformance are separate unverified gates.
- Root CLI/login callback server, native route assembly and runtime adapter
  registration require coordinator integration. No live account/provider calls
  are authorized or performed.
- Actual WS transport cancellation/disconnect and account-pinned socket reuse
  require runtime/route integration. No local WS transport is duplicated.
- No device-code login, realtime/audio, steering, Responses-lite/code-mode,
  automatic image-generation tool injection, native TLS/HTTP2 impersonation,
  model catalog polling, local tokenizer endpoint, or unscoped reasoning cache.
- Unknown encrypted reasoning is preserved, not fabricated or re-signed. Invalid
  signatures are classified; silently deleting reasoning and retrying is not used.
- Source-derived catalog/fixtures never establish availability, usage measurements
  or installed native-client conformance. Follow-up integration evidence must be
  recorded separately from the 200-test pure-policy milestone.
- `context_management` is explicitly rejected rather than silently implying
  automatic compaction. Use the separate compact operation. Unsupported `user`
  attribution metadata is removed.
- Conformance lab's mandatory `assembled_ingress` check remains **false**:
  the local runtime scenario does not substitute for a real authenticated request
  through coordinator-assembled ingress. No all-unsupported stub driver has been
  labeled as coverage.
