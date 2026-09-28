# Responses protocol handoff v2

**Implemented native common layer; assembled CPA parity is not complete.**
Base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
CPA source pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
No commits, root build/CLI/CI changes, shared IR/dialect edits, or route registration.

The final source-only snapshot is under:
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/bp3dg4b63e1r/mimic/build/responses-contract-v2/`.
`SHA256SUMS` enumerates and hashes every owned file relative to `source/`.
Copy exact approved source to ignored overlays only; coordinator owns assembly.
Earlier snapshots remain immutable; v1 has security defects and is superseded.

## Stable common API

The document and event APIs/types from v1 and v1.1 remain source-compatible.
See their handoff API sections, not their superseded limitations/evidence counts.

| Module | Responsibility |
|---|---|
| `mimic/dialect/responses` | Native request/response/compact decoding and encoding; unknown JSON extensions; known content/tool validation; function/custom result pairing; usage accessors; explicit unsupported cross-dialect conversion |
| `mimic/protocol/responses/stream` | Raw-byte SSE and JSON-event state machine; bounded frame/item/part metadata; ordering/identity/terminal validation; no response-content accumulation |
| `mimic/protocol/responses/http` | Status/content-type/encoding checks and injected pull/emit/cancel lifecycle |
| `mimic/protocol/responses/websocket` | Per-connection JSON create/continuation/cancel state, trusted scope and generation |
| `mimic/protocol/responses/frames` | RFC6455 framing, masking, UTF-8 fragmentation, controls, close and Upgrade validation |

Dependencies: existing base `mimic/ir`, `mimic/types`, Gleam standard library and
existing Erlang/JSON dependencies. Tests additionally use existing gleeunit.
No provider dependencies, new packages, OAuth, backend URLs or special transforms.
Production FFI consists only of CR/LF byte splitting, binary copy, mask XOR and SHA1.
Test-only FFI provides explicitly loopback socket primitives.

### Streaming migration: feed_partial, not atomic feed

```gleam
pub type Batch {
  Batch(events: List(Event), next: Result(Stream, String))
}
feed_partial(Stream, BitArray) -> Batch
```

Emit `batch.events` in order, exactly once, **then** inspect `batch.next`.
`Error` has no reusable state: cancel upstream and report failure. Do not retry,
replace a started stream with pre-output JSON, or synthesize completed.
Use `http.run` to implement this loop with runtime callbacks/backpressure.
The previous `feed` retains its atomic Result signature for buffered/all-or-error
consumers only. Streaming wrappers must migrate to `feed_partial`.

Pinned CPA source motivation:
`sdk/api/handlers/openai/openai_responses_handlers_stream_error_test.go`,
`TestResponsesHandlerCommitsValidFrameBeforeMalformedFrameInSameChunk`
(lines 154–180). The added regression checks every byte split of a valid frame
followed by malformed JSON: the prefix is emitted once and the malformed event
never appears. The pump test asserts one pull and one cleanup with no extra read.

### Compact remains separate

The compact response document retains **absent** output vs explicit `[]`.
Its output accessor returns an empty list for absence; encoding does not add a
field. Null/non-array output is rejected. This follows the native compact fixture
in `internal/runtime/executor/codex_executor_compact_test.go`, lines 36–41, 75–76.
Normal response/terminal validation still requires output: no global weakening
or provider-specific output hydration was introduced.

### RFC6455 API

```gleam
new(Role, Int, Int) -> Result(Decoder, String) // frame/message byte bounds
feed(Decoder, BitArray) -> Result(#(Decoder, List(Event)), String)
finish(Decoder) -> Result(Nil, String)
encode_text(Role, String, Option(BitArray)) -> Result(BitArray, String)
encode_ping(Role, BitArray, Option(BitArray)) -> Result(BitArray, String)
encode_pong(Role, BitArray, Option(BitArray)) -> Result(BitArray, String)
encode_close(Role, Option(Int), String, Option(BitArray)) -> Result(BitArray, String)
accept_key(String) -> Result(String, String)
verify_accept(String, String) -> Result(Nil, String)
server_upgrade(String, List(types.Header)) -> Result(List(types.Header), String)
client_upgrade(Int, List(types.Header), String) -> Result(Nil, String)
```

`Role = Server | Client` is the **local** role. Server decoder requires masked
incoming frames; client decoder rejects masked server frames. Decoder is opaque.
`Event = Text(String) | Ping(BitArray) | Pong(BitArray) |
Close(Option(Int), Option(String))`.

Bounds are 1..1 MiB per frame/message; a message may span multiple frames.
Interleaved controls do not reset partial UTF-8 or message limits. Binary data,
reserved bits/opcodes, malformed/nonminimal lengths, invalid closes, and bytes
after close fail explicitly. Encoders reject non-byte-aligned control data.
`finish` rejects truncated framing and EOF without a close frame.

Client encoders require a fresh four-byte mask from the caller's cryptographically
secure randomness. Deterministic masks in tests are **synthetic**, not production
defaults. No compression or subprotocol negotiation; server may decline an
extension offer, client rejects an unsolicited negotiated extension/subprotocol.
Upgrade helpers verify the HTTP method/status, tokens, version, key and accept
proof. Authentication/origin checks and HTTP/1.1 selection happen before them.

Framing success and response completion are independent: a clean WS close before
the active response terminal still fails the message protocol's disconnected
check. Local cancel is not a response.completed or an invented response.cancel
wire command; it invalidates session state and requests transport cleanup.

## Exact coordinator route-integration steps

At base `src/mimic/ingress.gleam`:

1. `allowed` (line 773) currently only accepts POST messages/chat. Extend the
   method/path table for POST `/v1/responses`, POST `/v1/responses/compact`,
   GET `/v1/responses`. Do not simply add strings to the old POST-only list.
2. In `handle` (line 170), retain `authenticated` first, then dispatch these
   three routes **before** existing `request_body` / `source_dialect` handling
   (lines 182–189). The existing `_ -> Openai` means Chat Completions; never let
   Responses fall through it. Keep existing routes/codecs unchanged.
3. Responses POST: call `decode_request`; validate capability/pairing and scoped
   continuation policy; call provider prepare on `request.document`; revalidate
   with `request_from_value`. Provider runtime selects account/endpoint/headers.
   Pass the protocol/operation/mode explicitly. No generic previous ID removal.
4. Compact POST: `decode_compact_request` rejects streaming. Provider compact
   policy remains provider-owned. `decode_compact_response` validates its distinct
   envelope; return JSON, no SSE/completed synthesis.
5. For an upstream SSE response, use `http.open_sse` before downstream headers.
   Runtime headers being returned already means Started/no failover. After Mist
   chunk-process handoff synchronously `runtime.adopt` before the old owner exits.
   That process drives `http.run`/`feed_partial`; write each event via
   `stream.encode_event`. Preserve the upstream ordered header data in the
   runtime; do not flatten headers into a dictionary.
6. For client buffered mode with upstream streaming, capture a validated terminal
   response returned by successful event validation, then finish the lifecycle.
   Avoid accumulating token deltas; the terminal document provides the output.
   Sparse output requiring provider hydration is an explicit unsupported case.
7. GET upgrade: authorize origin/client, select only a genuinely WS-capable
   adapter, validate with `frames.server_upgrade`, allocate a trusted scope and
   unpredictable server connection generation, and own socket lifecycle in one
   supervised process. Decode masked client frames as Server; pass Text payloads
   to `websocket.create`; forward prepared requests with `encode_create` and
   Client framing using fresh masks. Validate upstream upgrade and unmasked frames
   as Client; pass Text events to `websocket.receive`. Encode downstream frames as
   Server. Answer Ping with Pong; handle close/error/cancel/disconnect with one
   cleanup path. Enforce I/O deadlines and backpressure. Never reuse a session
   receipt on reconnect/account/model change.
8. If runtime lacks physical WS, reject explicitly rather than claiming readiness
   from a codec capability. Current runtime owner reports WS/H2 unsupported.
   No upstream TLS/socket implementation or timeout scheduler is added here.
9. Add actual assembled-ingress conformance drivers. These source-only tests do
   not satisfy the conformance lab's `assembled_ingress=true` requirement.

## Pinned source findings and deliberate differences

- `internal/api/server_routes.go` lines 77–79 registers distinct GET Responses,
  POST Responses and compact, not Chat aliases.
- Codex native response translator lines 15–24 passes event JSON through; lines
  53–61 extracts completed/incomplete document. The common layer additionally
  validates lifecycle and identity. It does not copy model supplementation.
- Codex request translator lines 15–61 forces stream/store/parallel tool flags,
  strips sampling/cache/user fields, rewrites roles and tools. These are provider
  transforms and are intentionally absent from this layer.
- OpenAI Responses-to-Chat translator lines 30–69 maps text formats, token limits
  and instructions; later code repairs tool output IDs. The reverse translator
  lines 594–633 emits custom/function done before item.done and lines 668–680
  starts reasoning summary items. Native preservation is not that translation.
  This implementation rejects all cross-dialect conversions rather than silently
  lose encrypted reasoning, tools, multimodal or unknown fields.
- WS request normalization lines 30–47 supports create/append, and lines 103–133
  uses incremental previous IDs; later lines merge histories. This implementation
  supports explicit same-connection create+previous ID, not append/implicit model
  inheritance or CPA's transcript repair/replacement heuristics.
- Some CPA translator/handler unit fixtures intentionally omit complete response
  metadata or item identities. Normal MIMIC responses require typed envelope,
  stable IDs and complete lifecycle; it does not treat arbitrary delta-only or
  sparse completion fixtures as validated protocol transcripts.
- Codex terminal executor hydrates sparse terminal output and classifies errors/
  bootstrap retries. The common layer does neither; runtime/provider owners
  decide retry policy before output, never after Started.

These are **source observations**, not results of running CPA or provider calls.
No successful differential parity gate or live upstream measurement is claimed.

## Verification and remaining blockers

Commands, all run locally:

```sh
mise exec gleam@1.18.1 -- gleam format --check src test
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam run -m responses_scenario
mise exec gleam@1.18.1 -- gleam run -m responses_frames_test
```

Latest full suite: **239 passed**, 60 new tests on the 179-test baseline.
Both standalone scenarios exit 0 and emit JSON explicitly marked synthetic and
`assembled_ingress:false`. HTTP uses real TCP withholds-terminal-until-first-event
coordination; WS exchanges real Upgrade bytes, masked create, created/completed,
same-connection continuation and cancellation close through the common codecs.
No application warnings. One earlier run timed out in unchanged recorder TLS;
subsequent full runs passed without modifying that unrelated test.

First independent review found seven core security/correctness defects; all were
fixed with explicit regressions before the v1.1 handoff. In particular untrusted
event names cannot inject SSE frames, known malformed content is not treated as
an extension, and output results cannot erase pending function calls.

Second bounded independent review found no concrete blocker in HTTP cleanup,
trusted WS scope/generation isolation, frame/close/UTF-8 limits or Upgrade
validation, and independently ran the then-current **234-test** suite. The final
five source-evidence regressions and `feed_partial` changes were validated in
this owner's **239-test** run; they were not part of that earlier reviewer snapshot.

Still blocking full parity: coordinator route wiring/authenticated socket
ownership, runtime physical WS/TLS integration, assembled route conformance,
CPA differential execution, unsupported cross-dialect conversion, sparse-terminal
hydration, WS append/history heuristics, and provider-specific integration.
The native codecs expose opaque unknown extensions, not a semantic implementation
of every hosted tool/multimodal event. No full generated-content buffering or
delta/final-text equality checking is performed.
