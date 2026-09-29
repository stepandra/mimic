# Codex HTTP continuation and Responses-lite

## Status and dependencies

Base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, verified against
`https://github.com/stepandra/mimic.git` before creating a clean jj change.
CPA reference: `acdace936fa7df2905500c7f5e0a97d683138dea`.

The gateway-facing `mimic/providers/codex/http` module requires **shared-core
snapshot 4**, archive SHA256
`f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc`.
It uses the actual compiled `runtime.open_scoped`, `protocol/continuation` and
Responses `http.run_fold` APIs. This provider delta contains **no shared files**.
Validation assembly lives under ignored `build/codex-http-assembled`; it is an
exact base source export plus hash-verified shared snapshot plus this owner delta.
The provider working tree alone intentionally does not substitute nonexistent
base APIs or create parallel stores/codecs.

Ingress registration is the integration owner's work. Account preselection uses
the shared cache's metadata-only `locate`; authoritative selected-scope lookup
still follows it before any network I/O. Stable authenticated client-session
policy remains an integration requirement. Sparse native terminal support remains
a shared-codec gap.

## Three different behaviors

| Path | Pinned CPA behavior | MIMIC behavior |
| --- | --- | --- |
| Ordinary HTTP Responses | `codex_executor_execute.go` and `codex_executor_stream.go` delete `previous_response_id` before sending | Missing/incompatible server receipts fail before sending. Valid receipts replay **all** previous input plus completed output before deleting the id. This safety difference is not identical parity. |
| Native WebSocket | Keeps `previous_response_id` on the same credential-scoped physical socket | Existing same-generation WS implementation retained. HTTP rejects WS receipts even if someone attaches history. No reconnect or HTTP fallback is added. |
| Responses-lite | Normal `/responses` route, selected by native header or metadata marker | Same upstream route, explicit lite mode/header, native tool declarations preserved, parallel calls false. Compact remains separate. |

Pinned `use_responses_lite` is model/client metadata, not a separate endpoint or
evidence of account availability. Explicit normal requests remain normal even on
models advertising this flag. Catalog capabilities remain source-derived.

## Gateway contract

1. Integration owns one private `continuation.Cache(session.Continuation)`,
   initialized with explicit count/total-byte/entry-byte/TTL limits. A reasonable
   initial configuration is `Limits(32, 8_388_608, 2_097_152, 900_000)`.
2. Authenticate tenant and namespace a stable client identifier into
   `contracts.Request.session`. A session header is an identifier, not authority.
   `routes.client_session_hint(headers)` accepts agreeing `thread-id`/
   `x-client-request-id` identifiers and rejects duplicates/conflicts. Never use
   a body flag/history declaration as proof. Missing/ambiguous lookup fails closed.
3. `routes.resolve_http(method,path,native,headers)` validates the allowlisted
   lite header and returns `Lite` intent. Pass internal operation
   `"responses/lite"`; it is **not** a public URL. Body metadata is also recognized.
4. `codex/http.open(runtime,cache,config,ca_file,request)` rebuilds the scope
   **inside the selected-account callback**, using the authoritative runtime
   `Revision`. Scope binds tenant/provider/auth/account/generation/model/origin/
   client/protocol/operation. It ignores `config.continuation`; only cache lookup
   supplies history. `locate` supplies `pinned_account` from this same cache
   before account selection; a contradictory caller-supplied pin is rejected.
5. `http.account(opened)` exposes the successful account for server bookkeeping.
   `http.adopt(opened)` transfers stream ownership before a different process
   consumes it. `consume` returns the preserved terminal; `forward` emits shared
   validated events synchronously and returns the terminal after clean EOF.
   `cancel` is idempotent through the runtime.
6. Only completed, paired, bounded history is published. Failed/incomplete/
   cancelled/error responses, bad framing, disconnects, trailing malformed data
   and downstream cancellation never create successful receipts. Cache capacity
   or duplicate-id refusal is a `Persistence/Started` failure, never a retry.

The older `adapter.http_planned`/`prepare_native` and `response.observe`/
`finish_observed` are trusted library primitives, not an ingress authorization
path. Do not wire client history directly to `adapter.Config.continuation`.

### Lifetime

