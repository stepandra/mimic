import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/chat/stream as shared
import mimic/protocol/responses/http.{Cancel}
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/chat
import mimic/providers/devin/chat_gateway
import mimic/providers/devin/client
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/response
import mimic/providers/registry
import mimic/providers/runtime

// F23-only SYNTHETIC protobuf, projections and numeric-loopback sockets.
// These are not captured CPA/provider/native-client responses.
type Server

@external(erlang, "mimic_devin_chat_projection_test_ffi", "with_servers")
fn with_servers(
  response: BitArray,
  close_after: Bool,
  run: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_chat_projection_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_devin_chat_projection_test_ffi", "counts")
fn counts(server: Server) -> #(Int, Int, Int)

fn state() -> chat.State {
  let assert Ok(state) =
    chat.new("chatcmpl-synthetic-f23", "devin/swe-1-7", 123)
  state
}

fn encode(events: List(response.Event)) -> #(chat.State, List(String)) {
  list.fold(events, #(state(), []), fn(acc, event) {
    let assert Ok(#(state, frames)) = chat.encode(acc.0, event)
    #(state, list.append(acc.1, frames))
  })
}

fn received(frames: List(String)) -> #(shared.Stream, List(shared.Event)) {
  let batch =
    shared.feed_partial(
      shared.new_with_limits(16_777_216, 1, 128),
      bit_array.from_string(string.concat(frames)),
      Ok,
    )
  let assert Ok(state) = batch.next
  #(state, batch.events)
}

fn documents(frames: List(String)) -> List(ir.Value) {
  received(frames).1
  |> list.filter_map(fn(event) {
    case event {
      shared.Event(document) -> Ok(document)
      _ -> Error(Nil)
    }
  })
}

fn deltas(frames: List(String)) -> List(ir.Value) {
  documents(frames)
  |> list.flat_map(fn(document) {
    let assert Some(ir.Array(choices)) = ir.field(document, "choices")
    list.map(choices, fn(choice) {
      let assert Some(delta) = ir.field(choice, "delta")
      delta
    })
  })
}

fn tool(id: String, name: String, arguments: BitArray) -> response.Event {
  response.Tool(response.ToolDelta(id, name, arguments, <<>>, "", False))
}

pub fn default_registration_never_advertises_stream_test() {
  list.each(bridge.models(), fn(model) {
    list.contains(model.capabilities, c.Stream) |> should.be_false
  })
  let assert Ok(registered) = chat_gateway.registration("devin/swe-1-7")
  registered.protocols |> should.equal(["openai-chat"])
  list.contains(registered.capabilities, c.Stream) |> should.be_true
  chat_gateway.registration("devin/unknown") |> should.be_error
}

pub fn validated_native_text_reasoning_binary_signatures_test() {
  let native =
    bit_array.concat([
      connect.envelope(
        pb.encode([
          pb.Bytes(3, <<"pre":utf8, 226>>),
          pb.text(9, "think"),
          pb.Bytes(10, <<255, 0>>),
          pb.text(21, "synthetic-signature-type"),
        ]),
      ),
      connect.envelope(pb.encode([pb.Bytes(3, <<130, 172>>), pb.Varint(5, 2)])),
      eos(),
    ])
  let #(decoder, events, error) = response.feed_prefix(response.new(), native)
  error |> should.equal(None)
  response.finish(decoder) |> should.be_ok
  let #(state, frames) = encode(events)
  let deltas = deltas(frames)
  list.filter_map(deltas, fn(delta) { ir.string_field(delta, "content") })
  |> string.concat
  |> should.equal("pre€")
  list.any(deltas, fn(delta) {
    ir.field(delta, "reasoning_content") == Some(ir.String("think"))
  })
  |> should.be_true
  list.any(deltas, fn(delta) {
    ir.field(delta, "devin_signature_delta") == Some(ir.String("/wA"))
    && ir.field(delta, "devin_signature_encoding") == Some(ir.String("base64"))
  })
  |> should.be_true
  list.any(deltas, fn(delta) {
    ir.field(delta, "devin_stop_reason") == Some(ir.Integer(2))
  })
  |> should.be_true
  shared.finish(received(frames).0) |> should.equal(Ok(shared.Completed))
  chat.encode(state, response.Stop) |> should.be_error
}

