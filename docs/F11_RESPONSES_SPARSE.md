# F11: source-qualified sparse Responses observations

Implemented against MIMIC `dd15c610ec39e4f296c30fe02347d0d2b368a629`.
This is the shared codec deliverable, not F12/F13 route, shipment, native-client,
CPA differential, WSS, or live qualification. No root/provider/auth/runtime/
config/CLI/vendor files were changed. No commit, JJ mutation, or publication.

## Why the withdrawn packet was not imported

The exact umbrella transcript
`ksQQVCxI78U2RVSszbHl9CfSlZLOAFQ9t5IBxBDu1fs15rdKs6m5jRdeJnRz`
and commit `3190bc60381d39f03dac1ebda92cf7ca47676b26` were inspected read-only.
Historical commands were treated as data; none of its ref mutations were run.

1. The old `Reconstruct` policy required created/added lifecycle events and
   rejected the pinned native metadata + item.done + completed `output:[]`
   sequence. It closed **zero** of the 48 direct executor fixture combinations,
   including the 16 native-lite combinations. Synthetic omission tests were not
   evidence of the requested native contract.
2. Review found initial reasoning.summary could disappear when item.done
   omitted its item. Initial observations must not be silently erased or
   promoted to final snapshots.
3. The subsequent proposal also needed correction: the fixture's HTTP/WS axis
   is **upstream executor transport**, not downstream gateway transport. Native
   executor byte preservation does not imply public `/v1/responses` preservation.

The successor uses the existing JSON and SSE decoders, a bounded sparse observer,
and an opaque wire envelope. It does not import the old synthetic reconstruction
branches. Strict lifecycle code and S6 raw-tool checks remain unchanged.

## Pinned source scope

Reference: `router-for-me/CLIProxyAPI`
`acdace936fa7df2905500c7f5e0a97d683138dea`. Public source was fetched read-only;
the running CPA service, credentials, accounts, and native binaries were not used.

| File | Full-file SHA-256 |
| --- | --- |
| `internal/runtime/executor/codex_native_fidelity_test.go` | `5599b79aa51038c4b5f53054124510b9a31de9aedd01f144a9fcf5fe138288cc` |
| `internal/runtime/executor/codex_executor_stream.go` | `94cde12304dc85f056ce2bdae316e7c2f82a88900c31bb48419274bc51e4e6c2` |
| `internal/runtime/executor/codex_executor_execute.go` | `44c07b9ea934c917fe48e7448109682559c8aacb397c4ae9740583404ed2ef2d` |
| `sdk/api/handlers/openai/openai_responses_handlers.go` | `44425e6550b54e39a5305441be7037bd32d78126926b2a317bca6a9aca86144d` |
| `internal/runtime/executor/codex_websockets_duplex_test.go` | `2ef80ec24e16109eb8fbc48beeeaca1e3bbec52e1a628a039e050da119427cda` |

Source URLs all use that exact commit:

