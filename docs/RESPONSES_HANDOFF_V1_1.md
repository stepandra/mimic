# Responses source-only handoff v1.1

Supersedes v1, including its event-name SSE injection vulnerability.
Base `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`; CPA pin
`acdace936fa7df2905500c7f5e0a97d683138dea`.

Immutable snapshot:
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/bp3dg4b63e1r/mimic/build/responses-contract-v1.1/`.
Its `SHA256SUMS` hashes exact owned bytes relative to `source/`. Consumers may
copy exact source into ignored test overlays, not track/edit foreign namespaces.

## Stable API and dependency compatibility

All v1 document/stream function signatures and exposed types remain unchanged;
see the public API section of `RESPONSES_HANDOFF_V1.md`. Stream semantics are
stricter, not silently transforming invalid events. Native document is still the
source of truth. No shared IR/dialect/build/ingress/provider files changed.
Dependencies remain base IR/types, standard library/JSON/Erlang and gleeunit.

New `mimic/protocol/responses/http`:

```gleam
open_sse(Int, List(types.Header)) -> Result(stream.Stream, String)
run(
  stream.Stream,
  handle,
  fn(handle) -> Result(Option(#(BitArray, handle)), upstream_error),
  fn(handle) -> Nil,
  fn(stream.Event) -> Result(Control, String),
) -> Result(stream.Outcome, Failure(upstream_error))
```

`Control = Continue | Cancel`; `Failure(e) = Upstream(e) | Protocol(String) |
Downstream(String)`. Inject runtime callbacks; no connection opens here. The
current stream owner invokes cleanup on terminal, EOF, codec/upstream failure,
downstream error, and local cancellation. The runtime still provides idempotence
and process-death cleanup. Emission precedes the next pull. Typed errors are not
retry authorization. `open_sse` checks status, Content-Type and encoding before
downstream response commitment; it does not rewrite the ordered headers.

New `mimic/protocol/responses/websocket`:

```gleam
new(Scope, String) -> Result(Session, String)
create(Session, Scope, String, String) -> Result(#(Session, responses.Request), String)
receive(Session, Scope, String, String) -> Result(#(Session, stream.Event), String)
encode_create(responses.Request) -> Result(String, String)
cancel(Session) -> #(Session, Bool)
disconnected(Session) -> Result(Nil, String)
```

`Session` is opaque, per connection; `Scope(tenant, provider, credential, account,
model, client_session)` and generation are trusted server values, not client
frame metadata. `create`/`receive` last argument is complete JSON text. Only one
active response; only validated completed grants same-scope/generation previous
response continuation. Outstanding function/custom results require matching
kind+id. Failed/incomplete/error clear receipt. Local cancel closes the session
and yields a one-shot transport-cleanup command. `disconnected` validates state;
caller must discard/cancel it, not reconnect and reuse it.

This is the WS **JSON message protocol**, not RFC6455 transport. It intentionally
rejects response.append, implicit field inheritance/history merging, background
generation and undocumented response.cancel. `encode_create` removes transport
stream/background:false and preserves native previous_response_id; no store
defaults or provider transforms. Physical WS capability remains false.

## Security/correctness hardening

Eight review-driven regression tests now cover:

- CR/LF/NUL type rejection; defensive encoder cannot inject frames even from a
  directly constructed invalid Event.
- Known nested text/reasoning/tool/content/result structure validation.
- Input-only result items cannot satisfy a server's own output tool call.
- Stable tool name as well as call ID/item ID/type.
- Compatible item/part ownership and contiguous part indexes.
- Stable identities in incomplete terminals, not just completed.
- Supported flat/nested error payload required before RemoteError.
- Every CR/LF framing byte counted, including split CRLF and blank dispatch.

Remaining deliberate limits: no delta/final-content equality check (no content
accumulation), unknown extension semantics are opaque, no generic output
hydration, and all cross-dialect projections explicitly unsupported.

## Reproducible evidence

```sh
mise exec gleam@1.18.1 -- gleam format --check src test
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam run -m responses_scenario
```

Latest full suite: **221 passed**, 42 new tests on the 179-test base. Prior run
had one existing recorder TLS timeout; the unchanged recorder test passed on
rerun. No application compile warnings. Root format check passes.

Standalone scenario opens actual loopback HTTP sockets for success, incomplete,
remote error, early disconnect, local cancel and downstream failure. Server
withholds terminal bytes until the client has decoded and emitted response.created.
Server observes connection close on early terminal/cancellation/failure. Stdout
explicitly reports `synthetic:true`, `real_loopback_http:true`,
`assembled_ingress:false`, and observed event sequences.

WS tests in this snapshot are message/session tests only. No real provider,
account, OAuth, native-client capture, timing measurement or CPA differential
execution was used. Root ingress remains coordinator-owned and unmodified.
No release/full parity claim follows from this snapshot.