pub fn tool_arguments_split_utf8_names_and_interleaving_test() {
  let #(_, frames) =
    encode([
      tool("one", "", <<"{\"x\":\"":utf8, 226>>),
      response.Text("between"),
      tool("two", "second", <<"{ \"b\": 2 }":utf8>>),
      tool("one", "first", <<130, 172, "\"}":utf8>>),
      response.Reason(10),
      response.Stop,
    ])
  let calls =
    deltas(frames)
    |> list.flat_map(fn(delta) {
      case ir.field(delta, "tool_calls") {
        Some(ir.Array(calls)) -> calls
        _ -> []
      }
    })
  let assert [second, first] = calls
  ir.field(second, "index") |> should.equal(Some(ir.Integer(1)))
  ir.field(first, "index") |> should.equal(Some(ir.Integer(0)))
  let assert Some(function) = ir.field(first, "function")
  ir.field(function, "arguments")
  |> should.equal(Some(ir.String("{\"x\":\"€\"}")))
  let assert Some(function) = ir.field(second, "function")
  ir.field(function, "arguments")
  |> should.equal(Some(ir.String("{ \"b\": 2 }")))
  shared.finish(received(frames).0) |> should.equal(Ok(shared.Completed))
}

pub fn usage_preserves_partial_estimated_and_native_metadata_test() {
  let #(_, frames) =
    encode([
      response.Usage(
        ir.Usage(0, 7, [
          #("devin_input_known", ir.Boolean(False)),
          #("devin_usage_source", ir.String("dimension_estimate")),
          #("cached_input_tokens", ir.Integer(3)),
        ]),
      ),
      response.Stop,
    ])
  let usage =
    documents(frames)
    |> list.filter_map(fn(document) { ir.required(document, "usage") })
  let assert [usage] = usage
  ir.field(usage, "prompt_tokens") |> should.equal(None)
  ir.field(usage, "total_tokens") |> should.equal(None)
  ir.field(usage, "completion_tokens") |> should.equal(Some(ir.Integer(7)))
  ir.field(usage, "devin_usage_partial") |> should.equal(Some(ir.Boolean(True)))
  ir.field(usage, "devin_usage_source")
  |> should.equal(Some(ir.String("dimension_estimate")))
  let assert Some(native) = ir.field(usage, "devin_usage")
  ir.field(native, "cached_input_tokens") |> should.equal(Some(ir.Integer(3)))
  let #(_, frames) =
    encode([
      response.Usage(
        ir.Usage(8, 2, [
          #("cache_write_tokens", ir.Integer(4)),
          #("devin_status_code", ir.Integer(200)),
          #("devin_request_id", ir.String("synthetic-request")),
          #("devin_model", ir.String("native-uid")),
        ]),
      ),
      response.Stop,
    ])
  let assert [usage] =
    documents(frames)
    |> list.filter_map(fn(document) { ir.required(document, "usage") })
  ir.field(usage, "total_tokens") |> should.equal(Some(ir.Integer(10)))
  ir.field(usage, "devin_usage_partial")
  |> should.equal(Some(ir.Boolean(False)))
  ir.field(usage, "devin_usage_source")
  |> should.equal(Some(ir.String("native_accounting")))
}

fn metric(key: String, count: Float) -> pb.Field {
  pb.Bytes(
    2,
    pb.encode([
      pb.text(5, key),
      pb.Bytes(4, pb.encode([pb.Fixed32(2, <<count:float-32-little>>)])),
    ]),
  )
}

