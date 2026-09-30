# Shared protocol/runtime parity wave

## Verified starting point

Source base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, fetched from
`https://github.com/stepandra/mimic.git` and checked against published `main`.
CPA reference pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
Toolchain: `mise exec gleam@1.18.1 -- ...`.
This map describes source contracts, not CPA differential or live-provider proof.

The shared-core writer owns neutral protocol/runtime additions. Provider
normalization stays in provider namespaces. Gateway, root CLI/build files,
`auth.gleam` callback/CLI, differential and client harnesses remain with their
owners. No provider registration follows merely from adding a codec.

## Baseline API map (usable without overlays)

| Module | Existing API and contract |
| --- | --- |
| `mimic/ir` | `Value` retains native unknown JSON fields structurally; `Request`, `Response`, `Turn`, `Content`, `Usage`, `StreamEvent` serve Chat/Anthropic translation. `Content` includes text, function call/result, thinking/signature and `Unknown(Value)`. |
| `mimic/dialect/{openai,anthropic}` | `decode_request`, `encode_request`, `decode_response`, `encode_response`. Native extensions survive; cross-dialect encoders reject unsupported extensions/media rather than silently discard them. This is not a Responses codec. |
| `mimic/dialect/responses` | Native `Request.document` and `Response.document` are authoritative. `request_from_value`, `response_from_value`, compact decoders, `pair_input(request, prior)`, `output_calls(response)` already exist. `PendingCall` distinguishes Function/Custom. Native encrypted reasoning, media and unknown fields need not pass through Chat IR. |
| `mimic/dialect` | Legacy Chat/Anthropic SSE translation: `new_stream`, `feed(Stream, String)`, `finish`. UTF-8 chunks only; native mode passes frames through. Not a bounded byte-stream validator. |
| `mimic/protocol/responses/stream` | Bounded raw-byte SSE: `new_with_limits`, `feed_partial -> Batch(events, next)`, `push(Stream, Value)` for WS messages, `finish -> Outcome`. Emit the valid prefix before inspecting `next`. Completed, Incomplete, Failed, RemoteError and Cancelled are distinct. EOF is not completion. |
| `mimic/protocol/responses/http` | `open_sse(status, headers)` validates before downstream commitment. Pull-driven `run(state, handle, next, cancel, emit)` provides synchronous backpressure and cleanup. |
| `mimic/protocol/responses/frames` | RFC6455 client/server framing, masking, fragmentation, UTF-8 and size checks. `feed_one` preserves a valid event before a later invalid frame. No extension negotiation. |
| `mimic/protocol/responses/websocket` | Pure same-connection lifecycle, `Scope`, `new`, `create`, `receive`, `cancel`. Completed alone grants a pending-tool receipt. No durable HTTP continuation, implicit history merge or cross-connection resume. |
| `mimic/providers/contracts` | `Adapter`: open/next/cancel/rejection. `SessionAdapter`: open/send/receive/cancel. `Request`: provider/auth/model/protocol/operation/mode/capabilities/session/pinned account/body. `Context`: approved origin/account/session key/credential. |
| `mimic/providers/runtime` | `start`, `open`, `next`, `cancel`, `adopt`, `execute`; `open_session`, `session_send`, `session_poll`, `session_adopt`, `session_cancel`. Runtime owns credential workers, leases, process/socket lifecycle and retry fences. Session receive `None` means idle, not EOF. |
| `mimic/providers/{transport,ws_transport}` | Existing HTTP text, explicit binary HTTP, and physical WS adapters. Verified TLS is not a TLS fingerprint or production provider qualification. |
| `mimic/auth/{runtime,runtime_store,storage}` | One refresh worker per provider/auth/account key under one private-store owner; exact-generation CAS fences, admin replacement/deletion wins, private metadata rotates atomically. API keys and permanent `SessionToken` are not expiring OAuth grants. |
| `mimic/{fleet,quota}` | Scoped account selection, sticky sessions, concurrency slots, persisted cooldowns. Only configured accounts/models; no upstream discovery. |

### Important distinctions

- `types.Capture`/`WireResponse` are UTF-8 JSON/SSE wire artifacts with ordered,
  case-preserving duplicate headers. They are not binary request containers.
- `contracts.HttpRequest.body` is `BitArray`, may contain secrets, and must never
  enter captures/logs/diagnostics. Connect envelopes/protobuf/EOS stay provider
  owned. HTTP/2 is representable but rejected before I/O.
