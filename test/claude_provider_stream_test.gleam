import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/providers/claude/response
import mimic/providers/claude/stream
import mimic/types.{Header}

fn start() {
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_creation_input_tokens\":2,\"cache_read_input_tokens\":3}}}\n\n"
}

fn stop() {
  "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
}

pub fn native_sse_every_character_boundary_test() {
  let unknown =
    "event: synthetic_future\ndata: {\"type\":\"synthetic_future\",\"keep\":true}\n\n"
  let tool =
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"synthetic-call\",\"name\":\"synthetic_tool\",\"input\":{}}}\n\n"
  let delta =
    "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n"
  let data = start() <> tool <> unknown <> delta <> stop()
  let #(state, output) =
    list.fold(string.to_graphemes(data), #(stream.new(), []), fn(acc, chunk) {
      let assert Ok(#(state, frames)) = stream.feed(acc.0, chunk)
      #(state, list.append(acc.1, frames))
    })
  string.join(output, "") |> should.equal(data)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  stream.usage(state)
  |> should.equal(stream.Usage(Some(10), Some(9), Some(2), Some(3)))
  // message_stop is completion even if upstream has not closed the socket.
  stream.status(state) |> should.equal(stream.Completed)
}

pub fn stop_reason_and_eof_are_not_completion_test() {
  let assert Ok(#(state, _)) = stream.feed(stream.new(), start())
  let delta =
    "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n\n"
  let assert Ok(#(state, _)) = stream.feed(state, delta)
  stream.finish(state) |> should.be_error
  let assert Ok(#(state, _)) =
    stream.feed(
      state,
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n",
    )
  stream.finish(state) |> should.be_error
}

pub fn errors_are_terminal_but_not_success_test() {
  let frame =
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"synthetic-sensitive-diagnostic\"}}\n\n"
  let assert Ok(#(state, frames)) = stream.feed(stream.new(), frame)
  frames |> should.equal([frame])
  stream.finish(state) |> should.equal(Ok(stream.Failed(stream.Overloaded)))
  stream.feed(state, start()) |> should.equal(Ok(#(state, [])))
  stream.usage(state) |> should.equal(stream.Usage(None, None, None, None))
}

pub fn terminal_is_sticky_across_trailing_chunks_test() {
  let terminal = start() <> stop()
  let trailing = "event: ping\ndata: {\"type\":\"ping\"}\n\n:partial-comment"
  let assert Ok(#(coalesced, frames)) =
    stream.feed(stream.new(), terminal <> trailing)
  string.join(frames, "") |> should.equal(terminal)
  stream.finish(coalesced) |> should.equal(Ok(stream.Completed))
  let assert Ok(#(split, _)) = stream.feed(stream.new(), terminal)
  let assert Ok(#(split, frames)) = stream.feed(split, trailing)
  frames |> should.equal([])
  stream.finish(split) |> should.equal(Ok(stream.Completed))
  stream.usage(split) |> should.equal(stream.usage(coalesced))
  stream.feed(split, string.repeat("x", 1_048_577))
  |> should.equal(Ok(#(split, [])))
}

pub fn malformed_and_spoofed_terminal_events_test() {
  stream.feed(stream.new(), stop()) |> should.be_error
  stream.feed(stream.new(), "data: [DONE]\n\n") |> should.be_error
  stream.feed(
    stream.new(),
    "event: message_stop\ndata: {\"type\":\"ping\"}\n\n",
  )
  |> should.be_error
  let assert Ok(#(state, _)) = stream.feed(stream.new(), start())
  stream.feed(state, start()) |> should.be_error
  stream.feed(
    state,
    "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":-1}}\n\n",
  )
  |> should.be_error
  stream.feed(state, string.repeat("x", 1_048_577)) |> should.be_error
}

pub fn request_rejection_scope_and_delay_test() {
  response.classify(
    429,
    [],
    "{\"error\":{\"message\":\"Usage credits are required for fast mode\"}}",
  )
  |> should.equal(Some(response.FastModeEntitlement))
  response.classify(
    429,
    [Header("Retry-After", "17")],
    "{\"error\":{\"message\":\"synthetic rate limit\"}}",
  )
  |> should.equal(Some(response.RateLimited(Some(17_000))))
  response.classify(401, [], "synthetic-secret")
  |> should.equal(Some(response.Authentication))
  response.classify(529, [], "") |> should.equal(Some(response.Overloaded))
  response.classify(200, [], "") |> should.equal(None)
  response.classify(302, [], "")
  |> should.equal(Some(response.UnexpectedStatus))
}
