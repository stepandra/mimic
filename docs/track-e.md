# Track E — Canonical IR and dialect codecs

This is a Gleam-only, local JSON/SSE translation library. All fixtures and
tests here are **synthetic**. No upstream compatibility or timing has been
measured. The first implementation supports Anthropic Messages and OpenAI
Chat Completions; Gemini, OpenAI Responses, binary content, and multimodal
blocks are not implemented.

## Public interfaces

```gleam
import mimic/dialect
import mimic/dialect/anthropic
import mimic/dialect/openai

// Both codec modules expose the same four functions:
// decode_request(String) -> Result(ir.Request, String)
// encode_request(ir.Request) -> Result(String, String)
// decode_response(String) -> Result(ir.Response, String)
// encode_response(ir.Response) -> Result(String, String)

let stream = dialect.new_stream(dialect.Anthropic, dialect.Openai)
// For each valid UTF-8 network chunk:
let assert Ok(#(stream, ready_frames)) = dialect.feed(stream, chunk)
// Send ready_frames in order, without waiting for the rest of the response.
let assert Ok(final_frames) = dialect.finish(stream)
```

`feed` accepts arbitrary chunk boundaries *between Unicode scalar values*,
including one character at a time, and several SSE events in one chunk.
The returned frames are complete SSE strings including blank-line delimiters.
Its state holds only one pending line, one pending SSE event, and open
content-block metadata, not a whole response. `finish` requires a complete
terminal frame (`message_stop` or `[DONE]`). An upstream `error` event,
malformed or unknown cross-dialect event, unfinished SSE frame, and data after
termination return `Error(String)`. The caller should stop/close the response
when conversion fails; do not send the partially converted result as success.
Same-dialect streaming forwards complete frames, including extensions.

`ir.Value` is a recursive JSON value. Anthropic request/response codecs retain
unknown root fields, message fields, block fields, usage fields, tool inputs,
system blocks, and unrecognised content blocks as data. JSON object key order
and whitespace may change; compare JSON structurally, not byte-for-byte.
`ir.Request` has `origin` and the original OpenAI token-limit spelling;
`ir.Turn` retains string-vs-array content. `ir.Response` retains OpenAI choice
and assistant-message extensions. Editing an IR value before re-encoding uses
the edited fields, rather than a stale copy of the original body.
OpenAI function-argument JSON strings retain their original formatting on
native roundtrips while their parsed `input` is unchanged.

## Fidelity boundary

Cross-dialect translation returns an explicit `Error` when a field/event has
no safe equivalent; it does not strip vendor extensions silently. This
includes Anthropic thinking/signatures, redacted or future content blocks,
cache-control and other unknown options, OpenAI developer instructions,
extra choices, multimodal parts, unknown usage details, and most vendor
metadata. Supported common content includes text, tool calls and tool
results, function tool definitions (`parameters` ↔ `input_schema`), common
tool choices, model, token limit, stop reason, basic usage and stream flag.
OpenAI `max_tokens` and `max_completion_tokens` both map to Anthropic
`max_tokens`; native OpenAI roundtrips preserve the spelling.
Zero Anthropic cache-token counters are safe to omit in OpenAI basic usage;
positive or unknown cache counters fail explicitly.

For incremental streaming, Anthropic `input_json_delta.partial_json` and
OpenAI `tool_calls[].function.arguments` fragments are *relayed as fragments*;
neither side buffers or prematurely parses the whole tool JSON. Nonempty
Anthropic initial tool input is rejected because concatenating it with
future fragments would be ambiguous. Anthropic prompt/completion usage maps
to an OpenAI final usage chunk. OpenAI prompt usage arriving only after its
first chunk cannot be retroactively represented in Anthropic `message_start`,
so that conversion errors explicitly rather than reporting an invented
prompt-token count. The initial Anthropic message uses zero when OpenAI
does not supply prompt usage upfront. Cross-dialect stream metadata not
modeled by the target is unsupported.

There is no live API gate in this track. `gleam test` covers structural JSON
roundtrips, unknown nested extensions, thinking/tool semantics, bidirectional
plain response translation, SSE split at every character, multi-event chunks,
partial tool JSON, usage, errors, and terminal markers. SDK/lab integration,
wire-level fidelity against real provider captures, and latency remain
unverified.
