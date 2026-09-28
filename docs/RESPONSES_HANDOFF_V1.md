# Responses source-only handoff v1

Superseded by `RESPONSES_HANDOFF_V1_1.md`. The original immutable v1 snapshot
contains review-confirmed validation defects, including event-name SSE injection.
Use the hardened snapshot for any further integration.

**Partial codec milestone, not CPA or route parity.** Baseline
`c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`; CPA pin
`acdace936fa7df2905500c7f5e0a97d683138dea`.

## Frozen source

Snapshot root:
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/bp3dg4b63e1r/mimic/build/responses-contract-v1/`.
`source/` contains these owned files; `SHA256SUMS` hashes their exact bytes:

- `src/mimic/dialect/responses.gleam`
- `src/mimic/protocol/responses/stream.gleam`
- `src/mimic_responses_bytes_ffi.erl`
- `test/responses_protocol_test.gleam`
- `docs/RESPONSES_PROTOCOL.md`
- `docs/RESPONSES_HANDOFF_V1.md`

Consumers may copy these exact bytes into **ignored test overlays only**.
Do not edit or track another owner's namespace. Coordinator integration is separate.
Dependencies: unchanged base `mimic/ir`, Gleam stdlib, existing `gleam_json`;
test dependency `gleeunit`. No build-file/dependency changes, provider code,
credentials, URLs or provider FFI are needed. Erlang FFI only splits raw bytes at
CR/LF; all protocol logic is Gleam.

## Public composition API

Import `mimic/dialect/responses`:

```gleam
decode_request(String) -> Result(Request, String)
request_from_value(ir.Value) -> Result(Request, String)
encode_request(Request) -> String
decode_compact_request(String) -> Result(Request, String)
decode_response(String) -> Result(Response, String)
response_from_value(ir.Value) -> Result(Response, String)
encode_response(Response) -> String
decode_compact_response(String) -> Result(CompactResponse, String)
encode_compact_response(CompactResponse) -> String
pair_input(Request, List(PendingCall)) -> Result(List(PendingCall), String)
output_calls(Response) -> Result(List(PendingCall), String)
capabilities() -> Capabilities
```

`Request(document: ir.Value, model: String, stream: Bool,
previous_response_id: Option(String))`.
`Response(document: ir.Value, id: String, status: Status,
output: List(ir.Value), usage: Option(ir.Usage))`.
`CompactResponse(document: ir.Value, id: String, output: List(ir.Value),
usage: Option(ir.Usage))`.
`Status`: `Queued | InProgress | Completed | Incomplete | Failed | Cancelled`.
`PendingCall(id: String, kind: ToolKind)`, `ToolKind`: `Function | Custom`.

Native document is authoritative; revalidate after provider transforms.
`pair_input` takes already scoped, trusted prior calls, not a client-provided
list. Decode alone does not resolve previous_response_id. No generic HTTP
stripping, replay or WS history inference is performed.

Import `mimic/protocol/responses/stream`:

```gleam
new() -> Stream
new_with_limits(Int, Int, Int) -> Stream // frame bytes, items, parts per item
feed(Stream, BitArray) -> Result(#(Stream, List(Event)), String)
push(Stream, ir.Value) -> Result(#(Stream, Event), String)
finish(Stream) -> Result(Outcome, String)
cancel(Stream) -> Stream
outcome(Stream) -> Option(Outcome)
terminal_response(Event) -> Result(responses.Response, String)
encode_event(Event) -> String
```

`Stream` is opaque. `Event(name: String, document: ir.Value)` retains the native
event. `Outcome`: `Completed | Incomplete | Failed | RemoteError | Cancelled`.
Create receipts only from terminal events **returned by a successful feed/push**,
not by constructing an Event and calling its stateless terminal accessor.
Only validated `Completed` establishes a successful continuation receipt.

Feed is atomic per input chunk; failure makes that operation unusable and requires
transport cancellation, not replay. Default bounds: 1 MiB per frame, 4096 output
items, 4096 parts per item. Transport owns chunk sizing/backpressure. State does
not retain deltas or terminal output documents. Caller receives each complete
event without waiting for EOF. `finish` rejects truncation and missing terminal.
Comments/SSE id/retry are not model events; automatic replay/reconnection is not
supported. `[DONE]` is accepted only after a protocol terminal, never as completion.

## Evidence

- `mise exec gleam@1.18.1 -- gleam test`: **199 passed**, including 20 new synthetic
  tests. No new source warnings; cold build has existing dependency deprecations.
- Owned Gleam files formatted with `gleam format`.
- Every possible two-chunk byte split of a synthetic text/tool-envelope stream;
  one-byte UTF-8/CRLF/CR/BOM/multiline input; frame bounds and invalid UTF-8.
- Item/order/id checks, duplicate events, tool call kind pairing, usage and opaque
  reasoning preservation; completed/incomplete/failed/error vs cancellation;
  early EOF, post-terminal rejection, independent stream state.

## Explicit limitations / remaining gates

- No root registration or HTTP route changes. No assembled-ingress evidence.
- No physical HTTP integration scenario yet in v1; tests above are pure codec.
- No WS message session wrapper or physical WS transport in this snapshot.
  `push` is an event validator, not a websocket implementation.
- Cross-dialect conversion deliberately returns Error for all inputs.
- Native validation covers structural envelope and common item lifecycle; unknown
  item/event extensions are forwarded and are not claimed semantically validated.
- This does not validate content equality between deltas and final snapshots;
  it validates identity/lifecycle without buffering all generated content.
- Completed output must contain the streamed items with stable ids; sparse
  provider terminals requiring output hydration are rejected, not silently
  reconstructed. Provider-specific hydration is outside this common layer.
- Usage values preserved/validated are not measured upstream usage.
- No live calls, no executable CPA differential run, no real provider/account
  coverage, no benchmark, and no full CPA parity claim.