State is **explicitly nonpersistent**. A fresh cache/VM has no receipts; restart
requires the client to send a complete standalone history, not an incremental id.
Credential rotation, same-value reenrollment and revocation invalidate lookup
through runtime-issued revisions; no token-derived generation hash is used.
No credential values are in cache values. Scope and native histories must never
be logged or captured. The shared cache bounds actual Erlang serialized size.
Provider history additionally caps JSON at 1 MiB, 4096 items and 15 minutes.
HTTP input item references are rejected: an opaque id is not complete replayable
history. Self-contained encrypted compaction/reasoning items remain supported.

Integration must cancel/drain in-flight publishers before clearing a live scope:
shared `clear_scope` is removal, not a tombstone. Whole-cache shutdown fences
subsequent publication. Old credential-generation entries are inaccessible and
expire, even if an already-started response finishes after reenrollment.

## Lite policy and limitations

- Header `X-OpenAI-Internal-Codex-Responses-Lite: true` or
  `client_metadata.ws_request_header_x_openai_internal_codex_responses_lite`
  boolean/string true selects lite. Duplicate/malformed markers fail explicitly.
  This is stricter than CPA's permissive false fallback.
- `parallel_tool_calls` becomes false, including when tools are absent.
- Native `additional_tools` stays in input; function/custom/namespace schemas
  reuse shared validation. Tool results remain kind- and call-id-paired.
- No automatic image-generation tool injection. Explicit image-generation tools
  are unsupported here (not a claim that CPA rejects them).
- Source-declared image inputs are preserved; audio/file input is rejected.
  The Images capability means image input, not generated image output.
- Opaque encrypted reasoning is retained without fabricating signatures.
  Exact catalog reasoning efforts are checked. Provider usage/extensions are
  preserved; no local token estimate is passed off as upstream usage.
- Ordinary full terminal Responses documents use the existing shared codec.
  No provider-owned sparse hydration or append codec was added.
- Native WS lite support is not added by this HTTP slice.

### Native client thread identity (source evidence only)

QA traced Codex `0.158.0`, commit
`064c6b8c737f5b41d171fdda80bd9ef10ad06eb3`: `codex-api/src/requests/headers.rs`
and `endpoint/responses.rs` emit `thread-id` and `x-client-request-id` from the
same thread id. `core/src/session/session.rs` retains it across turns/resume.
`session-id` may instead be shared by subagents or overridden for cache affinity;
`x-codex-turn-state` is turn-local. Neither is used as the continuation identity.
These are source-backed expectations, not captured client executions.

### Observed native sparse gap

The actual pinned CPA test `TestCodexNativeStreamFidelity` was run locally for
Codex/OpenAI-Response × HTTP × header/metadata × buffering on/off (8 leaves).
Its synthetic upstream sends `output_item.done` without a created/added sequence,
then `response.completed` with `output:[]` and no `object` field. CPA preserves
the sparse native terminal. MIMIC's strict shared codec rejects that sequence;
**full native-lite parity is not claimed**. Compatibility-mode CPA backfill is a
different policy and must not be silently applied to native lite.

`test/codex_http_fixtures/cpa-lite-native-terminal.json` records selected actual
local CPA test output; it is not a live capture and contains no account material.
The full differential harness and native-client qualification belong to lab/QA.

## Evidence

- Untouched exact base: 522 Gleam tests passed locally.
- Provider-only pre-S3 stage: 534 Gleam + 10 Python tests, full
  `scripts/verify-integration.sh`, source and shipment scenarios passed.
- S3 assembly focused run: 39 tests passed, including actual three-turn HTTP
  replay, simultaneous tenants using the same response id, buffered-to-streaming
  continuation, same-value credential replacement, missing/cross-scope/expired
  receipts, cache restart, trailing corruption, remote failure and cancellation.
- S4 assembly full gate: 567 Gleam + 10 Python tests passed, including all
  `scripts/verify-integration.sh` runtime, source and Erlang-shipment smokes.
  This assembly adds only the hash-verified shared S4 snapshot to the exact base
  and the Codex owner delta; it is not the final all-provider gateway integration.
- Actual pinned CPA: 8 lite normalization tests plus 8 native HTTP fidelity
  leaves passed locally using synthetic loopback endpoints.
- No live provider calls, account discovery, TLS fingerprints or full parity
  claims. Final assembled full-gate results are recorded in the snapshot handoff.