pub fn validated_native_usage_estimates_never_become_exact_zeroes_test() {
  let native =
    bit_array.concat([
      data([
        pb.Bytes(
          28,
          pb.encode([
            pb.text(1, "Token Usage"),
            metric("output_tokens", 7.0),
            metric("cached_input_tokens", 3.0),
          ]),
        ),
      ]),
      data([
        pb.Bytes(
          7,
          pb.encode([
            pb.Varint(2, 8),
            pb.Varint(4, 4),
            pb.Varint(6, 200),
          ]),
        ),
      ]),
      eos(),
    ])
  let #(decoder, events, error) = response.feed_prefix(response.new(), native)
  error |> should.equal(None)
  response.finish(decoder) |> should.be_ok
  let #(_, frames) = encode(events)
  let assert [estimate, accounting] =
    documents(frames)
    |> list.filter_map(fn(document) { ir.required(document, "usage") })
  ir.field(estimate, "prompt_tokens") |> should.equal(None)
  ir.field(estimate, "completion_tokens") |> should.equal(Some(ir.Integer(7)))
  ir.field(estimate, "total_tokens") |> should.equal(None)
  ir.field(estimate, "devin_usage_source")
  |> should.equal(Some(ir.String("dimension_estimate")))
  ir.field(accounting, "prompt_tokens") |> should.equal(Some(ir.Integer(8)))
  ir.field(accounting, "completion_tokens") |> should.equal(None)
  ir.field(accounting, "total_tokens") |> should.equal(None)
  ir.field(accounting, "devin_usage_source")
  |> should.equal(Some(ir.String("native_accounting")))
  ir.field(accounting, "devin_usage_partial")
  |> should.equal(Some(ir.Boolean(True)))
}

