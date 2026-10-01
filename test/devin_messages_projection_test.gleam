import devin_messages_oracle as oracle
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/responses/http.{Cancel}
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/client
import mimic/providers/devin/messages
import mimic/providers/devin/messages_gateway as gateway
import mimic/providers/devin/messages_stream as projection
import mimic/providers/devin/models
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/response
import mimic/providers/devin/stream as native
import mimic/providers/registry
import mimic/providers/runtime

pub type Server

@external(erlang, "mimic_devin_f24_messages_test_ffi", "with_servers")
fn with_servers(
  bytes: BitArray,
  close: Bool,
  run: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_f24_messages_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_devin_f24_messages_test_ffi", "counts")
fn counts(server: Server) -> #(Int, Int, Int)

@external(erlang, "mimic_devin_f24_messages_test_ffi", "focused")
fn focused() -> Bool

pub fn main() {
  let assert True = focused()
  Nil
}

fn state() {
  let assert Ok(state) = projection.new("msg-synthetic-f24", "devin/swe-1-7")
  state
}

fn encode(events: List(response.Event)) {
  list.try_fold(events, #(state(), []), fn(acc, event) {
    use #(state, frames) <- result.try(projection.encode(acc.0, event))
    Ok(#(state, list.append(acc.1, frames)))
  })
}

fn tool(id: String, name: String, arguments: BitArray) {
  response.Tool(response.ToolDelta(id, name, arguments, <<>>, "", False))
}

fn usage() {
  response.Usage(
    ir.Usage(8, 5, [
      #("cache_write_tokens", ir.Integer(4)),
      #("cached_input_tokens", ir.Integer(3)),
    ]),
  )
}

fn data(fields: List(pb.Field)) {
  let bytes = pb.encode(fields)
  <<0, { bit_array.byte_size(bytes) }:32-big, bytes:bits>>
}

fn eos() {
  <<2, 2:32-big, "{}":utf8>>
}

fn native_tool(id: String, name: String, arguments: BitArray) {
  pb.message(6, [pb.text(1, id), pb.text(2, name), pb.Bytes(3, arguments)])
}

/// All payload/signature/counters are SYNTHETIC, not upstream captures.
fn qualified_native() {
  <<
    { data([pb.text(9, "synthetic reasoning")]) }:bits,
    { data([native_tool("first", "", <<"{\"x\":\"":utf8, 226>>)]) }:bits,
    { data([pb.text(3, "A")]) }:bits,
    { data([native_tool("second", "two", <<"{}":utf8>>)]) }:bits,
    { data([pb.text(3, "B")]) }:bits,
    { data([native_tool("first", "one", <<130, 172, "\"}":utf8>>)]) }:bits,
    { data([pb.text(3, "C")]) }:bits,
    {
      data([pb.text(10, "CAQSsynthetic-not-verified"), pb.text(21, "anthropic")])
    }:bits,
    {
      data([
        pb.message(7, [
          pb.Varint(2, 8),
          pb.Varint(3, 5),
          pb.Varint(4, 4),
          pb.Varint(5, 3),
        ]),
        pb.Varint(5, 10),
      ])
    }:bits,
    { eos() }:bits,
  >>
}

fn parity(bytes: BitArray) {
  let assert Ok(body) =
    messages.buffered(bytes, "msg-synthetic-f24", "devin/swe-1-7")
  let assert Ok(buffered) = ir.parse(body)
  let assert Ok(#(decoder, events)) = response.feed(response.new(), bytes)
  response.finish(decoder) |> should.be_ok
  let assert Ok(#(last, frames)) = encode(events)
  oracle.reconstruct(frames) |> should.equal(Ok(buffered))
  projection.encode(last, response.Stop) |> should.be_error
  frames
}

fn nested_tool_native(depth: Int) -> BitArray {
  let arguments =
    string.repeat("{\"x\":", depth) <> "0" <> string.repeat("}", depth)
  <<
    {
      data([
        native_tool("deep", "synthetic-tool", bit_array.from_string(arguments)),
        pb.message(7, [pb.Varint(2, 8), pb.Varint(3, 5)]),
        pb.Varint(5, 10),
      ])
    }:bits,
    { eos() }:bits,
  >>
}

pub fn full_message_depth_boundary_keeps_json_sse_parity_test() {
  // The Message/content/tool envelope adds three containers to the tool input.
  list.each([124, 125], fn(depth) {
    let _ = parity(nested_tool_native(depth))
    Nil
  })
}

pub fn full_message_depth_overflow_is_rejected_in_both_modes_test() {
  list.each([126, 127, 128], fn(depth) {
    let bytes = nested_tool_native(depth)
    messages.buffered(bytes, "msg-synthetic-f24", "devin/swe-1-7")
    |> should.be_error
    let assert Ok(#(decoder, events)) = response.feed(response.new(), bytes)
    response.finish(decoder) |> should.be_ok
    encode(events) |> should.be_error
  })
}

pub fn strict_sdk_reconstruction_delayed_names_interleaved_tools_text_signed_thinking_test() {
  let frames = parity(qualified_native())
  let assert Ok(message) = oracle.reconstruct(frames)
  let assert Some(ir.Array(blocks)) = ir.field(message, "content")
  let assert [thinking, first, a, second, bc] = blocks
  ir.field(thinking, "signature")
  |> should.equal(Some(ir.String("CAQSsynthetic-not-verified")))
  ir.field(first, "id") |> should.equal(Some(ir.String("first")))
  ir.field(first, "input")
  |> should.equal(Some(ir.Object([#("x", ir.String("€"))])))
  ir.field(a, "text") |> should.equal(Some(ir.String("A")))
  ir.field(second, "id") |> should.equal(Some(ir.String("second")))
  ir.field(bc, "text") |> should.equal(Some(ir.String("BC")))
}

pub fn exact_zero_usage_is_measured_not_fabricated_and_initial_snapshot_initialized_test() {
  let bytes = <<
    {
      data([
        pb.text(3, "text"),
        pb.message(7, [pb.Varint(2, 0), pb.Varint(3, 0)]),
      ])
    }:bits,
    { eos() }:bits,
  >>
  let frames = parity(bytes)
  let assert [start, ..] = frames
  string.contains(start, "\"input_tokens\":0") |> should.be_true
  string.contains(start, "\"output_tokens\":0") |> should.be_true
  let assert Ok(#(_, before)) = encode([response.Text("not yet"), usage()])
  before |> should.equal([])
}

pub fn same_tool_continuation_does_not_reopen_or_split_text_run_test() {
  let bytes = <<
    { data([native_tool("one", "", <<"{\"a\":":utf8>>)]) }:bits,
    { data([pb.text(3, "x")]) }:bits,
    { data([native_tool("one", "lookup", <<"1}":utf8>>)]) }:bits,
    { data([pb.text(3, "y")]) }:bits,
    { data([pb.message(7, [pb.Varint(2, 2), pb.Varint(3, 7)])]) }:bits,
    { eos() }:bits,
  >>
  let assert Ok(message) = oracle.reconstruct(parity(bytes))
  let assert Some(ir.Array([call, text])) = ir.field(message, "content")
  ir.field(call, "id") |> should.equal(Some(ir.String("one")))
  ir.field(text, "text") |> should.equal(Some(ir.String("xy")))
}

pub fn usage_snapshots_merge_in_native_decoder_and_absent_partial_estimate_reject_test() {
  let complete = <<
    { data([pb.message(7, [pb.Varint(3, 7)])]) }:bits,
    { data([pb.message(7, [pb.Varint(2, 2)])]) }:bits,
    { eos() }:bits,
  >>
  parity(complete) |> should.not_equal([])
  list.each(
    [
      <<{ eos() }:bits>>,
      <<{ data([pb.message(7, [pb.Varint(3, 7)])]) }:bits, { eos() }:bits>>,
    ],
    fn(bytes) { messages.buffered(bytes, "id", "model") |> should.be_error },
  )
  list.each(
    [
      ir.Usage(0, 1, [#("devin_input_known", ir.Boolean(False))]),
      ir.Usage(1, 1, [#("devin_usage_source", ir.String("dimension_estimate"))]),
      ir.Usage(-1, 1, []),
    ],
    fn(value) {
      encode([response.Text("prefix"), response.Usage(value), response.Stop])
      |> should.be_error
    },
  )
  encode([response.Text("prefix"), response.Stop]) |> should.be_error
}

pub fn unsigned_opaque_missing_type_or_ambiguous_thinking_reject_not_success_test() {
  list.each(
    [
      [response.ThinkingDelta("reason"), usage(), response.Stop],
      [
        response.ThinkingDelta("reason"),
        response.SignatureDelta(<<"CAQSsynthetic":utf8>>),
        usage(),
        response.Stop,
      ],
      [
        response.SignatureDelta(<<"CAQSsynthetic":utf8>>),
        response.SignatureType("anthropic"),
        usage(),
        response.Stop,
      ],
      [
        response.ThinkingDelta("first"),
        response.Text("between"),
        response.ThinkingDelta("second"),
      ],
      [response.ThinkingDelta("reason"), response.SignatureType("sealed")],
    ],
    fn(events) { encode(events) |> should.be_error },
  )
  let bytes = <<
    {
      data([
        pb.text(9, "reason"),
        pb.message(7, [pb.Varint(2, 8), pb.Varint(3, 5)]),
      ])
    }:bits,
    { eos() }:bits,
  >>
  messages.buffered(bytes, "id", "model") |> should.be_error
}

pub fn malformed_tool_custom_conflicting_name_nonobject_or_incomplete_reject_test() {
  list.each([<<"{":utf8>>, <<"[1]":utf8>>, <<255>>, <<>>], fn(args) {
    encode([tool("id", "lookup", args), usage(), response.Stop])
    |> should.be_error
  })
  encode([tool("id", "", <<"{}":utf8>>), usage(), response.Stop])
  |> should.be_error
  encode([tool("id", "first", <<"{}":utf8>>), tool("id", "other", <<>>)])
  |> should.be_error
  encode([response.Tool(response.ToolDelta("id", "f", <<>>, <<>>, "", True))])
  |> should.be_error
}

pub fn unknown_stop_filtered_and_tool_stop_without_tool_reject_test() {
  list.each([0, 11, 999], fn(n) {
    encode([response.Reason(n)]) |> should.be_error
  })
  encode([usage(), response.Reason(10), response.Stop]) |> should.be_error
  list.each([1, 2, 3, 4], fn(n) {
    let assert Ok(#(_, frames)) =
      encode([response.Text("x"), usage(), response.Reason(n), response.Stop])
    oracle.reconstruct(frames) |> should.be_ok
  })
}

pub fn aggregate_event_block_tool_and_bytes_limits_fail_closed_test() {
  let assert Ok(builder) = messages.new("id", "model")
  let many = list.repeat(response.Text(""), messages.max_events)
  let assert Ok(full) = list.try_fold(many, builder, messages.push)
  messages.push(full, response.Stop) |> should.be_error
  let many =
    list.index_map(list.repeat(Nil, 128), fn(_, i) {
      [tool(int.to_string(i), "lookup", <<"{}":utf8>>), response.Text("x")]
    })
    |> list.flatten
  let assert Ok(#(full, _)) = encode(many)
  projection.encode(full, tool("new", "lookup", <<"{}":utf8>>))
  |> should.be_error
  messages.push(
    builder,
    response.Text(string.repeat("x", messages.max_bytes + 1)),
  )
  |> should.be_error
}

pub fn encoded_limit_is_same_for_buffered_and_sse_not_a_late_codec_loss_test() {
  let text = string.repeat("x", messages.max_response_bytes)
  let bytes = <<
    {
      data([pb.text(3, text), pb.message(7, [pb.Varint(2, 8), pb.Varint(3, 5)])])
    }:bits,
    { eos() }:bits,
  >>
  messages.buffered(bytes, "id", "model") |> should.be_error
  encode([response.Text(text), usage(), response.Stop]) |> should.be_error
  let parts =
    list.index_map(list.repeat(Nil, 128), fn(_, i) {
      [tool(int.to_string(i), "lookup", <<"{}":utf8>>), response.Text("x")]
    })
    |> list.flatten
  encode([response.ThinkingDelta("reason"), ..parts]) |> should.be_error
}

pub fn oracle_rejects_historical_omission_out_of_order_overlap_unsigned_and_premature_test() {
  let start =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"id\",\"model\":\"model\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":8,\"output_tokens\":5}}}\n\n"
  oracle.feed(
    oracle.new(),
    string.replace(
      start,
      ",\"usage\":{\"input_tokens\":8,\"output_tokens\":5}",
      "",
    ),
  )
  |> should.be_error
  let assert Ok(state) = oracle.feed(oracle.new(), start)
  let block =
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
  oracle.feed(state, string.replace(block, "\"index\":0", "\"index\":1"))
  |> should.be_error
  let assert Ok(open) = oracle.feed(state, block)
  oracle.feed(open, string.replace(block, "\"index\":0", "\"index\":1"))
  |> should.be_error
  oracle.feed(
    open,
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  )
  |> should.be_error
  let thinking =
    string.replace(
      block,
      "{\"type\":\"text\",\"text\":\"\"}",
      "{\"type\":\"thinking\",\"thinking\":\"x\",\"signature\":\"\"}",
    )
  let assert Ok(unsigned) = oracle.feed(state, thinking)
  oracle.feed(
    unsigned,
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
  )
  |> should.be_error
}

fn request(mode: c.Mode, body: String) {
  c.Request(
    "devin",
    "session_token",
    "devin/swe-1-7",
    "anthropic-messages",
    "generate",
    mode,
    [],
    "synthetic-f24-client",
    None,
    body,
  )
}

fn body(stream: Bool) {
  "{\"model\":\"devin/swe-1-7\",\"max_tokens\":32,\"stream\":"
  <> case stream {
    True -> "true"
    False -> "false"
  }
  <> ",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic hello\"}]}"
}

fn engine(directory: String, one: Server, two: Server) {
  let assert Ok(store) = storage.new(directory)
  let accounts =
    list.map([#("one", one), #("two", two)], fn(pair) {
      let assert Ok(_) =
        runtime_store.save(
          store,
          credentials.key("devin", "session_token", pair.0),
          c.SessionToken("synthetic-f24-token-" <> pair.0, []),
        )
      runtime.Account(
        "devin",
        "session_token",
        pair.0,
        "http://127.0.0.1:" <> int.to_string(port(pair.1)),
        fleet.LocalLoopback,
        1,
        ["devin/swe-1-7"],
        credentials.StaticSession,
      )
    })
  let assert Ok(model) = gateway.combined_registration("devin/swe-1-7")
  let assert Ok(registered) = registry.new([model])
  let assert Ok(engine) = runtime.start(store, registered, accounts)
  engine
}

fn open(engine: runtime.Runtime) {
  let assert Ok(#("one", opened)) =
    gateway.open(engine, None, request(c.Streaming, body(True)))
  opened
}

fn collect(opened: client.Client(projection.State), frames: List(String)) {
  let batch = client.next(opened)
  let frames = list.append(frames, batch.frames)
  case batch.done {
    True -> #(batch, frames)
    False -> collect(batch.client, frames)
  }
}

fn http(body: BitArray, chunked: Bool) {
  case chunked {
    False -> {
      let headers =
        "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: "
        <> int.to_string(bit_array.byte_size(body))
        <> "\r\n\r\n"
      <<headers:utf8, body:bits>>
    }
    True -> {
      let assert Ok(size) = int.to_base_string(bit_array.byte_size(body), 16)
      <<
        "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
        size:utf8,
        "\r\n":utf8,
        body:bits,
        "\r\n":utf8,
      >>
    }
  }
}

fn once(engine: runtime.Runtime, one: Server, two: Server) {
  runtime.active_leases(engine) |> should.equal(Ok(0))
  counts(one).0 |> should.equal(1)
  counts(one).1 |> should.equal(1)
  counts(two).0 |> should.equal(0)
  runtime.stop(engine) |> should.be_ok
}

fn await_eof(server: Server, attempts: Int) {
  case counts(server).2 > 0 {
    True -> Nil
    False if attempts > 0 -> {
      process.sleep(10)
      await_eof(server, attempts - 1)
    }
    False -> counts(server).2 |> should.equal(1)
  }
}

pub fn socket_buffered_thinking_tools_exact_usage_test() {
  use directory, one, two <- with_servers(http(qualified_native(), False), True)
  let engine = engine(directory, one, two)
  gateway.execute(engine, None, request(c.Buffered, body(False)))
  |> should.be_ok
  once(engine, one, two)
}

pub fn socket_sse_barrier_waits_eos_plus_clean_eof_and_emits_once_test() {
  use directory, one, two <- with_servers(http(qualified_native(), False), True)
  let engine = engine(directory, one, two)
  let prefix = client.next(open(engine))
  prefix.done |> should.be_false
  prefix.frames |> should.equal([])
  let #(batch, frames) = collect(prefix.client, [])
  batch.error |> should.equal(None)
  oracle.reconstruct(frames) |> should.be_ok
  client.next(batch.client).frames |> should.equal([])
  once(engine, one, two)
}

fn failure_case(suffix: BitArray, chunked: Bool) {
  use directory, one, two <- with_servers(
    http(<<{ data([pb.text(3, "prefix")]) }:bits, suffix:bits>>, chunked),
    True,
  )
  let engine = engine(directory, one, two)
  let #(batch, frames) = collect(open(engine), [])
  batch.error
  |> should.equal(Some(c.Failure(c.InvalidResponse, c.Started, None)))
  frames |> should.equal([])
  let failed = projection.failure(c.Failure(c.InvalidResponse, c.Started, None))
  let assert Ok(observer) = oracle.feed(oracle.new(), failed)
  oracle.finish(observer) |> should.be_error
  string.contains(failed, "synthetic-private") |> should.be_false
  client.next(batch.client).frames |> should.equal([])
  once(engine, one, two)
}

pub fn socket_error_trailer_safe_failure_no_replay_test() {
  let trailer = <<
    "{\"error\":{\"code\":\"unauthenticated\",\"message\":\"synthetic-private\"}}":utf8,
  >>
  failure_case(
    <<2, { bit_array.byte_size(trailer) }:32-big, trailer:bits>>,
    False,
  )
}

pub fn socket_malformed_trailer_test() {
  failure_case(<<2, 1:32-big, "{":utf8>>, False)
}

pub fn socket_truncated_trailer_test() {
  failure_case(<<2, 2:32-big, "{":utf8>>, False)
}

pub fn socket_missing_eos_test() {
  failure_case(<<>>, False)
}

pub fn socket_post_eos_data_test() {
  failure_case(<<{ eos() }:bits, 0>>, False)
}

pub fn socket_unknown_native_field_test() {
  failure_case(data([pb.Bytes(99, <<0>>)]), False)
}

pub fn socket_eos_then_http_truncation_test() {
  failure_case(eos(), True)
}

pub fn socket_projection_error_while_buffering_cancels_without_invalid_prefix_test() {
  let bytes = <<
    { data([pb.text(3, "prefix")]) }:bits,
    {
      data([
        pb.message(6, [pb.text(1, "id"), pb.text(2, "custom"), pb.Varint(6, 1)]),
      ])
    }:bits,
  >>
  use directory, one, two <- with_servers(http(bytes, True), False)
  let engine = engine(directory, one, two)
  let #(batch, frames) = collect(open(engine), [])
  batch.error |> should.equal(Some(c.Failure(c.Unsupported, c.Started, None)))
  frames |> should.equal([])
  await_eof(one, 100)
  once(engine, one, two)
}

pub fn socket_cancel_while_buffering_releases_lease_test() {
  use directory, one, two <- with_servers(
    http(data([pb.text(3, "prefix")]), True),
    False,
  )
  let engine = engine(directory, one, two)
  let opened = open(engine)
  let prefix = client.next(opened)
  prefix.frames |> should.equal([])
  client.cancel(prefix.client)
  await_eof(one, 100)
  once(engine, one, two)
}

pub fn socket_owner_death_while_buffering_releases_lease_test() {
  use directory, one, two <- with_servers(
    http(data([pb.text(3, "prefix")]), True),
    False,
  )
  let engine = engine(directory, one, two)
  let opened = open(engine)
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) = client.adopt(opened)
      let prefix = client.next(opened)
      process.send(ready, prefix.frames)
      let _ = client.next(prefix.client)
      Nil
    })
  process.receive(ready, 3000) |> should.equal(Ok([]))
  process.kill(owner)
  await_eof(one, 100)
  once(engine, one, two)
}

pub fn socket_downstream_cancel_valid_sdk_prefix_does_not_send_stop_test() {
  use directory, one, two <- with_servers(http(qualified_native(), False), True)
  let engine = engine(directory, one, two)
  let frames = process.new_subject()
  client.run(open(engine), fn(frame) {
    process.send(frames, frame)
    Ok(Cancel)
  })
  |> should.equal(Ok(client.Cancelled))
  let assert Ok(prefix) = process.receive(frames, 1000)
  oracle.feed(oracle.new(), prefix) |> should.be_ok
  string.contains(prefix, "message_stop") |> should.be_false
  once(engine, one, two)
}

pub fn socket_downstream_failure_no_replay_test() {
  use directory, one, two <- with_servers(http(qualified_native(), False), True)
  let engine = engine(directory, one, two)
  client.run(open(engine), fn(_) { Error("synthetic disconnected") })
  |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
  once(engine, one, two)
}

pub fn hard_total_deadline_cancels_native_and_lease_while_buffering_test() {
  use directory, one, two <- with_servers(
    http(data([pb.text(3, "prefix")]), True),
    False,
  )
  let engine = engine(directory, one, two)
  let assert Ok(output) =
    runtime.open(
      engine,
      gateway.bounded_adapter(bridge.adapter(None), 100),
      request(c.Streaming, body(True)),
    )
  let opened = client.new(native.new(output.stream), state(), projection.encode)
  let #(batch, frames) = collect(opened, [])
  frames |> should.equal([])
  batch.error |> should.not_equal(None)
  await_eof(one, 100)
  once(engine, one, two)
}

pub fn native_history_image_thinking_call_result_preservation_and_pre_io_loss_test() {
  let value =
    "{\"model\":\"devin/swe-1-7\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGk=\"}}]},{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"reason\",\"signature\":\"CAQSsynthetic\"},{\"type\":\"tool_use\",\"id\":\"call-one\",\"name\":\"lookup\",\"input\":{\"x\":1}}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call-one\",\"content\":\"found\"}]},{\"role\":\"user\",\"content\":\"next\"}]}"
  let request = request(c.Buffered, value)
  gateway.validate(request, models.baseline()) |> should.be_ok
  let assert Ok(plan) =
    bridge.prepare(
      c.Context(
        "devin",
        "session_token",
        "one",
        "http://127.0.0.1:1",
        "scope",
        c.SessionToken("synthetic-f24", []),
      ),
      request,
    )
  let assert <<0, _:32-big, payload:bits>> = plan.body
  let assert Ok(fields) = pb.decode(payload)
  let prompts =
    list.filter_map(fields, fn(field) {
      case field {
        pb.Bytes(3, bytes) -> pb.decode(bytes)
        _ -> Error("not prompt")
      }
    })
  let assert [user, assistant, result, _] = prompts
  list.contains(
    user,
    pb.message(10, [pb.text(1, "aGk="), pb.text(2, "image/png")]),
  )
  |> should.be_true
  list.contains(assistant, pb.text(11, "reason")) |> should.be_true
  list.contains(assistant, pb.text(12, "CAQSsynthetic")) |> should.be_true
  list.contains(assistant, pb.text(18, "anthropic")) |> should.be_true
  list.contains(result, pb.text(7, "call-one")) |> should.be_true
  list.contains(result, pb.text(3, "found")) |> should.be_true
  gateway.validate(request, [
    models.Model("devin/swe-1-7", "swe-1-7", 64_000, False),
  ])
  |> should.be_error
  gateway.validate(
    c.Request(
      ..request,
      body: string.replace(value, ",\"signature\":\"CAQSsynthetic\"", ""),
    ),
    models.baseline(),
  )
  |> should.be_error
}

pub fn unknown_model_blocks_or_url_fail_before_runtime_and_credentials_test() {
  use directory, one, two <- with_servers(http(qualified_native(), False), True)
  let engine = engine(directory, one, two)
  list.each(["document", "audio", "redacted_thinking"], fn(kind) {
    let value =
      "{\"model\":\"devin/swe-1-7\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\""
      <> kind
      <> "\",\"data\":\"synthetic\"}]}]}"
    gateway.execute(engine, None, request(c.Buffered, value))
    |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  })
  let value =
    "{\"model\":\"devin/swe-1-7\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"url\",\"url\":\"https://invalid.example/image\"}}]}]}"
  gateway.execute(engine, None, request(c.Buffered, value))
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  runtime.stop(engine) |> should.be_ok
  gateway.open(
    engine,
    None,
    c.Request(..request(c.Streaming, body(True)), model: "devin/unknown"),
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  counts(one).0 |> should.equal(0)
  counts(two).0 |> should.equal(0)
}
