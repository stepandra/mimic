# F14 compiled contract and approved owner amendment

Base: `85f44ef07144a8a4433933b2f51f1972e4744039` (F15 library frozen).
Scope: native Kimi Anthropic Messages SSE only. No request-normalization,
generic Kimi/F15, gateway/config/CLI/dependency/vendor/CI changes in this child.

The actual Claude `http.run` emits raw native frames. The Claude observer
already parses each JSON document, validates event/type agreement, usage and
lifecycle, and preserves unknown events and native content. A second SSE parser
in Kimi or HTTP would duplicate that authority and is rejected.

## Approved and implemented amendment

The parent relayed the Claude owner's explicit **stream.gleam + http.gleam**
grant and subsequent source-review approval. `F14_CLAUDE_SEAM.patch` contains
the exact approved, formatted hunks; an in-memory application against the base
reconstructs the compiled source byte-for-byte. The opt-in hook lives in the
observer, where the parsed document already exists. Claude adapter was not
edited; it plans requests, not response streams.

Compiled seam:

```gleam
// mimic/providers/claude/stream
new_with_model(upstream_model: String, model: String) -> State

// mimic/providers/claude/http
new_with_model(upstream_model: String, model: String) -> State
run_with_model(
  opened: runtime.Response,
  upstream_model: String,
  model: String,
  emit: fn(String) -> Result(responses_http.Control, String),
) -> Result(claude_stream.Status, String)

// mimic/providers/kimi/adapter
run_messages_for(
  response: runtime.Response,
  request: contracts.Request,
  emit: fn(String) -> Result(responses_http.Control, String),
) -> Result(claude_stream.Status, contracts.Failure)
```

The signatures above compiled with Gleam 1.18.1. Focused preservation/mismatch,
boundaries, cancellation and isolation tests are recorded in `F14_HANDOFF.md`.

The hook is request-scoped. The Kimi runner validates the registered selected
request model and derives the nonempty expected upstream model from the static
mapping, never from the response or unvalidated body identity. It validates
`message_start.message.model == kimi/models.upstream_id(request.model)`, then
replaces **only that field** with the requested public model. All other
documents stay raw; only the start event's JSON data lines are reserialized.
Event/id/retry/comment/extension lines keep their order. Tool inputs/argument
strings, thinking/signatures, usage, nested `model` keys and vendor data are
never recursively transformed. Ordinary Claude callers remain opt-out and
preserve their existing raw frames.

HTTP byte framing, strict headers/encoding, per-event limits, valid prefix
delivery before a same-read error, terminal handling and cancellation stay in
the actual Claude codec. A restored output frame also must fit 1 MiB, including
expansion of a short upstream model ID. No Kimi state, replay cache or hidden
continuation. `Failed(error_kind)` is a delivered terminal remote error, not a
successful message or permission to retry.

## Coordinator-owned gateway dependency

Root dispatch presently accepts native Kimi Messages only for buffered mode;
the inherited Kimi planner explicitly rejected streaming. The owned planner now
admits it by passing the actual requested mode to existing `messages.prepare`.

`F14_GATEWAY.patch` changes only the existing dispatch and adds a Messages
branch under `serve_kimi`, calling the actual `stream_encoded` helper and the
new provider runner. `stream_encoded` retains synchronous runtime adoption.
The target is the coordinator's admitted F15 root
`8fd0c6fcff4f4e7a1a47de33e306e1c84d0ea936`, inspected read-only. Both gateway
hunks have unique exact context there. The root is not edited here. Actual F14
source/shipment workflows remain pending until coordinator admission.

## Allowed verification

Gleam is pinned via `mise exec gleam@1.18.1`. Focused formatting, compile,
selected EUnit modules, synthetic real-loopback runtime tests and the smoke
harness self-test are allowed. No full `gleam test` or integration gate, native
client, real credential, live provider, CPA or differential qualification.
