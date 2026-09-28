# Shared Responses protocol — contract v1

Base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`. CPA source baseline:
`acdace936fa7df2905500c7f5e0a97d683138dea`. Fixtures and tests here are synthetic,
not provider captures or evidence of assembled ingress parity.

## Ownership and proposed stable boundary

No change to `mimic/ir`, `mimic/dialect`, existing OpenAI/Anthropic codecs, root
CLI/build files, or ingress registration is required. Native documents use the
existing lossless `ir.Value` tree; Responses-specific state lives in new modules.
Provider transforms receive `request.document`; revalidate their result with
`request_from_value` before emission. Unknown native fields remain data.

- `mimic/dialect/responses`: `decode_request(String)`, `request_from_value(Value)`
  -> `Result(Request, String)`; `encode_request(Request)` -> `String`.
  `Request` exposes document, model, stream, previous_response_id.
  `decode_response(String)`, `response_from_value(Value)` ->
  `Result(Response, String)`; `Response` exposes document, id, status, output,
  usage. `decode_compact_request`, `decode_compact_response` are distinct
  contracts; compact is not a stream or a completed Responses event.
- `mimic/protocol/responses/stream`: `new()` -> opaque `Stream`;
  `feed(Stream, BitArray)` -> `Result(#(Stream, List(Event)), String)`;
  `push(Stream, Value)` applies the same event validator to a WS JSON message;
  `finish(Stream)` -> `Result(Outcome, String)`.
  Events expose their unchanged native document and event type. Terminal
  outcomes distinguish Completed, Incomplete, Failed, RemoteError and Cancelled.
  `cancel(Stream)` is local, idempotent state cancellation, not a fabricated
  successful server event. `terminal_response(Event)` exposes a validated
  terminal response when present.
- `mimic/protocol/responses/websocket`: session-local, opaque protocol state.
  Create uses a top-level `type: response.create`, not a nested `response`.
  Native incremental continuation requires a completed response on the same
  trusted scope/connection generation. No global cache, implicit cross-session
  lookup, transcript merging, or silent previous_response_id stripping.
  Local cancellation closes the upstream operation; no undocumented
  `response.cancel` wire support is claimed.
- Capabilities explicitly separate native document/SSE/protocol support from
  physical HTTP/WS availability. A codec capability never registers a route
  or makes a provider transport available.

Implemented native subset and final integration instructions are recorded in
`RESPONSES_HANDOFF_V2.md`. This proposal is not a claim that every CPA parity gate
has passed; the handoff distinguishes codec support from production routing.

## Runtime agreement

Runtime `open` returns status, ordered headers and a handle; `next` returns raw
bytes, EOF or typed failure. It owns socket/backpressure/leases. The codec never
opens a provider connection. Returning runtime headers already marks delivery
Started, so decoding failure cannot trigger replay. EOF is not response.completed.
Failed/incomplete/error protocol terminals are outcomes, not retry authorization.

The current owner calls runtime `cancel` on malformed/truncated input, downstream
disconnect, local cancellation, or early protocol terminal. Call `finish` on EOF.
Use `runtime.adopt` synchronously when handing a stream to Mist's chunk process,
before the old process exits. Physical upstream WS/H2 remains unsupported by the
runtime. These boundaries were agreed with the runtime owner.

## Fidelity rules

Native documents retain reasoning summaries, encrypted_content, usage detail,
tools, multimodal content and unknown JSON fields. This is structural fidelity,
not preservation of JSON whitespace, object ordering, or duplicate object keys.
Cross-dialect conversions must be opt-in and reject every unrepresentable field;
existing Chat Completions support is not Responses support.

No full-response accumulation in streaming state: only the unfinished SSE frame,
bounded item/part identities, sequence metadata and terminal classification.
An upstream terminal event may itself contain the entire output. That one frame
is bounded, passed to the caller, and not retained by stream state. Missing output
is never reconstructed by accumulating all prior output deltas.

## Pinned CPA source evidence

Read actual files at the pin, not README descriptions:

- `internal/api/server_routes.go`: GET/POST `/v1/responses`, POST
  `/v1/responses/compact`, plus Codex-direct aliases.
- `internal/translator/codex/openai/responses/codex_openai-responses_response.go`:
  native event forwarding, model supplementation on created/in_progress,
  buffered extraction of completed/incomplete response objects.
- `internal/translator/codex/openai/responses/codex_openai-responses_request.go`:
  provider-specific mutations belong to Codex, not this common layer.
- `internal/translator/openai/openai/responses/openai_openai-responses_{request,response}.go`:
  Chat-to-Responses conversion is a separate translation, with tool indexes,
  reasoning and usage mapping; it is not native pass-through.
- `internal/runtime/executor/codex_executor_{stream,terminal}.go`:
  terminal detection, early EOF errors and provider-specific terminal output
  hydration/retry classification. Hydration is not copied into the common layer.
- `sdk/api/handlers/openai/openai_responses_websocket_requests.go`:
  create/append normalization; incremental previous_response_id vs full-history
  modes. No response.cancel request branch at this pin.
- Corresponding native response translator tests, compact executor tests and
  Responses handler stream-error tests distinguish failure from normal EOF.

## Coordinator integration (not performed here)

1. Register POST `/v1/responses`, POST `/v1/responses/compact`, and GET
   `/v1/responses` upgrade separately, through the existing authentication and
   policy gates. Do not route any of them through the Chat Completions codec.
2. Decode native request; enforce provider capabilities and continuation policy;
   run the provider-owned transform; revalidate. Never strip previous_response_id
   generically. HTTP providers that require replay must require trusted history;
   WS providers may use native incremental input on the same connection.
3. For buffered Responses decode the native response document; for compact use
   the compact response decoder and return application/json, not SSE.
4. For SSE check successful HTTP status/content type, use `feed_partial` on raw
   chunks, emit its validated events with `encode_event`, then inspect `next`.
   A later malformed frame must not erase an already-valid prefix in the same
   chunk. The HTTP `run` helper implements this rule. On EOF call `finish`.
   On failure cancel upstream; once headers were sent report in-stream failure,
   never switch HTTP status or replay. Never synthesize successful completion.
5. GET upgrades use the separate `frames` RFC6455 codec and `websocket` message
   state machine. Production socket/TLS ownership and authenticated routing are
   not registered here. Reject the route explicitly until origin policy, frame
   limits, close/ping deadlines, cancellation and process ownership are wired.
6. Run conformance against assembled ingress. Pure codec tests cannot satisfy
   `assembled_ingress=true`; no route parity is claimed by this handoff.