- `Failure(reason, delivery, retry_after_ms)` never contains provider body,
  token, URL or exception text. Unknown send/result is `Uncertain`; returned
  headers/output means `Started`. Neither permits transparent replay.
- Opaque stream/session handles require synchronous `adopt` from the new owner
  before the old owner exits. Old owners cannot pull/send/cancel after transfer.
- Native structural JSON retention does not mean original object ordering,
  whitespace or numeric spelling. Baseline `ir.parse` uses a dictionary decoder
  and does **not** reject duplicate keys. Provider-local raw JSON guards exist;
  callers must not assume those guards protect every shared protocol entry point.

## Gaps and bounded next slices

1. Native Chat needs byte-safe bounded SSE validation/restoration and the same
   valid-prefix-before-error semantics as Responses. Reuse shared framing;
   preserve unknown native fields. A native path does not imply safe Responses
   or Anthropic projection.
2. HTTP continuation needs an explicitly owned, trusted, bounded scope and
   lifecycle. Scope must separate tenant/provider/auth/account/generation/model/
   origin; only validated successful terminals can grant receipts. Full native
   history and pending custom/function pairing must remain intact. No token
   hashing or new credential manager in a provider adapter.
3. Operation-specific endpoints must be operator registrations associated with
   the same credential worker, not duplicate account workers or request-provided
   origins. Existing runtime account origin is singular.
4. Binary H1 currently permits numeric loopback fixtures only. Remote binary
   HTTPS requires an explicit experimental opt-in contract and tests; removing
   the restriction is not qualification. No H2 dependency without integration
   owner approval. CPA source inspection is not transport qualification.
5. Cross-dialect reasoning/signatures/media/custom tools are not universally
   representable. Fail closed until a specific reversible projection is defined.
   No unknown extension or tool result may silently disappear.

## Snapshot 1: unambiguous native JSON

`ir.parse` keeps its signature and now rejects duplicate decoded keys, including
escaped equivalents and nested duplicates, before dictionary conversion.
`parse_bounded(source, max_bytes, max_depth, max_values)` is additive. Default
limits are 16 MiB, 128 containers deep and 1,048,576 values. Boundary callers can
choose lower limits. Errors remain the legacy secret-free `"invalid JSON"`.
The structural scanner is adapted from the existing Claude guard, not a second
JSON syntax decoder; the standard library still validates syntax and literals.
Provider-local guards may remain unchanged; no adapter ABI changes are needed.

Compatibility: ambiguous JSON that previously selected a map winner now fails
closed. Native unknown fields, encrypted content, reasoning and media still
round-trip structurally. Constructed `Value` objects are trusted in-memory values,
not proof that raw input passed this boundary.

## Snapshot 2: native Chat and caller-owned Responses fold

- `protocol/sse` extracts the existing Responses byte framing. `feed_one` returns
  at most one frame plus untouched remaining bytes. Responses now uses this same
  scanner; its public types and feed/push/finish APIs are unchanged.
- `protocol/chat/stream.new`, `new_with_limits(frame_bytes, choices, tools)`,
  `feed_partial(state, bytes, restore) -> Batch(events, next)`, `finish`,
  `outcome`, `encode_event` are additive. `restore` has type
  `fn(ir.Value) -> Result(ir.Value, String)`; pass `Ok` for identity. Provider
  restoration precedes validation. Events are `Event(document)`,
  `ErrorEvent(document)` and `Done`; outcomes are Completed, Incomplete,
  RemoteError and Cancelled.
- Native Chat preserves reasoning_content, media/vendor extensions, detailed
  usage and raw tool argument fragments. It tracks response/model identity,
  choice finish state and tool index/id/name. It does not accumulate or claim
  to validate a reconstructed full tool-argument JSON string. Unknown custom
  tool types and finish reasons fail explicitly. There is no cross-dialect
  projection. Native known text fields must be strings or null.
- Chat limits default to 1 MiB/frame, 128 choices and 4096 tools total;
  identity/name metadata is limited to 1024 bytes each. `[DONE]` requires all
  observed choices finished; length/content_filter yield Incomplete, not success.
  EOF alone never completes. Emit `Batch.events` before checking `Batch.next`.
- `protocol/chat/http.open_sse(status, headers)` reuses the existing HTTP media
  gate; `run(state, handle, next, cancel, restore, emit)` uses Responses HTTP
  `Control`/`Failure` types, synchronous backpressure and one cleanup call.
