import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/protocol/chat/http
import mimic/protocol/chat/stream
import mimic/protocol/responses/http as lifecycle
import mimic/types

// Synthetic native Chat fixtures. No provider captures or credentials.
fn chunk(delta: String, finish: String) -> String {
  "data: {\"id\":\"synth\",\"object\":\"chat.completion.chunk\",\"model\":\"native\","
  <> "\"choices\":[{\"index\":0,\"delta\":"
  <> delta
  <> ",\"finish_reason\":"
  <> finish
  <> "}]}\n\n"
}

fn restore(value: ir.Value) -> Result(ir.Value, String) {
  case ir.field(value, "model") {
    None -> Ok(value)
    Some(_) ->
      Ok(
        ir.Object([
          #("model", ir.String("alias")),
          ..ir.extras(value, ["model"])
        ]),
      )
  }
}

fn complete() -> BitArray {
  bit_array.from_string(
    chunk(
      "{\"role\":\"assistant\",\"content\":\"é😀\",\"reasoning_content\":\"why\",\"audio\":{\"data\":\"opaque\"},\"vendor\":true}",
      "null",
    )
    <> chunk("{}", "\"stop\"")
    <> "data: [DONE]\n\n",
  )
}

pub fn all_byte_splits_preserve_native_documents_test() {
  let bytes = complete()
  let expected = stream.feed_partial(stream.new(), bytes, restore)
  let assert Ok(done) = expected.next
  stream.finish(done) |> should.equal(Ok(stream.Completed))
  let assert [stream.Event(document), _, stream.Done] = expected.events
  ir.field(document, "model") |> should.equal(Some(ir.String("alias")))
  let assert Ok(choices) =
    ir.required(document, "choices") |> result.try(ir.as_array)
  let assert [choice] = choices
  let assert Some(delta) = ir.field(choice, "delta")
  ir.field(delta, "reasoning_content") |> should.equal(Some(ir.String("why")))
  ir.field(delta, "audio") |> should.not_equal(None)
  indices(bit_array.byte_size(bytes) + 1)
  |> list.each(fn(at) {
    let assert Ok(left) = bit_array.slice(bytes, 0, at)
    let assert Ok(right) =
      bit_array.slice(bytes, at, bit_array.byte_size(bytes) - at)
    let first = stream.feed_partial(stream.new(), left, restore)
    let assert Ok(state) = first.next
    let second = stream.feed_partial(state, right, restore)
    list.append(first.events, second.events) |> should.equal(expected.events)
    let assert Ok(state) = second.next
    stream.finish(state) |> should.equal(Ok(stream.Completed))
  })
}

pub fn one_byte_fragments_and_prefix_before_error_test() {
  let bytes = bit_array.append(complete(), <<"data: bad\n\n":utf8>>)
  indices(bit_array.byte_size(bytes) + 1)
  |> list.each(fn(at) {
    let assert Ok(left) = bit_array.slice(bytes, 0, at)
    let assert Ok(right) =
      bit_array.slice(bytes, at, bit_array.byte_size(bytes) - at)
    let first = stream.feed_partial(stream.new(), left, restore)
    let events = case first.next {
      Error(_) -> first.events
      Ok(state) -> {
        let second = stream.feed_partial(state, right, restore)
        second.next |> should.be_error
        list.append(first.events, second.events)
      }
    }
    list.length(events) |> should.equal(3)
  })
  let #(state, count) =
    indices(bit_array.byte_size(complete()))
    |> list.fold(#(stream.new(), 0), fn(acc, at) {
      let assert Ok(byte) = bit_array.slice(complete(), at, 1)
      let batch = stream.feed_partial(acc.0, byte, restore)
      let assert Ok(next) = batch.next
      #(next, acc.1 + list.length(batch.events))
    })
  count |> should.equal(3)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
}

pub fn terminals_and_eof_are_distinct_test() {
  stream.finish(stream.new()) |> should.be_error
  let done = stream.feed_partial(stream.new(), <<"data: [DONE]\n\n":utf8>>, Ok)
  done.next |> should.be_error
  let batch =
    stream.feed_partial(
      stream.new(),
      bit_array.from_string(chunk("{}", "\"length\"") <> "data: [DONE]\n\n"),
      Ok,
    )
  let assert Ok(state) = batch.next
  stream.finish(state) |> should.equal(Ok(stream.Incomplete))
  let batch =
    stream.feed_partial(
      stream.new(),
      <<
        "data: {\"error\":{\"message\":\"synthetic failure\",\"code\":\"rate_limit\"}}\n\n":utf8,
      >>,
      Ok,
    )
  let assert Ok(state) = batch.next
  stream.finish(state) |> should.equal(Ok(stream.RemoteError))
  let prefix =
    stream.feed_partial(
      stream.new(),
      bit_array.from_string(chunk("{}", "\"stop\"")),
      Ok,
    )
  let assert Ok(state) = prefix.next
  stream.finish(state) |> should.be_error
}