pub fn reasons_preserve_incomplete_filtered_and_tool_termination_test() {
  list.each(
    [
      #(1, "length"),
      #(3, "length"),
      #(2, "stop"),
      #(4, "stop"),
      #(11, "content_filter"),
    ],
    fn(pair) {
      let #(_, frames) =
        encode([response.Text("prefix"), response.Reason(pair.0), response.Stop])
      let finish =
        documents(frames)
        |> list.flat_map(fn(document) {
          let assert Some(ir.Array(choices)) = ir.field(document, "choices")
          list.filter_map(choices, fn(choice) {
            ir.string_field(choice, "finish_reason")
          })
        })
      finish |> should.equal([pair.1])
      let expected = case pair.1 {
        "stop" -> shared.Completed
        _ -> shared.Incomplete
      }
      shared.finish(received(frames).0) |> should.equal(Ok(expected))
    },
  )
  let assert Ok(#(state, _)) = chat.encode(state(), response.Reason(10))
  chat.encode(state, response.Stop) |> should.be_error
  chat.encode(state, response.Reason(2)) |> should.be_error
}

pub fn unsupported_semantics_and_incomplete_tools_reject_test() {
  chat.encode(
    state(),
    response.Tool(response.ToolDelta("one", "custom", <<>>, <<>>, "", True)),
  )
  |> should.be_error
  chat.encode(
    state(),
    response.Tool(response.ToolDelta(
      "one",
      "invalid",
      <<>>,
      <<255>>,
      "synthetic",
      False,
    )),
  )
  |> should.be_error
  chat.encode(
    state(),
    response.Usage(ir.Usage(1, 1, [#("unknown", ir.Integer(3))])),
  )
  |> should.be_error
  list.each([<<"{":utf8>>, <<"{\"x\":\"":utf8, 255>>, <<>>], fn(arguments) {
    let assert Ok(#(state, _)) =
      chat.encode(state(), tool("one", "f", arguments))
    chat.encode(state, response.Stop) |> should.be_error
  })
  let assert Ok(#(state, _)) =
    chat.encode(state(), tool("one", "f", <<"{}":utf8>>))
  chat.encode(state, tool("one", "different", <<>>)) |> should.be_error
}

fn data(fields: List(pb.Field)) -> BitArray {
  connect.envelope(pb.encode(fields))
}

fn eos() -> BitArray {
  <<2, 2:32-big, "{}":utf8>>
}

fn http(body: BitArray, incomplete: Int) -> BitArray {
  case incomplete {
    0 -> {
      let headers =
        "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: "
        <> int.to_string(bit_array.byte_size(body))
        <> "\r\n\r\n"
      <<headers:utf8, body:bits>>
    }
    _ -> {
      // Fixed-length egress reads an exact body block before returning it.
      // Chunked fixtures expose a validated prefix before their framing fails
      // or while the peer remains open waiting for actual cancellation EOF.
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

fn engine(directory: String, one: Server, two: Server) -> runtime.Runtime {
  let assert Ok(store) = storage.new(directory)
  let accounts =
    list.map([#("one", one), #("two", two)], fn(pair) {
      let assert Ok(_) =
        runtime_store.save(
          store,
          credentials.key("devin", "session_token", pair.0),
          c.SessionToken("synthetic-f23-token-" <> pair.0, []),
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
  let assert Ok(model) = chat_gateway.registration("devin/swe-1-7")
  let assert Ok(registry) = registry.new([model])
  let assert Ok(engine) = runtime.start(store, registry, accounts)
  engine
}

fn open(engine: runtime.Runtime) -> client.Client(chat.State) {
  let request =
    c.Request(
      "devin",
      "session_token",
      "devin/swe-1-7",
      "openai-chat",
      "generate",
      c.Streaming,
      [c.Stream],
      "synthetic-f23-client",
      None,
      "{\"model\":\"devin/swe-1-7\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic hello\"}]}",
    )
  let assert Ok(#("one", client)) = chat_gateway.open(engine, None, request)
  client
}

fn collect(
  client: client.Client(chat.State),
  frames: List(String),
) -> #(client.Batch(chat.State), List(String)) {
  let batch = client.next(client)
  let frames = list.append(frames, batch.frames)
  case batch.done {
    True -> #(batch, frames)
    False -> collect(batch.client, frames)
  }
}

fn assert_once(engine: runtime.Runtime, one: Server, two: Server) {
  runtime.active_leases(engine) |> should.equal(Ok(0))
  counts(one).0 |> should.equal(1)
  counts(one).1 |> should.equal(1)
  counts(two).0 |> should.equal(0)
  runtime.stop(engine) |> should.be_ok
}

pub fn socket_success_requires_eos_and_clean_eof_once_test() {
  use directory, one, two <- with_servers(
    http(<<{ data([pb.text(3, "once")]) }:bits, { eos() }:bits>>, 0),
    True,
  )
  let engine = engine(directory, one, two)
  let prefix = client.next(open(engine))
  prefix.done |> should.be_false
  string.contains(string.concat(prefix.frames), "[DONE]") |> should.be_false
  let #(batch, frames) = collect(prefix.client, prefix.frames)
  batch.error |> should.equal(None)
  string.concat(frames)
  |> string.split("[DONE]")
  |> list.length
  |> should.equal(2)
  shared.finish(received(frames).0) |> should.equal(Ok(shared.Completed))
  client.next(batch.client).frames |> should.equal([])
  assert_once(engine, one, two)
}

fn failure_case(suffix: BitArray, extra: Int) {
  use directory, one, two <- with_servers(
    http(<<{ data([pb.text(3, "prefix")]) }:bits, suffix:bits>>, extra),
    True,
  )
  let engine = engine(directory, one, two)
  let #(batch, frames) = collect(open(engine), [])
  batch.error
  |> should.equal(Some(c.Failure(c.InvalidResponse, c.Started, None)))
  let frames =
    list.append(frames, [
      chat.failure(c.Failure(c.InvalidResponse, c.Started, None)),
    ])
  let wire = string.concat(frames)
  string.split(wire, "\"content\":\"prefix\"") |> list.length |> should.equal(2)
  string.contains(wire, "[DONE]") |> should.be_false
  string.contains(wire, "\"finish_reason\":\"") |> should.be_false
  shared.finish(received(frames).0) |> should.equal(Ok(shared.RemoteError))
  client.next(batch.client).frames |> should.equal([])
  client.next(batch.client).error |> should.equal(None)
  assert_once(engine, one, two)
}

pub fn socket_prefix_then_error_trailer_never_done_or_replay_test() {
  let trailer =
    bit_array.from_string(
      "{\"error\":{\"code\":\"unauthenticated\",\"message\":\"synthetic-private\"}}",
    )
  failure_case(<<2, { bit_array.byte_size(trailer) }:32-big, trailer:bits>>, 0)
}

pub fn socket_malformed_trailer_test() {
  failure_case(<<2, 1:32-big, "{":utf8>>, 0)
}

pub fn socket_truncated_connect_trailer_test() {
  failure_case(<<2, 2:32-big, "{":utf8>>, 0)
}

pub fn socket_unsupported_native_semantic_field_test() {
  failure_case(data([pb.Bytes(99, <<0>>)]), 0)
}

pub fn socket_missing_eos_test() {
  failure_case(<<>>, 0)
}

pub fn socket_eos_followed_data_test() {
  failure_case(<<{ eos() }:bits, 0>>, 0)
}

pub fn socket_truncated_http_after_valid_eos_test() {
  failure_case(eos(), 1)
}

fn await_peer_eof(server: Server, attempts: Int) -> Nil {
  case counts(server).2 > 0 {
    True -> Nil
    False if attempts > 0 -> {
      process.sleep(10)
      await_peer_eof(server, attempts - 1)
    }
    False -> counts(server).2 |> should.equal(1)
  }
}

pub fn socket_projection_error_preserves_prefix_and_cancels_test() {
  let custom =
    pb.encode([pb.text(1, "one"), pb.text(2, "custom"), pb.Varint(6, 1)])
  let body = <<
    { data([pb.text(3, "prefix")]) }:bits,
    { data([pb.Bytes(6, custom)]) }:bits,
  >>
  use directory, one, two <- with_servers(http(body, 100), False)
  let engine = engine(directory, one, two)
  let #(batch, frames) = collect(open(engine), [])
  batch.error |> should.equal(Some(c.Failure(c.Unsupported, c.Started, None)))
  string.contains(string.concat(frames), "\"content\":\"prefix\"")
  |> should.be_true
  string.contains(string.concat(frames), "[DONE]") |> should.be_false
  await_peer_eof(one, 100)
  assert_once(engine, one, two)
}

pub fn socket_client_cancel_releases_lease_test() {
  use directory, one, two <- with_servers(
    http(data([pb.text(3, "prefix")]), 100),
    False,
  )
  let engine = engine(directory, one, two)
  let opened = open(engine)
  client.run(opened, fn(_) { Ok(Cancel) }) |> should.equal(Ok(client.Cancelled))
  client.cancel(opened)
  await_peer_eof(one, 100)
  assert_once(engine, one, two)
}

pub fn socket_downstream_disconnect_releases_lease_test() {
  use directory, one, two <- with_servers(
    http(data([pb.text(3, "prefix")]), 100),
    False,
  )
  let engine = engine(directory, one, two)
  client.run(open(engine), fn(_) { Error("synthetic downstream closed") })
  |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
  await_peer_eof(one, 100)
  assert_once(engine, one, two)
}

pub fn socket_synchronous_adoption_revokes_original_owner_test() {
  use directory, one, two <- with_servers(
    http(data([pb.text(3, "prefix")]), 100),
    False,
  )
  let engine = engine(directory, one, two)
  let opened = open(engine)
  let ready = process.new_subject()
  let finished = process.new_subject()
  let _sender =
    process.spawn_unlinked(fn() {
      let gate = process.new_subject()
      let adopted = client.adopt(opened)
      process.send(ready, #(adopted, gate))
      let assert Ok(Nil) = process.receive(gate, 3000)
      let outcome = client.run(opened, fn(_) { Ok(Cancel) })
      process.send(finished, outcome)
    })
  let assert Ok(#(adopted, gate)) = process.receive(ready, 3000)
  adopted |> should.equal(Ok(Nil))
  let revoked = client.next(opened)
  revoked.frames |> should.equal([])
  revoked.error |> should.equal(Some(c.Failure(c.Cancelled, c.Started, None)))
  runtime.active_leases(engine) |> should.equal(Ok(1))
  process.send(gate, Nil)
  process.receive(finished, 3000) |> should.equal(Ok(Ok(client.Cancelled)))
  await_peer_eof(one, 100)
  assert_once(engine, one, two)
}