- `protocol/responses/http.run_fold(state, handle, next, cancel, initial, emit)`
  returns `Result(#(Outcome, accumulator), Failure(error))`, with
  `emit: fn(accumulator, Event) -> Result(#(accumulator, Control), String)`.
  Unlike legacy `run`, it waits for clean transport EOF after the terminal.
  A later protocol/I/O/downstream failure returns no accumulator; local Cancel
  returns Cancelled. Providers must grant receipts only for Completed and must
  bound the accumulator. This is not a cache or provider continuation policy.
- Existing `run` still ends at a validated protocol terminal. Both paths use one
  pump; legacy callback and adapter ABIs remain unchanged.

## Snapshot 3: approved endpoints and generation-scoped receipt storage

### Runtime hooks

`runtime.start_with_bindings(store, registry, accounts, bindings)` is additive.
Each `EndpointBinding(provider, auth_mode, account, protocol, operation, origin,
egress)` is operator configuration. An account with any bindings uses an exclusive
protocol/operation allowlist. Duplicate bindings, unknown accounts/operations,
userinfo, paths, query/fragment and invalid ports fail before runtime ownership
or network I/O. No request-controlled origin is accepted. Every binding shares
the account's one credential worker, fleet concurrency allocation and quota key.
The selected `Context.origin` changes; no provider should preplan from the first
configured account. `runtime.start` retains its original behavior.

`auth/runtime.acquire_versioned(worker)` returns
`Result(#(AuthMaterial, runtime_store.Revision), Failure)`. `Revision` remains
opaque and private. Acquisition validates material and exact revision against
the current durable record; a concurrent replacement fails closed.

`runtime.open_scoped(runtime, adapter, open_callback, request)` replaces only the
open callback:

```gleam
fn(Context, runtime_store.Revision, Request)
  -> Result(Opened(handle), Failure)
```

The existing adapter supplies next/cancel/rejection unchanged. The callback runs
inside the runtime-selected execution process. Existing `open`, `Account`,
`Context`, `Adapter` and `SessionAdapter` constructors keep their ABI. WS sends
now compare exact revisions, so a same-token admin save invalidates the old
connection just like replacement, deletion or refresh. A failed send remains
Started and is never replayed.

### Continuation cache ownership and API

Agreed with the Codex owner: shared core owns a generic, nonpersistent bounded
cache; integration owns its instance, supervision/shutdown and authenticated
tenant/client scope; providers own native receipt/history/pending-call policy.
No provider-specific scheduler, token digest, durable context store or duplicate
credential manager is introduced.

`protocol/continuation` exposes:

- `scope(tenant, context, revision, request) -> Result(Scope, String)`, called
  inside `open_scoped`. Tenant and `request.session` must come from trusted
  integration state, not an unverified inbound assertion. Scope includes tenant,
  provider, auth mode, account, opaque generation, model, origin, client session,
  protocol and operation. It does not retain Context credentials or request body.
- `start(Limits(entries, total_bytes, entry_bytes, ttl_ms)) -> Result(Cache(a), String)`.
  Limits cap entries at 4096, total retained external representation at 64 MiB,
  and TTL at one day. Integration chooses smaller budgets; TTL is monotonic,
  not a request timestamp. A clock rollback/overflow/failure clears and latches
  the cache until restart.
- `put(cache, scope, id, value)`, `get(cache, scope, id)`, `remove`,
  `clear_scope`, `stop`. Values are generic opaque provider receipts. Actual
  Erlang external size of scope/id/value determines byte admission, not an
  adapter-declared weight; this is not a claim of exact BEAM heap accounting.
  Admission is serialized and rejects duplicate IDs within a scope or capacity
  overflow; it never silently overwrites or evicts a live receipt. Expired data
  is swept on access. Byte checks occur before enqueueing values.

The cache does not infer that a value proves successful completion. Use
`run_fold` to validate terminal plus EOF, then the provider's receipt constructor,
then `put`. Reconstruct the current scope using the current runtime revision on
every new execution. Never reuse an old scope after reauthorization or admin
mutation. Do not store credentials or log/cache-export scopes, values or native
history. Cache errors never include them. A timeout is not proof that a cache
mutation did not occur and never authorizes provider replay.

`remove`/`clear_scope` remove current entries; they are not permanent tombstones
for future puts. The integration owner must fence in-flight receipt publication
on cancellation/shutdown. Stopping/restarting the instance loses all receipts
and fails closed. This API is not yet wired into the gateway in this worktree.

### Remaining provider/integration blockers