pub fn stable_tool_identity_and_raw_argument_fragments_test() {
  let start =
    chunk(
      "{\"tool_calls\":[{\"index\":0,\"id\":\"call\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\" {\"}}]}",
      "null",
    )
  let finish =
    chunk(
      "{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\" }\"}}]}",
      "\"tool_calls\"",
    )
  let batch =
    stream.feed_partial(
      stream.new(),
      bit_array.from_string(start <> finish <> "data: [DONE]\n\n"),
      Ok,
    )
  batch.next |> should.be_ok
  let assert [stream.Event(first), stream.Event(second), stream.Done] =
    batch.events
  ir.stringify(first) |> should.not_equal(ir.stringify(second))
  let bad =
    chunk(
      "{\"tool_calls\":[{\"index\":0,\"id\":\"different\",\"function\":{\"name\":\"f\",\"arguments\":\"}\"}}]}",
      "\"tool_calls\"",
    )
  let batch =
    stream.feed_partial(stream.new(), bit_array.from_string(start <> bad), Ok)
  list.length(batch.events) |> should.equal(1)
  batch.next |> should.be_error
}

pub fn limits_invalid_utf8_duplicates_and_restore_failure_test() {
  [
    <<"data: ":utf8, 255, "\n\n":utf8>>,
    <<"data: {\"id\":\"a\",\"id\":\"b\"}\n\n":utf8>>,
    <<1:1>>,
  ]
  |> list.each(fn(bytes) {
    stream.feed_partial(stream.new(), bytes, Ok).next |> should.be_error
  })
  stream.feed_partial(
    stream.new_with_limits(8, 1, 1),
    <<": 123456\n\n":utf8>>,
    Ok,
  ).next
  |> should.be_error
  let batch =
    stream.feed_partial(stream.new(), complete(), fn(_) {
      Error("restoration denied")
    })
  batch.events |> should.equal([])
  batch.next |> should.equal(Error("restoration denied"))
}

pub fn pump_emits_prefix_and_cancels_once_test() {
  let calls = process.new_subject()
  let bytes =
    bit_array.from_string(
      chunk("{\"content\":\"valid\"}", "null") <> "data: bad\n\n",
    )
  let result =
    http.run(
      stream.new(),
      0,
      fn(handle) {
        process.send(calls, "pull")
        Ok(Some(#(bytes, handle + 1)))
      },
      fn(_) { process.send(calls, "cancel") },
      Ok,
      fn(_) {
        process.send(calls, "emit")
        Ok(lifecycle.Continue)
      },
    )
  result |> should.equal(Error(lifecycle.Protocol("invalid JSON")))
  process.receive(calls, 100) |> should.equal(Ok("pull"))
  process.receive(calls, 100) |> should.equal(Ok("emit"))
  process.receive(calls, 100) |> should.equal(Ok("cancel"))
  process.receive(calls, 0) |> should.be_error
  http.open_sse(200, [types.Header("Content-Type", "text/event-stream")])
  |> should.be_ok
  http.open_sse(200, [
    types.Header("Content-Type", "text/event-stream"),
    types.Header("content-type", "application/json"),
  ])
  |> should.be_error
}

fn indices(count: Int) -> List(Int) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { index })
}

pub fn native_error_text_is_bounded_by_frame_not_identity_limit_test() {
  let document =
    ir.Object([
      #(
        "error",
        ir.Object([
          #("message", ir.String(string.repeat("synthetic detail ", 100))),
          #("vendor", ir.String("preserved")),
        ]),
      ),
    ])
  let bytes =
    bit_array.from_string("data: " <> ir.stringify(document) <> "\n\n")
  let batch = stream.feed_partial(stream.new(), bytes, Ok)
  batch.events |> should.equal([stream.ErrorEvent(document)])
  let assert Ok(state) = batch.next
  stream.finish(state) |> should.equal(Ok(stream.RemoteError))
}

pub fn named_and_unnamed_errors_keep_sse_dispatch_semantics_test() {
  let document =
    ir.Object([
      #("error", ir.Object([#("message", ir.String("synthetic failure"))])),
    ])
  list.each(["", "event: error\n"], fn(prefix) {
    let frame = prefix <> "data: " <> ir.stringify(document) <> "\n\n"
    let batch =
      stream.feed_partial(stream.new(), bit_array.from_string(frame), Ok)
    let assert [event] = batch.events
    stream.encode_event(event) |> should.equal(frame)
    let assert Ok(state) = batch.next
    stream.finish(state) |> should.equal(Ok(stream.RemoteError))
  })
}