- [Executor fixture: events, transport, selectors, expected terminal](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_native_fidelity_test.go#L19-L137).
  48 combinations: four source formats × upstream HTTP/WS × no/header/metadata
  lite selector × bootstrap buffering off/on. Only Codex/OpenAIResponse with a
  lite selector are native: 16 combinations. These all use `Stream:true`.
  Bootstrap buffering is **not nonstreaming HTTP**. Request preparation,
  classification, alias headers and model/route selection belong to F12/F13.
- [Executor streaming hydration guard](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_executor_stream.go#L248-L266):
  native execution preserves completed.output, compatibility execution hydrates.
  The same decision appears in the later stream loop.
- [Public HTTP handler repair](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L203-L211),
  [item recording and hydration](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L320-L379),
  [framer construction](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L704-L719),
  [forwarding through the framer](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L1009-L1055).
  The handler hydrates absent/empty completed.output even for Codex clients.
  Its private-event filtering and error rewrites are separate behavior, not
  implemented or qualified by this codec.
- [Nonstream Execute](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_executor_execute.go#L160-L199):
  collects item.done and unconditionally hydrates at line 188 before translation.
  Native streaming transparency cannot be generalized to that path.
- [Duplex sparse envelopes and id-less item shape](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_websockets_duplex_test.go#L59-L90).
  Missing response object/status and missing output item id are source-backed.
  Steering controls and their lifecycle are **not** implemented by F11.

The three literal JSON event-data strings in `test/responses_sparse_test.gleam`
were compared against the pinned executor source: **3/3 exact matches**.

| Event data | SHA-256, UTF-8 without an added newline |
| --- | --- |
| metadata | `6baffc27198461b901fc896c0654063ccb1863c79d7150402e035d04cd40662b` |
| item.done | `87653f7cca05963cb2b49bcdb9f53d288397a99b8e818f0801dc3d3a230ee5a0` |
| completed | `d67cb80dc6ae32c97a73a97570859c77b12c6e7b1d8b57ca3fd1322fbfa41f97` |

These are **synthetic source fixtures**, not captured upstream traffic.
The codec tests exercise their common data sequence, not the 48 executor
request-preparation/transport combinations or 16 assembled native workflows.

## Additive compiled consumer contract

```gleam
// mimic/protocol/responses/stream
Policy = Strict
       | NativeSparse(sparse.Projection, max_observation_bytes: Int, max_events: Int)
new_with_policy(Policy) -> Result(Stream, String)
new_with_policy_and_limits(Policy, frame_bytes: Int, items: Int, parts: Int)
  -> Result(Stream, String)
feed_wire_partial(Stream, BitArray) -> WireBatch
push_json(Stream, String) -> Result(#(Stream, WireEvent), String)
wire_event(WireEvent) -> Event
wire_data(WireEvent) -> String
wire_report(WireEvent) -> Option(sparse.Report)
encode_wire_event(WireEvent) -> String
terminal_report(Stream) -> Option(sparse.Report)

// mimic/protocol/responses/sparse
Projection = Transparent | HydrateCompleted
Reconstruction = Reconstructed(responses.Response) | Unknown(List(Gap))
Authority = ContinuationEligible(responses.Response) | Ineligible(List(Gap))
reconstruction(Report) -> Reconstruction
authority(Report) -> Authority
status(Report) -> responses.Status

// mimic/protocol/responses/http
open_sse_with_policy(status: Int, List(Header), Policy) -> Result(Stream, String)
run_wire_fold(state, handle, next, cancel, initial, emit)
  -> Result(#(stream.Outcome, Option(sparse.Report), accumulator), Failure(error))
// emit: fn(accumulator, WireEvent) -> Result(#(accumulator, Control), String)

// mimic/protocol/responses/websocket
new_with_policy(Scope, generation: String, Policy) -> Result(Session, String)
receive_wire(Session, Scope, generation: String, message: String)
  -> Result(#(Session, WireEvent), String)
```

`WireEvent` and `Report` are opaque. WireBatch has `events` and `next`, like the
existing valid-prefix Batch. Stream constructors, feed/push, terminal_response,
run/run_fold, and WS new/create/receive keep their existing signatures.
All existing constructors choose **Strict**. No client hint selects a policy.

Use `wire_data` for WS text and `encode_wire_event` for SSE. Transparent preserves
the validated original **JSON event data**, including spacing, key order,
multiline data, UTF-8 and extensions. It is not a promise to preserve SSE comments,
field spelling, delimiters, id/retry fields, or raw TCP/RFC6455 framing.
HydrateCompleted changes only absent/empty `response.completed.response.output`,
from a contiguous set of fully validated final item snapshots. It does not
invent response.created, added events, ids, object/status fields on the wire,
usage, reasoning bodies, tool inputs, or unknown empty output.

`stream.terminal_response` remains the strict document decoder. Do not run
sparse wire documents through that accessor to infer authority. Use the report;
its reconstructed Response can contain protocol-derived object/status constants
without pretending those fields were present on the native wire.

## Reconstruction and authority

| Observations | Wire completion | Reconstruction | Continuation eligibility |
| --- | --- | --- | --- |
| Exact native fixture: metadata, full indexed done, completed with `[]`, no created | Completed | Validated closed item snapshot set; usage/extensions retained | Ineligible: MissingCreated |
| Same sequence, HydrateCompleted | Completed, wire output hydrated | Same as Transparent | Same ineligibility; projection adds no authority |
| Created + full nonempty done snapshots + matching completed | Completed | Reconstructed | Eligible only as evidence; owner must still enforce transport/scope fences |
| Supplied nonempty terminal output consistent with all observations | Completed | Reconstructed if ids/types are known | Requires created and all other eligibility conditions |
| Created + completed `[]`, no item observations | Completed | Unknown: MissingOutput | Ineligible; native `[]` does not prove empty history |
| Omitted terminal output with open items | Completed | Unknown: OpenItems | Ineligible |
| Full id-less source item(s) | Completed | Unknown: MissingItemIdentity | Ineligible; no fabricated ids |
| Unknown native item/content type | Completed, data retained | Unknown: UnknownExtension | Ineligible |
| Incomplete / failed / cancelled / error | Distinct non-success outcome | Only supplied/closed observations, or Unknown | Ineligible: NonCompleted, plus any other gaps |
| Local cancel | Cancelled | No reusable report | Ineligible; observations are discarded |
| Malformed event, contradiction, framing failure, disconnect before terminal | Error with prior valid events preserved | No reusable next state | No authority; close/cancel and discard state |

Gaps are typed: MissingCreated, MissingItemIdentity, MissingOutput, OpenItems,
UnknownExtension and NonCompleted. Completion is not reconstructed completeness,
and reconstructed completeness is not permission to persist or use a receipt.

The observer checks nonempty supplied ids, contiguous output/part indices,
unique item/call ids (including identities first supplied at done), monotonic
sequence numbers, parent/part kinds, text and tool-input evidence, closed-part
and final-item consistency, reasoning/encrypted-content preservation, response
id/status integrity, usage shape/nonnegative counts and supplied total-token
sum. Completed cannot contain nonnull error/incomplete evidence. Raw name/call_id
on tool delta/done must agree **before** any alias restoration.

Initial snapshots are only initial evidence. No final item payload means no
item.done reconstruction. In particular initial reasoning.summary cannot be
erased or treated as final. Deltas/closed parts without an item.done or coherent
full terminal snapshot do not establish a complete item.

## Transport/consumer obligations

- **HTTP:** use run_wire_fold and wait for its successful clean-EOF return.
  A report on an emitted WireEvent is provisional. Later malformed/truncated
  data, I/O or downstream failure returns no report/accumulator. Cancel returns
  Cancelled with no report. Do not issue a receipt from emit or Completed alone.
  Preserve original status/send-state/uncertainty; no automatic replay.
- **WS:** receive_wire uses the existing session owner. Only sparse
  ContinuationEligible enters its existing same-connection receipt path; unknown
  completion clears the prior receipt. Generation must represent the same
  physical upstream connection, not a reconnect alias. The owner must enforce
  client-key validity and provider/account revisions per inference and destroy
  Session on framing/codec/I/O/downstream error, cancellation, reset or revocation.
  No HTTP receipt/cross-socket cached-history substitution.
- Scope/model/pending-tool pairing is still checked by the existing WS create
  path. Reports do not authenticate, bind an account, or store credentials.
  Metadata headers are untrusted event data, never configuration or authorization.
- Thread trusted Policy through the actual provider collectors/forwarders and
  WS session construction. A root preflight that discards its Stream is not an
  integration. F12/F13 own mode classification, routes, shipment and these owner
  fences; this packet does not change any of them.

The conservative sparse API grants neither HTTP history nor a WS cursor from an
unknown empty native summary. A less conservative same-socket cursor contract
would need a distinct source-qualified authority type and tool-state contract;
it must not be implemented by treating unknown output as an empty Response.

## Bounds and deliberate narrowing

Additive constructors reject invalid limits. Maximums: frame 1 MiB, cumulative
JSON observation data 16 MiB, JSON events 100000, items 4096, combined parts per
item 4096. Smaller limits are supported. SSE framing also counts unfinished
lines/ignored fields. Observation bytes include actual JSON-data whitespace,
not only reserialized JSON. Final reconstruction is bounded and a hydrated
event must fit the frame limit. Retained state is bounded observations, not an
unbounded transcript, and is cleared at terminal/cancel.

Compared with CPA's repair helper, F11 deliberately rejects unindexed items,
gapped/reordered indices, duplicate or conflicting observations, output:null,
unknown event kinds, omitted final item payloads and invalid/contradictory
terminal/usage evidence. It does not infer output from a subset of closed items
while another observed item remains open. These are safety constraints, not
claims that CPA rejects the same data. It preserves opaque unknown item payloads
without claiming their semantics or continuation authority. Steering and generic
accept-any-terminal recovery are explicitly unsupported.

## Verification

Toolchain: Gleam 1.18.1, Erlang selected by the same mise environment.
`ERL_FLAGS='+S 2:2 +A 2'`. Final results:

- Build passed.
- **108/108 focused EUnit tests passed:** 71 existing Responses strict/S6/HTTP/
  WS/frame tests and 37 new sparse tests, including seven actual loopback
  HTTP/RFC6455 tests. The loopback peers wait for delivered metadata before
  sending remaining output; clients read one byte at a time.
- Scoped formatting/check and diff whitespace check passed.
- Exact source-event data audit matched all three pinned executor strings.
- Full `gleam test`, full integration/shipment, actual root native routes,
  CPA differential, WSS, installed native clients and live gates were **not run**.
  The user requested the focused gate, not a full/heavy gate. Gleeunit's root
  main discovers every test; the focused entrypoint uses the same EUnit runner
  without unrelated discovery.

Reproduce the new sparse gate:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m responses_sparse_test
```

Reproduce the final existing + new focused gate:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam build
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- erl -noshell \
  -pa build/dev/erlang/*/ebin \
  -eval 'case eunit:test([responses_protocol_test,responses_http_test,responses_fold_test,responses_websocket_test,responses_frames_test,responses_frames_streaming_test,responses_tool_identity_test,responses_sparse_test,responses_sparse_scenario], [verbose, {scale_timeouts, 10}]) of ok -> halt(0); _ -> halt(1) end.'
```

Development failures were retained, not relabelled passing:
initial compilation corrected unsupported guards/list APIs and grouping/type
errors; `sparse-expanded.log` used a mismatched Erlang environment and could not
load the beam; `sparse-loopback-types.log` exposed a test subject owned by the
wrong process; `focused-owned-subject.log` exposed an order-sensitive test
assertion for request JSON; `focused-formatted.log` had 106 passing/one failing
id-less terminal test, exposing an accidental strict-decoder gate before sparse
assessment. All were corrected before `focused-final.log` passed 108/108.
The 36-test `sparse-final.log` is an earlier checkpoint before the final
late-tool-id regression was added.

Raw logs and public source inspection artifacts are under ignored `build/f11/`
in this clone; they are local development evidence, not replicated captures or
external qualification. Owned source/test/doc hashes are in the adjacent
`F11_RESPONSES_SPARSE_SHA256SUMS` manifest. No prior branch files were imported.