- Kimi Messages restoration needs an owner-published Claude hook; no provider
  namespace was edited or parallel Messages parser introduced here.
- Codex native-lite sparse terminal policy is not enabled. Strict existing
  Responses terminal completeness remains the default; no output hydration or
  silent global weakening was added.
- Generic Responses/Chat/Anthropic cross-projection and Devin client event
  encoding remain limited to existing explicitly supported representations.
  Unsupported encrypted reasoning/media/custom tools fail rather than disappear.
- Remote binary H1 experimental opt-in, H2 and live TLS/provider qualification
  remain absent. Existing loopback binary HTTP/TLS/WS regressions continue to run.
- Integration still owns endpoint configuration, cache lifecycle, trusted tenant
  construction, sender adoption, callbacks/enrollment and route registration.

## Snapshot 4: preselection and reviewed fidelity fixes

Integration identified that account pinning must precede selection, but full
cache scope requires the selected account/revision. The additive
`continuation.locate(cache, tenant, request, receipt_id) -> Result(String, String)`
queries the **same** cache and returns only the unique stored account matching
tenant/provider/auth/model/protocol/operation/client-session/receipt ID.
Missing, expired or distinct-account-ambiguous matches fail. An already pinned
request is rejected. Multiple generations/origins of the same account may
locate it; this is only a selection hint, not authorization or history.

Required integration order:

1. Authenticate and establish a stable, explicit tenant/client session.
2. Locate the previous receipt's account; set the server-controlled pin.
3. Open through `open_scoped`; construct full scope from selected Context and
   current Revision; require `get` success **before** the provider sends bytes.
4. Grant a new provider receipt only after validated completion and clean EOF.

A per-request random session does not enable continuation. No second receipt
registry, caller-chosen pinned account, stale generation fallback, cross-origin
fallback or implicit fresh-account retry is introduced.

Independent read-only review found two native Chat fidelity defects in snapshot
3. Both are fixed with regressions: error.message uses the frame budget instead
of the metadata identity budget; named `event: error` retains its SSE dispatch
semantics. `NamedErrorEvent(document)` is added alongside the existing Event,
ErrorEvent and Done constructors. Consumers with exhaustive matches on this
new-wave enum must add the case; `encode_event` handles it. Existing baseline
adapter/runtime constructors are unaffected.

Review found no other confirmed defects. Follow-up tests now cover real TLS
terminal-then-invalid-HTTP framing with no accumulator and zero leases/socket
cleanup, cross-binding concurrency saturation and cooldown, and runtime-selected
cache miss after same-token admin replacement. The new locate path has isolation,
ambiguity, stale-generation, pin and expiry regressions. These are local synthetic
tests, not proof of assembled gateway continuation or live-provider behavior.

## Evidence

Untouched-base full `scripts/verify-integration.sh` exited 0: 522 Gleam tests,
10 Python tests and all library/source/shipment integration scenarios passed.
The first invocation timed out; the successful rerun used
`ERL_FLAGS="+S 2:2 +A 2"` to reduce parallel host contention.
Snapshot 1 compiled with Gleam 1.18.1. Focused EUnit execution of the compiled
`ir_boundary_test`, `responses_protocol_test`, `responses_http_test`: 44 passed,
including real bounded loopback HTTP and all byte-split Responses cases.
Snapshot 2 adds `chat_protocol_test` and `responses_fold_test`: 53 focused tests
passed in total, including every Chat byte split, one-byte UTF-8 fragments,
valid-prefix-before-error, terminal classification, tool identity, restoration,
bounds, exactly-once cleanup and receipt-fold failure paths.
Runtime focused regression: 55 tests passed across endpoint binding, refresh v4,
binary v3, WS runtime and physical WS transport. After adding cache tests and
same-token WS invalidation, the 17-test cache/binding/WS-runtime set passed.
Snapshot 3 full `scripts/verify-integration.sh` exited 0: 543 Gleam tests,
10 Python tests and all scenarios plus source/shipment smokes passed. A synthetic
HTTP fixture logged BrokenPipe during a client disconnect; the smoke assertions
and script still passed. The exact log is retained, not cleaned up.
Snapshot 4 compiled and its 20-test Chat/cache/runtime-binding set passed,
including the review fixes and additional real TLS boundary checks. Its exact
full integration rerun is pending at this source checkpoint; final evidence is
published separately rather than overwriting prior immutable snapshots.
No provider calls, accounts, user-environment credentials or live validation
were used. CI green is published baseline provenance, not a new CI run.
