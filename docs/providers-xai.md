# xAI native Responses integration (bounded)

The frozen xAI17 handoff was imported from
`build/xai-handoff-v1/source` in the owner workspace. Its manifest SHA-256 is
`9169c42de7768eb2256e6cf7c772e749bbbe36e425e0c4cd2f97ea743b74369a`;
all listed files matched before integration edits. The original source was
based on a pre-codec runtime contract. This page describes the **assembled
runtime v4 / Responses v2** boundary, not a measured upstream fingerprint.

## Gateway/runtime hook

The gateway owns catalog parsing, account registration, inbound routes and
downstream SSE writing. It should register explicit account entries with
`provider="xai"`, `auth_mode="api_key"`, an operator-approved `origin`
(`https://api.x.ai` by default), explicit `models`, and `StaticKey` policy.
Save API-key material under `credentials.key("xai", "api_key", id)` using the
runtime credential store. Never capture a key in the adapter factory or select
an origin from an inbound request.

For each explicitly enabled model, call `models.registration(id)`; this
advertises only native `responses` and `responses/compact` HTTP with
`Buffer`/`Stream`. The reference model list is not proof of entitlement.
Build-only and composer models are excluded from this API-key registration.

Use `adapter.http(config, ca_file)` with
`endpoint.Config(endpoint.ApiKey, True, False, Some(origin <> "/v1"),
None, None, endpoint.VerifiedTls)` for configured HTTPS origins.
For **synthetic loopback only**, use `endpoint.LocalMock` and a literal
`http://127.0.0.1:<port>` origin. Runtime v4 selects the account and injects
`Context.credential`; `bridge.prepare` checks origin, auth mode, model,
operation and body before transport. It never logs or persists the secret
capture. Gateway must not raw-proxy xAI response bytes:

- `adapter.collect(runtime_response, "responses")` validates SSE with the
  shared Responses stream codec, extracts the terminal Response document
  (including output/usage), validates EOF, and returns JSON. Buffered requests
  still use SSE *upstream*.
- `adapter.collect(runtime_response, "responses/compact")` bounds and validates
  the native compact JSON response. Compact is buffered only.
- `adapter.run(runtime_response, emit)` validates SSE and emits valid native
  events in order. `emit` should use `stream.encode_event` for downstream bytes
  and return `responses_http.Continue` or `Cancel`. A valid prefix survives a
  later malformed frame even in the same TCP chunk. After downstream output,
  protocol errors/cancellation cannot trigger retry/failover.

`bridge.prepare` rejects cross-dialect Chat payloads, physical WebSocket,
continuation (`previous_response_id`), tool declarations/choices (restoration
is not bound to the selected response stream), media, and fields the frozen
transform would silently drop. The direct `request`/`tools` modules retain
their source-inspection policy helpers, but those are not advertised runtime
capabilities. The endpoint planner can describe WS/proxy modes; this does not
mean a physical WS transport exists. Unsupported paths must remain explicit.

## OAuth device and refresh boundary

`oauth.discover`, `start`, `poll` and `refresh_outcome` use injected send/time;
the runtime still owns persistence, singleflight, account activation and
cooldown. Discovery/stored refresh endpoints are revalidated against the
configured TLS or loopback policy. OAuth material stores only the approved
token endpoint as private metadata, not inferred JWT identity. Duplicate
endpoint metadata fails closed.

Every OAuth JSON response passes the bounded `xai/json_guard` before status
classification or field selection. This rejects duplicate object keys at any
depth, including escaped-equivalent keys, so parser first/last-wins behavior
cannot select stale tokens or contradictory errors. Refresh maps an
unambiguous `429 {"error":"rate_limit_exceeded"}` to
`RefreshRateLimited(milliseconds)`; a valid positive `Retry-After` is
preserved. Bare 429, contradictory token fields, malformed success, unknown
transport outcome and duplicate JSON map to `RefreshUnavailable` (not
`RefreshRetryable`). Invalid grant requires an unambiguous recognized 400.
Device code/token values never appear in public error strings. The OAuth
route is **not** advertised by the API-key-only gateway catalog until the
gateway deliberately configures its account policy and persistence workflow.

## Evidence and limits

Imported synthetic tests cover endpoint/model policy, request transforms,
actual loopback HTTP and runtime cancellation/failover. New
`xai_oauth_guard_test` covers duplicate/escaped/nested keys and runtime v4
refresh classification; `xai_adapter_test` exercises loopback runtime bytes,
credential-scoped auth, terminal usage and valid-prefix-before-error through
the common codec. These tests are not live xAI validation or assembled ingress
route evidence. The gateway worker owns route tests.

At this handoff, `gleam test` in the isolated xAI clone was blocked by
`src/mimic.gleam` importing gateway before that worker's source landed.
Subsequent terminal materialization returned “the requested worktree version
was not materialized because the checkout kept changing”; no compile/test pass
is claimed for this integration. Parent must run `gleam format` and
`gleam test` on the assembled tree. No live endpoints, real credentials,
deployments or benchmark measurements were used.
