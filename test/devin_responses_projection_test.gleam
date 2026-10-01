/// F25 dedicated SYNTHETIC provider tests. No source fixture is a captured
/// native SDK/live response, and these are not substitutes for actual root CLI.
import devin_responses_oracle as oracle
import devin_responses_schema as sdk_shape
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
import mimic/protocol/responses/http.{Cancel, Continue}
import mimic/protocol/responses/stream as strict
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/catalog
import mimic/providers/devin/catalog_gateway
import mimic/providers/devin/client
import mimic/providers/devin/configuration
import mimic/providers/devin/connect
import mimic/providers/devin/models
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/response
import mimic/providers/devin/responses
import mimic/providers/devin/responses_delivery as delivery
import mimic/providers/devin/responses_gateway as gateway
import mimic/providers/devin/responses_request as input
import mimic/providers/devin/responses_stream as projection
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{Header}

pub type Server

@external(erlang, "mimic_devin_f25_responses_test_ffi", "with_servers")
fn with_servers(
  first: BitArray,
  second: BitArray,
  hold: Bool,
  inspect: fn(String, BitArray) -> Bool,
  run: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_f25_responses_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_devin_f25_responses_test_ffi", "counts")
fn counts(server: Server) -> #(Int, Int, Int, Int)

@external(erlang, "mimic_devin_f25_responses_test_ffi", "finally")
fn finally(run: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "mimic_devin_f25_responses_test_ffi", "focused")
fn focused() -> Bool

type Unit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn now(unit: Unit) -> Int

pub fn main() {
  let assert True = focused()
  Nil
}

fn data(fields: List(pb.Field)) -> BitArray {
  connect.envelope(pb.encode(fields))
}

fn eos() -> BitArray {
  <<2, 2:32-big, "{}":utf8>>
}

fn accounting() -> pb.Field {
  pb.message(7, [pb.Varint(2, 8), pb.Varint(3, 5), pb.Varint(5, 3)])
}

fn tool(id: String, name: String, args: BitArray) -> response.Event {
  response.Tool(response.ToolDelta(id, name, args, <<>>, "", False))
}

fn native_tool(id: String, name: String, args: BitArray) -> pb.Field {
  pb.message(6, [pb.text(1, id), pb.text(2, name), pb.Bytes(3, args)])
}

fn encrypted() -> String {
  // SYNTHETIC transport shape, not a valid/decryptable upstream signature.
  <<128, 0:64, 0:128, 0:128, 0:256>> |> bit_array.base64_url_encode(True)
}

fn fixture() -> BitArray {
  <<
    { data([pb.text(9, "synthetic reasoning")]) }:bits,
    { data([native_tool("first", "", <<"{\"x\":\"":utf8, 226>>)]) }:bits,
    { data([pb.text(3, "A")]) }:bits,
    { data([native_tool("second", "two", <<"{}":utf8>>)]) }:bits,
    { data([pb.text(3, "B")]) }:bits,
    { data([native_tool("first", "one", <<130, 172, "\"}":utf8>>)]) }:bits,
    { data([pb.text(3, "C")]) }:bits,
    { data([pb.text(10, encrypted()), pb.text(21, "openai")]) }:bits,
    { data([accounting(), pb.Varint(5, 10)]) }:bits,
    { eos() }:bits,
  >>
}

fn encode(events: List(response.Event)) {
  let assert Ok(state) =
    projection.new("resp_synthetic_f25", "devin/f25-alias", 42, settings())
  list.try_fold(events, #(state, []), fn(acc, event) {
    use #(state, frames) <- result.try(projection.encode(acc.0, event))
    Ok(#(state, list.append(acc.1, frames)))
  })
}

fn parity(bytes: BitArray) -> List(String) {
  let assert Ok(projected) =
    responses.buffered(
      bytes,
      "resp_synthetic_f25",
      "devin/f25-alias",
      42,
      settings(),
    )
  let assert Ok(#(decoder, events)) = response.feed(response.new(), bytes)
  response.finish(decoder) |> should.be_ok
  let assert Ok(#(last, frames)) = encode(events)
  frames |> should.equal(responses.frames(projected))
  let assert Ok(expected) = ir.parse(responses.json(projected))
  oracle.reconstruct(frames) |> should.equal(Ok(expected))
  projection.encode(last, response.Stop) |> should.be_error
  ir.field(responses.document(projected), "choices") |> should.equal(None)
  frames
}

fn expected_json(value: ir.Value) -> ir.Value {
  // Object field-list order is not JSON semantics. Parse only the expectation;
  // retain every field/value and preserve array/item/content order exactly.
  let assert Ok(decoded) = ir.parse(ir.stringify(value))
  decoded
}

pub fn json_sse_exact_construction_interleaved_tools_delayed_names_split_utf8_test() {
  let assert Ok(document) = oracle.reconstruct(parity(fixture()))
  let assert Some(ir.Array([thought, first, a, second, bc])) =
    ir.field(document, "output")
  ir.field(thought, "encrypted_content")
  |> should.equal(Some(ir.String(encrypted())))
  ir.field(first, "call_id") |> should.equal(Some(ir.String("first")))
  ir.field(first, "arguments") |> should.equal(Some(ir.String("{\"x\":\"€\"}")))
  ir.field(second, "call_id") |> should.equal(Some(ir.String("second")))
  ir.field(bc, "content")
  |> should.equal(
    Some(
      expected_json(
        ir.Array([
          ir.Object([
            #("type", ir.String("output_text")),
            #("text", ir.String("BC")),
            #("annotations", ir.Array([])),
          ]),
        ]),
      ),
    ),
  )
  ir.field(a, "id") |> should.not_equal(ir.field(first, "id"))
  ir.field(first, "id") |> should.not_equal(ir.field(first, "call_id"))
}

pub fn all_native_byte_splits_produce_same_json_and_sse_test() {
  let bytes = fixture()
  let expected = parity(bytes)
  list.each(
    list.index_map(list.repeat(Nil, bit_array.byte_size(bytes) + 1), fn(_, i) {
      i
    }),
    fn(index) {
      let assert Ok(prefix) = bit_array.slice(bytes, 0, index)
      let assert Ok(suffix) =
        bit_array.slice(bytes, index, bit_array.byte_size(bytes) - index)
      let assert Ok(#(decoder, first)) = response.feed(response.new(), prefix)
      let assert Ok(#(decoder, second)) = response.feed(decoder, suffix)
      response.finish(decoder) |> should.be_ok
      let assert Ok(#(_, frames)) = encode(list.append(first, second))
      frames |> should.equal(expected)
    },
  )
}

pub fn native_exact_zero_partial_snapshot_merge_and_unsigned_reasoning_test() {
  let bytes = <<
    { data([pb.text(9, "unsigned summary"), pb.message(7, [pb.Varint(3, 0)])]) }:bits,
    { data([pb.message(7, [pb.Varint(2, 0)]), pb.Varint(5, 2)]) }:bits,
    { eos() }:bits,
  >>
  let assert Ok(document) = oracle.reconstruct(parity(bytes))
  let assert Some(usage) = ir.field(document, "usage")
  ir.field(usage, "total_tokens") |> should.equal(Some(ir.Integer(0)))
  let assert Ok(#(_, frames)) =
    encode([
      response.Text("not complete"),
      response.Usage(ir.Usage(8, 5, [])),
    ])
  frames |> should.equal([])
}

pub fn terminal_stop_reasons_completed_length_filter_and_missing_reason_test() {
  list.each([1, 2, 3, 4, 11], fn(reason) {
    let bytes = <<
      { data([pb.text(3, "answer"), accounting(), pb.Varint(5, reason)]) }:bits,
      { eos() }:bits,
    >>
    let assert Ok(document) = oracle.reconstruct(parity(bytes))
    let expected = case reason {
      1 | 3 | 11 -> "incomplete"
      _ -> "completed"
    }
    ir.field(document, "status") |> should.equal(Some(ir.String(expected)))
  })
  responses.buffered(
    <<{ data([accounting()]) }:bits, { eos() }:bits>>,
    "id",
    "m",
    1,
    settings(),
  )
  |> should.be_error
  encode([
    response.Usage(ir.Usage(1, 1, [])),
    response.Reason(10),
    response.Stop,
  ])
  |> should.be_error
}

pub fn missing_partial_estimated_negative_accounting_is_not_fabricated_test() {
  list.each(
    [
      [response.Text("x"), response.Reason(2), response.Stop],
      [
        response.Usage(
          ir.Usage(0, 1, [#("devin_input_known", ir.Boolean(False))]),
        ),
        response.Reason(2),
        response.Stop,
      ],
      [
        response.Usage(
          ir.Usage(1, 1, [
            #("devin_usage_source", ir.String("dimension_estimate")),
          ]),
        ),
        response.Reason(2),
        response.Stop,
      ],
      [response.Usage(ir.Usage(-1, 1, [])), response.Reason(2), response.Stop],
    ],
    fn(events) { encode(events) |> should.be_error },
  )
}

pub fn invalid_custom_incomplete_conflicting_tools_and_reasoning_are_unsupported_test() {
  let tail = [
    response.Usage(ir.Usage(1, 1, [])),
    response.Reason(2),
    response.Stop,
  ]
  list.each([<<>>, <<"{":utf8>>, <<"[1]":utf8>>, <<255>>], fn(args) {
    encode([tool("call", "run", args), ..tail]) |> should.be_error
  })
  encode([tool("call", "", <<"{}":utf8>>), ..tail]) |> should.be_error
  encode([tool("call", "a", <<"{}":utf8>>), tool("call", "b", <<>>)])
  |> should.be_error
  encode([
    response.Tool(response.ToolDelta("call", "run", <<>>, <<>>, "", True)),
  ])
  |> should.be_error
  list.each(["anthropic", "sealed", "unknown"], fn(kind) {
    encode([response.ThinkingDelta("x"), response.SignatureType(kind)])
    |> should.be_error
  })
  encode([
    response.ThinkingDelta("one"),
    response.Text("x"),
    response.ThinkingDelta("two"),
  ])
  |> should.be_error
  encode([
    response.SignatureDelta(bit_array.from_string(encrypted())),
    response.SignatureType("openai"),
    ..tail
  ])
  |> should.be_error
  input.qualify_encrypted(<<"gAAAAsynthetic":utf8>>, "openai")
  |> should.be_error
}

pub fn common_byte_event_item_tool_and_argument_depth_limits_test() {
  let assert Ok(builder) = responses.new("id", "m", 1, settings())
  let assert Ok(full) =
    list.try_fold(
      list.repeat(response.Text(""), responses.max_events),
      builder,
      responses.push,
    )
  responses.push(full, response.Stop) |> should.be_error
  responses.push(
    builder,
    response.Text(string.repeat("x", responses.max_bytes + 1)),
  )
  |> should.be_error
  let tail = [
    response.Usage(ir.Usage(1, 1, [])),
    response.Reason(2),
    response.Stop,
  ]
  encode([
    response.Text(string.repeat("x", responses.max_response_bytes)),
    ..tail
  ])
  |> should.be_error
  let tools =
    list.index_map(list.repeat(Nil, 129), fn(_, i) {
      tool(int.to_string(i), "run", <<"{}":utf8>>)
    })
  encode(tools) |> should.be_error
  let items =
    list.index_map(list.repeat(Nil, 128), fn(_, i) {
      [tool(int.to_string(i), "run", <<"{}":utf8>>), response.Text("a")]
    })
    |> list.flatten
  encode(items) |> should.be_ok
  encode([response.ThinkingDelta("b"), ..items]) |> should.be_error
  list.each([128, 129], fn(depth) {
    let args =
      string.repeat("{\"x\":", depth) <> "0" <> string.repeat("}", depth)
    let result =
      encode([tool("deep", "run", bit_array.from_string(args)), ..tail])
    case depth {
      128 -> {
        let _ = result |> should.be_ok
        Nil
      }
      _ -> {
        let _ = result |> should.be_error
        Nil
      }
    }
  })
}

pub fn strict_s6_raw_tool_identity_rejects_conflicting_name_after_projection_test() {
  let frames = parity(fixture())
  let changed =
    list.map(frames, fn(frame) {
      case string.contains(frame, "response.function_call_arguments.done") {
        True -> string.replace(frame, "\"name\":\"one\"", "\"name\":\"other\"")
        False -> frame
      }
    })
  oracle.reconstruct(changed) |> should.be_error
}

fn model_catalog() -> catalog.Catalog {
  let assert Ok(value) =
    catalog.new([
      catalog.Entry(models.Model("devin/f25", "f25-native", 2048, True), [
        "devin/f25-alias",
      ]),
      catalog.Entry(
        models.Model("devin/f25-other", "f25-other-native", 1024, False),
        [],
      ),
    ])
  value
}

fn configured(one: String, two: String) -> configuration.Configured {
  let assert Ok(value) =
    configuration.new(model_catalog(), [
      configuration.Account("one", one, ["devin/f25-alias"]),
      configuration.Account("two", two, ["devin/f25-alias", "devin/f25-other"]),
    ])
  value
}

fn body(stream: Bool) -> String {
  "{\"model\":\"devin/f25-alias\",\"max_output_tokens\":32,\"stream\":"
  <> case stream {
    True -> "true"
    False -> "false"
  }
  <> ",\"input\":\"synthetic hello\",\"tools\":"
  <> ir.stringify(definitions())
  <> "}"
}

fn definitions() -> ir.Value {
  ir.Array(
    list.map(["one", "two", "run", "lookup"], fn(name) {
      ir.Object([
        #("type", ir.String("function")),
        #("name", ir.String(name)),
        #("parameters", ir.Object([#("type", ir.String("object"))])),
        #("strict", ir.Boolean(False)),
      ])
    }),
  )
}

fn settings() -> input.Settings {
  let assert Ok(settings) = input.settings(body(False))
  settings
}

fn request(mode: c.Mode) -> c.Request {
  c.Request(
    "devin",
    "session_token",
    "devin/f25-alias",
    "openai-responses",
    "generate",
    mode,
    [],
    "synthetic-f25-tenant",
    None,
    body(mode == c.Streaming),
  )
}

pub fn capability_addition_does_not_grant_compact_ws_continuation_or_other_inputs_test() {
  let cfg = configured("http://127.0.0.1:1", "http://127.0.0.1:2")
  let assert Ok(row) = catalog_gateway.registration(cfg, "devin/f25-alias")
  row.capabilities |> should.equal([c.Stream, c.Buffer, c.Tools, c.Images])
  list.each([c.Continuation, c.WebSocket, c.Audio], fn(cap) {
    catalog_gateway.validate(
      cfg,
      c.Request(..request(c.Buffered), required: [cap]),
    )
    |> should.be_error
  })
  list.each(["compact", "responses/compact", "count"], fn(operation) {
    catalog_gateway.validate(
      cfg,
      c.Request(..request(c.Buffered), operation: operation),
    )
    |> should.be_error
  })
  list.each(
    ["openai-chat", "anthropic-messages", "responses", "responses/lite"],
    fn(protocol) {
      catalog_gateway.validate(
        cfg,
        c.Request(..request(c.Buffered), protocol: protocol),
      )
      |> should.be_error
    },
  )
  catalog_gateway.validate(cfg, request(c.Buffered)) |> should.be_ok
}

pub fn native_request_mapping_is_responses_not_chat_and_full_tool_pairing_is_local_test() {
  let value =
    "{\"model\":\"devin/f25-alias\",\"instructions\":\"system\",\"max_output_tokens\":32,\"input\":["
    <> "{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aGk=\"}]},"
    <> "{\"type\":\"function_call\",\"call_id\":\"history-call\",\"name\":\"lookup\",\"arguments\":\"{\\\"x\\\":1}\"},"
    <> "{\"type\":\"function_call_output\",\"call_id\":\"history-call\",\"output\":\"result\"},"
    <> "{\"role\":\"user\",\"content\":\"next\"}],\"tools\":[{\"type\":\"function\",\"name\":\"lookup\",\"parameters\":{\"type\":\"object\"},\"strict\":false}]}"
  let req = c.Request(..request(c.Buffered), body: value)
  gateway.validate(req, catalog.mappings(model_catalog())) |> should.be_ok
  input.decode(value) |> should.be_ok
  let assert Ok(bytes) = mimic_native(value)
  let assert <<0, _:32, protobuf:bits>> = bytes
  let assert Ok(fields) = pb.decode(protobuf)
  list.contains(fields, pb.text(2, "system")) |> should.be_true
  list.contains(fields, pb.text(21, "f25-native")) |> should.be_true
  let prompts =
    list.filter_map(fields, fn(field) {
      case field {
        pb.Bytes(3, bytes) -> pb.decode(bytes)
        _ -> Error("not a prompt")
      }
    })
  list.any(prompts, fn(fields) {
    list.contains(
      fields,
      pb.message(10, [pb.text(1, "aGk="), pb.text(2, "image/png")]),
    )
  })
  |> should.be_true
  list.any(prompts, fn(fields) {
    list.contains(fields, pb.text(7, "history-call"))
  })
  |> should.be_true
  let orphan =
    "{\"model\":\"devin/f25-alias\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"other\",\"output\":\"x\"}]}"
  input.decode(orphan) |> should.be_error
  input.decode(string.replace(
    value,
    "\"call_id\":\"history-call\",\"output\"",
    "\"call_id\":\"other\",\"output\"",
  ))
  |> should.be_error
}

fn mimic_native(source: String) {
  // Use bridge's actual protocol dispatch to avoid another native request mapper.
  let ctx =
    c.Context(
      "devin",
      "session_token",
      "one",
      "http://127.0.0.1:1",
      "synthetic-scope",
      c.SessionToken("synthetic-f25-one", []),
    )
  bridge.prepare_configured(
    ctx,
    c.Request(..request(c.Buffered), body: source),
    catalog.mappings(model_catalog()),
  )
  |> result.map(fn(plan) { plan.body })
}

pub fn preflight_unknown_fields_tokens_models_signed_opaque_refs_or_remote_images_test() {
  let cfg = configured("http://127.0.0.1:1", "http://127.0.0.1:2")
  list.each(
    [
      "{\"previous_response_id\":\"resp_other\"}", "{\"store\":true}",
      "{\"reasoning\":{\"effort\":\"high\"}}",
      "{\"text\":{\"format\":{\"type\":\"json_object\"}}}",
      "{\"input\":[{\"type\":\"item_reference\",\"id\":\"x\"}]}",
      "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"aGk=\",\"format\":\"wav\"}}]}]}",
      "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"https://invalid.example/x\"}]}]}",
      "{\"input\":[{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"sealed.v1.synthetic\"}]}",
    ],
    fn(extra) {
      let assert Ok(ir.Object(fields)) = ir.parse(extra)
      let keys = list.map(fields, fn(f) { f.0 })
      let assert Ok(ir.Object(original)) = ir.parse(body(False))
      let value =
        ir.Object(list.append(
          list.filter(original, fn(f) { !list.contains(keys, f.0) }),
          fields,
        ))
      catalog_gateway.validate(
        cfg,
        c.Request(..request(c.Buffered), body: ir.stringify(value)),
      )
      |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
    },
  )
  list.each([0, -1, 2049], fn(max) {
    gateway.validate(
      c.Request(
        ..request(c.Buffered),
        body: string.replace(body(False), ":32", ":" <> int.to_string(max)),
      ),
      catalog.mappings(model_catalog()),
    )
    |> should.be_error
  })
}

fn origin(server: Server) -> String {
  "http://127.0.0.1:" <> int.to_string(port(server))
}

fn engine(directory: String, one: Server, two: Server) -> runtime.Runtime {
  let assert Ok(store) = storage.new(directory)
  let cfg = configured(origin(one), origin(two))
  let accounts =
    list.map([#("one", one), #("two", two)], fn(pair) {
      let assert Ok(_) =
        runtime_store.save(
          store,
          credentials.key("devin", "session_token", pair.0),
          c.SessionToken("synthetic-f25-" <> pair.0, []),
        )
      runtime.Account(
        "devin",
        "session_token",
        pair.0,
        origin(pair.1),
        fleet.LocalLoopback,
        1,
        case pair.0 {
          "one" -> ["devin/f25-alias"]
          _ -> ["devin/f25-alias", "devin/f25-other"]
        },
        credentials.StaticSession,
      )
    })
  let assert Ok(row) = catalog_gateway.registration(cfg, "devin/f25-alias")
  let assert Ok(other) = catalog_gateway.registration(cfg, "devin/f25-other")
  let assert Ok(registry) = registry.new([row, other])
  let assert Ok(engine) = runtime.start(store, registry, accounts)
  engine
}

fn inspect(header: String, body: BitArray) -> Bool {
  string.contains(
    header,
    "POST /exa.api_server_pb.ApiServerService/GetChatMessage HTTP/1.1",
  )
  && string.contains(header, "application/connect+proto")
  && case body {
    <<0, size:32-big, bytes:bits>> ->
      size == bit_array.byte_size(bytes)
      && case pb.decode(bytes) {
        Ok(fields) -> list.contains(fields, pb.text(21, "f25-native"))
        _ -> False
      }
    _ -> False
  }
}

fn http(bytes: BitArray, truncated: Bool) -> BitArray {
  let size =
    bit_array.byte_size(bytes)
    + case truncated {
      True -> 1
      False -> 0
    }
  <<
    {
      "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: "
      <> int.to_string(size)
      <> "\r\n\r\n"
    }:utf8,
    bytes:bits,
  >>
}

fn collect(opened: client.Client(projection.State), frames: List(String)) {
  let batch = client.next(opened)
  let frames = list.append(frames, batch.frames)
  case batch.done {
    True -> #(batch, frames)
    False -> collect(batch.client, frames)
  }
}

fn await_eof(server: Server, tries: Int) {
  case counts(server).3 > 0 {
    True -> Nil
    False if tries > 0 -> {
      process.sleep(10)
      await_eof(server, tries - 1)
    }
    False -> counts(server).3 |> should.equal(1)
  }
}

pub fn actual_native_socket_json_sse_route_barrier_once_and_cleanup_test() {
  use directory, one, two <- with_servers(
    http(fixture(), False),
    http(fixture(), False),
    False,
    inspect,
  )
  let engine = engine(directory, one, two)
  finally(
    fn() {
      let cfg = configured(origin(one), origin(two))
      let assert Ok(json) =
        catalog_gateway.execute(engine, None, request(c.Buffered), cfg)
      let assert Ok(value) = ir.parse(json)
      ir.field(value, "object") |> should.equal(Some(ir.String("response")))
      let assert Ok(#("one", opened)) =
        catalog_gateway.open_responses(engine, None, request(c.Streaming), cfg)
      let prefix = client.next(opened)
      prefix.frames |> should.equal([])
      let #(batch, frames) = collect(prefix.client, [])
      batch.error |> should.equal(None)
      oracle.reconstruct(frames) |> should.be_ok
      client.next(batch.client).frames |> should.equal([])
      runtime.active_leases(engine) |> should.equal(Ok(0))
      counts(one).2 |> should.equal(2)
      counts(two).0 |> should.equal(0)
      Nil
    },
    fn() {
      let _ = runtime.stop(engine)
      Nil
    },
  )
  Nil
}

pub fn malformed_truncated_nativefail_both_modes_never_succeed_or_failover_test() {
  let error = <<
    "{\"error\":{\"code\":\"unauthenticated\",\"message\":\"synthetic-f25-one\"}}":utf8,
  >>
  list.each(
    [
      #(data([pb.text(3, "prefix")]), False),
      #(<<{ fixture() }:bits, 0>>, False),
      #(fixture(), True),
      #(
        <<
          { data([pb.text(3, "prefix")]) }:bits,
          2,
          { bit_array.byte_size(error) }:32-big,
          error:bits,
        >>,
        False,
      ),
      #(data([pb.Bytes(99, <<0>>)]), False),
    ],
    fn(pair) {
      use directory, one, two <- with_servers(
        http(pair.0, pair.1),
        http(fixture(), False),
        False,
        inspect,
      )
      let engine = engine(directory, one, two)
      finally(
        fn() {
          let cfg = configured(origin(one), origin(two))
          catalog_gateway.execute(engine, None, request(c.Buffered), cfg)
          |> should.be_error
          let assert Ok(#("one", opened)) =
            catalog_gateway.open_responses(
              engine,
              None,
              request(c.Streaming),
              cfg,
            )
          let #(batch, frames) = collect(opened, [])
          frames |> should.equal([])
          batch.error
          |> should.equal(Some(c.Failure(c.InvalidResponse, c.Started, None)))
          counts(two).0 |> should.equal(0)
          runtime.active_leases(engine) |> should.equal(Ok(0))
          Nil
        },
        fn() {
          let _ = runtime.stop(engine)
          Nil
        },
      )
      Nil
    },
  )
}

pub fn quota_failover_preserves_selected_account_catalog_and_credential_test() {
  use directory, one, two <- with_servers(
    <<
      "HTTP/1.1 429 Limited\r\nRetry-After: 1\r\nContent-Length: 0\r\n\r\n":utf8,
    >>,
    http(fixture(), False),
    False,
    fn(header, body) {
      inspect(header, body)
      && case string.contains(header, "synthetic-f25-two-synthetic-f25-two") {
        True -> !string.contains(header, "synthetic-f25-one")
        False -> string.contains(header, "synthetic-f25-one-synthetic-f25-one")
      }
    },
  )
  let engine = engine(directory, one, two)
  finally(
    fn() {
      let cfg = configured(origin(one), origin(two))
      let assert Ok(#("two", opened)) =
        catalog_gateway.open_responses(engine, None, request(c.Streaming), cfg)
      let #(batch, frames) = collect(opened, [])
      batch.error |> should.equal(None)
      oracle.reconstruct(frames) |> should.be_ok
      counts(one).2 |> should.equal(1)
      counts(two).2 |> should.equal(1)
      runtime.active_leases(engine) |> should.equal(Ok(0))
      Nil
    },
    fn() {
      let _ = runtime.stop(engine)
      Nil
    },
  )
  Nil
}

pub fn buffering_explicit_cancel_owner_death_and_deadline_release_socket_and_lease_test() {
  list.each(["cancel", "owner-death", "deadline"], fn(mode) {
    let prefix = data([pb.text(3, "prefix")])
    use directory, one, two <- with_servers(
      <<
        "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n",
        {
          int.to_base_string(bit_array.byte_size(prefix), 16)
          |> result.unwrap("0")
        }:utf8,
        "\r\n",
        prefix:bits,
        "\r\n",
      >>,
      http(fixture(), False),
      True,
      inspect,
    )
    let engine = engine(directory, one, two)
    finally(
      fn() {
        let cfg = configured(origin(one), origin(two))
        let assert Ok(#(_, opened)) =
          gateway.open_with_adapter_until(
            engine,
            request(c.Streaming),
            catalog.mappings(model_catalog()),
            catalog_gateway.adapter(cfg, None),
            now(Millisecond) + 1000,
          )
        let prefix = client.next(opened)
        prefix.frames |> should.equal([])
        case mode {
          "cancel" -> client.cancel(prefix.client)
          "owner-death" -> {
            let ready = process.new_subject()
            let owner =
              process.spawn_unlinked(fn() {
                let adopted = client.adopt(prefix.client)
                process.send(ready, adopted)
                process.sleep(3000)
              })
            process.receive(ready, 1000) |> should.equal(Ok(Ok(Nil)))
            process.kill(owner)
          }
          _ -> {
            let batch = client.next(prefix.client)
            batch.frames |> should.equal([])
            batch.done |> should.be_true
            batch.error |> should.not_equal(None)
          }
        }
        await_eof(one, 200)
        runtime.active_leases(engine) |> should.equal(Ok(0))
        counts(two).0 |> should.equal(0)
        Nil
      },
      fn() {
        let _ = runtime.stop(engine)
        Nil
      },
    )
    Nil
  })
}

pub fn downstream_cancel_and_failure_never_emit_a_later_terminal_test() {
  use directory, one, two <- with_servers(
    http(fixture(), False),
    http(fixture(), False),
    False,
    inspect,
  )
  let engine = engine(directory, one, two)
  finally(
    fn() {
      let cfg = configured(origin(one), origin(two))
      let assert Ok(#(_, opened)) =
        catalog_gateway.open_responses(engine, None, request(c.Streaming), cfg)
      let frames = process.new_subject()
      client.run(opened, fn(frame) {
        process.send(frames, frame)
        Ok(Cancel)
      })
      |> should.equal(Ok(client.Cancelled))
      let assert Ok(frame) = process.receive(frames, 1000)
      let assert Ok(#(observer, _)) =
        strict.feed(strict.new(), bit_array.from_string(frame))
      strict.finish(observer) |> should.be_error
      let assert Ok(#(_, opened)) =
        catalog_gateway.open_responses(engine, None, request(c.Streaming), cfg)
      client.run(opened, fn(_) { Error("synthetic closed") })
      |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
      counts(two).0 |> should.equal(0)
      runtime.active_leases(engine) |> should.equal(Ok(0))
      Nil
    },
    fn() {
      let _ = runtime.stop(engine)
      Nil
    },
  )
  Nil
}

pub fn exact_selected_context_model_account_origin_auth_and_remote_gate_test() {
  let cfg = configured("http://127.0.0.1:1", "http://127.0.0.1:2")
  let context =
    c.Context(
      "devin",
      "session_token",
      "two",
      "http://127.0.0.1:2",
      "synthetic-private-account-scope",
      c.SessionToken("synthetic-f25-two", []),
    )
  let request =
    c.Request(
      ..request(c.Buffered),
      model: "devin/f25-other",
      body: string.replace(body(False), "devin/f25-alias", "devin/f25-other"),
    )
  configuration.selected(cfg, context, request)
  |> should.equal(
    Ok([models.Model("devin/f25-other", "f25-other-native", 1024, False)]),
  )
  list.each(
    [
      c.Context(..context, account: "one", origin: "http://127.0.0.1:1"),
      c.Context(..context, account: "unknown"),
      c.Context(..context, origin: "http://127.0.0.1:1"),
      c.Context(..context, provider: "codex"),
      c.Context(..context, auth_mode: "oauth"),
    ],
    fn(context) {
      configuration.selected(cfg, context, request) |> should.be_error
    },
  )
  bridge.prepare_configured(
    c.Context(..context, origin: "https://server.codeium.com"),
    request,
    catalog.mappings(model_catalog()),
  )
  |> should.be_error
  list.each(
    [
      c.Request(..request, session: ""),
      c.Request(..request, pinned_account: Some("one")),
      c.Request(..request, model: "devin/f25"),
      c.Request(..request, body: body(True)),
    ],
    fn(request) { catalog_gateway.validate(cfg, request) |> should.be_error },
  )
}

pub fn projected_ids_and_full_history_never_create_a_tenant_or_account_receipt_test() {
  let cfg = configured("http://127.0.0.1:1", "http://127.0.0.1:2")
  let assert Ok(projected) =
    responses.buffered(
      fixture(),
      "resp_source_tenant",
      "devin/f25-alias",
      42,
      settings(),
    )
  let assert Some(ir.String(id)) = ir.field(responses.document(projected), "id")
  list.each(["synthetic-tenant-a", "synthetic-tenant-b"], fn(tenant) {
    let body =
      "{\"model\":\"devin/f25-alias\",\"input\":\"next\",\"previous_response_id\":\""
      <> id
      <> "\"}"
    catalog_gateway.validate(
      cfg,
      c.Request(..request(c.Buffered), session: tenant, body: body),
    )
    |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  })
  let assert Ok(second) =
    responses.buffered(
      fixture(),
      "resp_other_tenant",
      "devin/f25-other",
      42,
      settings(),
    )
  ir.field(responses.document(projected), "id")
  |> should.not_equal(ir.field(responses.document(second), "id"))
  ir.field(responses.document(projected), "output")
  |> should.not_equal(ir.field(responses.document(second), "output"))
}

pub fn input_cardinality_rejects_before_shared_pairer_and_keeps_256_boundary_test() {
  let calls =
    list.index_map(list.repeat(Nil, 8192), fn(_, index) {
      ir.Object([
        #("type", ir.String("function_call")),
        #("call_id", ir.String("call-" <> int.to_string(index))),
        #("name", ir.String("run")),
        #("arguments", ir.String("{}")),
      ])
    })
  let source =
    ir.stringify(
      ir.Object([
        #("model", ir.String("devin/f25-alias")),
        #("input", ir.Array(calls)),
      ]),
    )
  { string.byte_size(source) < 1_048_576 } |> should.be_true
  input.decode(source)
  |> should.equal(Error("Devin Responses input item limit"))
  let messages =
    list.repeat(
      ir.Object([
        #("role", ir.String("user")),
        #("content", ir.String("x")),
      ]),
      256,
    )
  input.decode(
    ir.stringify(
      ir.Object([
        #("model", ir.String("devin/f25-alias")),
        #("input", ir.Array(messages)),
      ]),
    ),
  )
  |> should.be_ok
}

pub fn flat_error_event_uses_actual_sequence_nullable_fields_and_rejects_old_nested_test() {
  let error = c.Failure(c.Unavailable, c.Started, None)
  let assert Ok(frame) = projection.failure(error, 7)
  let assert Ok(value) = sdk_shape.error_event(frame, 7)
  ir.field(value, "message")
  |> should.equal(Some(ir.String("Devin Responses stream failed")))
  ir.field(value, "error") |> should.equal(None)
  let assert Ok(nullable) =
    projection.encode_error(projection.ErrorEvent(
      None,
      "synthetic error",
      None,
      0,
    ))
  sdk_shape.error_event(nullable, 0) |> should.be_ok
  projection.failure(error, -1) |> should.be_error
  sdk_shape.error_event(
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"old\"}}\n\n",
    0,
  )
  |> should.be_error
}

fn schema_document(usage: ir.Value) -> ir.Value {
  // Deliberately synthetic SDK typing fixture, not native accounting evidence.
  ir.Object([
    #("id", ir.String("resp_synthetic_schema")),
    #("object", ir.String("response")),
    #("model", ir.String("devin/f25-alias")),
    #("created_at", ir.Integer(42)),
    #("output", ir.Array([])),
    #("tools", ir.Array([])),
    #("tool_choice", ir.String("auto")),
    #("parallel_tool_calls", ir.Boolean(True)),
    #("usage", usage),
  ])
}

pub fn pinned_sdk_whole_usage_optional_but_detail_objects_and_counts_not_nullable_test() {
  sdk_shape.response(schema_document(ir.Null)) |> should.be_ok
  let core = [
    #("input_tokens", ir.Integer(2)),
    #("output_tokens", ir.Integer(3)),
    #("total_tokens", ir.Integer(5)),
  ]
  sdk_shape.response(schema_document(ir.Object(core))) |> should.be_error
  sdk_shape.response(
    schema_document(
      ir.Object(
        list.append(core, [
          #("input_tokens_details", ir.Null),
          #("output_tokens_details", ir.Null),
        ]),
      ),
    ),
  )
  |> should.be_error
  sdk_shape.response(
    schema_document(
      ir.Object(
        list.append(core, [
          #("input_tokens_details", ir.Object([#("cached_tokens", ir.Null)])),
          #(
            "output_tokens_details",
            ir.Object([#("reasoning_tokens", ir.Null)]),
          ),
        ]),
      ),
    ),
  )
  |> should.be_error
  // Known nonzero counters in a SYNTHETIC schema fixture are legitimate.
  sdk_shape.response(
    schema_document(
      ir.Object(
        list.append(core, [
          #(
            "input_tokens_details",
            ir.Object([#("cached_tokens", ir.Integer(1))]),
          ),
          #(
            "output_tokens_details",
            ir.Object([#("reasoning_tokens", ir.Integer(2))]),
          ),
        ]),
      ),
    ),
  )
  |> should.be_ok
}

fn boundary_native() -> BitArray {
  let chunks =
    list.index_map(list.repeat(Nil, 128), fn(_, index) {
      data([
        native_tool(int.to_string(index), "run", <<"{}":utf8>>),
        pb.text(3, "a"),
      ])
    })
  bit_array.concat(
    list.append(chunks, [
      data([accounting(), pb.Varint(5, 10)]),
      eos(),
    ]),
  )
}

pub fn finalized_256_items_json_sse_positive_and_257_negative_without_tool_confound_test() {
  let frames = parity(boundary_native())
  let assert Ok(document) = oracle.reconstruct(frames)
  let assert Some(ir.Array(output)) = ir.field(document, "output")
  list.length(output) |> should.equal(256)
  let too_many = <<
    { data([pb.text(9, "b")]) }:bits,
    { boundary_native() }:bits,
  >>
  responses.buffered(too_many, "id", "devin/f25-alias", 42, settings())
  |> should.be_error
  let assert Ok(#(decoder, events)) = response.feed(response.new(), too_many)
  response.finish(decoder) |> should.be_ok
  encode(events) |> should.be_error
}

pub fn admitted_controls_echo_exact_tools_and_failclosed_parallel_or_forced_requests_test() {
  let frames = parity(fixture())
  let assert Ok(document) = oracle.reconstruct(frames)
  ir.field(document, "tools")
  |> should.equal(Some(expected_json(definitions())))
  ir.field(document, "tool_choice") |> should.equal(Some(ir.String("auto")))
  ir.field(document, "parallel_tool_calls")
  |> should.equal(Some(ir.Boolean(True)))
  let assert Ok(no_parallel) =
    input.settings(string.replace(
      body(False),
      "\"stream\":false",
      "\"stream\":false,\"parallel_tool_calls\":false",
    ))
  responses.buffered(fixture(), "id", "devin/f25-alias", 42, no_parallel)
  |> should.be_error
  list.each(["true", "null"], fn(strict) {
    input.decode(string.replace(
      body(False),
      "\"strict\":false",
      "\"strict\":" <> strict,
    ))
    |> should.be_error
  })
  input.decode(string.replace(body(False), ",\"strict\":false", ""))
  |> should.be_error
  list.each(["required", "none"], fn(choice) {
    input.decode(string.replace(
      body(False),
      "\"stream\":false",
      "\"stream\":false,\"tool_choice\":\"" <> choice <> "\"",
    ))
    |> should.be_error
  })
}

fn synthetic_adapter(
  chunks: List(BitArray),
  observed: process.Subject(String),
) -> c.Adapter(List(BitArray)) {
  c.Adapter(
    open: fn(context, _) {
      process.send(observed, "open_" <> context.account)
      Ok(c.Opened(
        200,
        [Header("Content-Type", "application/connect+proto")],
        chunks,
      ))
    },
    next: fn(chunks) {
      case chunks {
        [] -> {
          process.send(observed, "eof")
          Ok(None)
        }
        [bytes, ..rest] -> Ok(Some(#(bytes, rest)))
      }
    },
    cancel: fn(_) { process.send(observed, "cancel") },
    rejection: fn(_, _) { None },
  )
}

fn drain(observed: process.Subject(String)) -> List(String) {
  case process.receive(observed, 20) {
    Ok(value) -> [value, ..drain(observed)]
    Error(_) -> []
  }
}

fn pad(bytes: Int) -> BitArray {
  data([pb.Bytes(1, bit_array.from_string(string.repeat("\u{0000}", bytes)))])
}

fn native_byte_chunks(extra: Int) -> List(BitArray) {
  let tail = <<
    { data([pb.text(3, "ok"), accounting(), pb.Varint(5, 2)]) }:bits,
    { eos() }:bits,
  >>
  list.append(list.repeat(pad(65_527), 127), [
    pad(65_536 - bit_array.byte_size(tail) - 9 + extra),
    tail,
  ])
}

pub fn aggregate_native_exact_8mib_and_plus_one_multichunk_isolated_adapter_test() {
  list.each([0, 1], fn(extra) {
    let chunks = native_byte_chunks(extra)
    list.fold(chunks, 0, fn(size, bytes) { size + bit_array.byte_size(bytes) })
    |> should.equal(responses.max_bytes + extra)
    list.each([c.Buffered, c.Streaming], fn(mode) {
      use directory, one, two <- with_servers(
        http(fixture(), False),
        http(fixture(), False),
        False,
        inspect,
      )
      let engine = engine(directory, one, two)
      finally(
        fn() {
          let observed = process.new_subject()
          let adapter = synthetic_adapter(chunks, observed)
          let deadline = now(Millisecond) + 10_000
          case mode {
            c.Buffered -> {
              let result =
                gateway.execute_with_adapter_until(
                  engine,
                  request(mode),
                  catalog.mappings(model_catalog()),
                  adapter,
                  deadline,
                )
              case extra {
                0 -> {
                  let _ = result |> should.be_ok
                  Nil
                }
                _ -> {
                  result
                  |> should.equal(
                    Error(c.Failure(c.InvalidResponse, c.Started, None)),
                  )
                  Nil
                }
              }
            }
            c.Streaming -> {
              let assert Ok(#("one", opened)) =
                gateway.open_with_adapter_until(
                  engine,
                  request(mode),
                  catalog.mappings(model_catalog()),
                  adapter,
                  deadline,
                )
              let #(batch, frames) = collect(opened, [])
              case extra {
                0 -> {
                  let _ = oracle.reconstruct(frames) |> should.be_ok
                  Nil
                }
                _ -> {
                  batch.error
                  |> should.equal(
                    Some(c.Failure(c.InvalidResponse, c.Started, None)),
                  )
                  frames |> should.equal([])
                  Nil
                }
              }
            }
          }
          let observations = drain(observed)
          list.count(observations, fn(value) { value == "open_one" })
          |> should.equal(1)
          list.contains(observations, "open_two") |> should.be_false
          list.contains(observations, "cancel") |> should.be_true
          runtime.active_leases(engine) |> should.equal(Ok(0))
          counts(one).0 |> should.equal(0)
          counts(two).0 |> should.equal(0)
          Nil
        },
        fn() {
          let _ = runtime.stop(engine)
          Nil
        },
      )
      Nil
    })
  })
}

pub fn post_eof_first_callback_expiry_never_starts_remaining_or_terminal_frames_test() {
  use directory, one, two <- with_servers(
    http(fixture(), False),
    http(fixture(), False),
    False,
    inspect,
  )
  let engine = engine(directory, one, two)
  finally(
    fn() {
      let observed = process.new_subject()
      let emitted = process.new_subject()
      let deadline = now(Millisecond) + 500
      let assert Ok(#(_, opened)) =
        gateway.open_with_adapter_until(
          engine,
          request(c.Streaming),
          catalog.mappings(model_catalog()),
          synthetic_adapter([fixture()], observed),
          deadline,
        )
      let outcome =
        delivery.run(opened, deadline, fn(frame) {
          runtime.active_leases(engine) |> should.equal(Ok(0))
          process.send(emitted, frame)
          process.sleep(int.max(0, deadline - now(Millisecond) + 20))
          Ok(Continue)
        })
      let assert delivery.Failed(error, 1, False) = outcome
      error |> should.equal(c.Failure(c.Unavailable, c.Started, None))
      let frames = drain(emitted)
      list.length(frames) |> should.equal(1)
      let assert [created] = frames
      string.contains(created, "response.created") |> should.be_true
      string.contains(created, "response.completed") |> should.be_false
      let assert Ok(failure) = projection.failure(error, 1)
      sdk_shape.error_event(failure, 1) |> should.be_ok
      runtime.active_leases(engine) |> should.equal(Ok(0))
      Nil
    },
    fn() {
      let _ = runtime.stop(engine)
      Nil
    },
  )
  Nil
}

pub fn original_native_deadline_error_is_flat_typed_not_permissive_observer_success_test() {
  let prefix = data([pb.text(3, "prefix")])
  use directory, one, two <- with_servers(
    <<
      "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n",
      {
        int.to_base_string(bit_array.byte_size(prefix), 16)
        |> result.unwrap("0")
      }:utf8,
      "\r\n",
      prefix:bits,
      "\r\n",
    >>,
    http(fixture(), False),
    True,
    inspect,
  )
  let engine = engine(directory, one, two)
  finally(
    fn() {
      let emitted = process.new_subject()
      let deadline = now(Millisecond) + 200
      let cfg = configured(origin(one), origin(two))
      let assert Ok(#(_, opened)) =
        gateway.open_with_adapter_until(
          engine,
          request(c.Streaming),
          catalog.mappings(model_catalog()),
          catalog_gateway.adapter(cfg, None),
          deadline,
        )
      let outcome =
        delivery.run(opened, deadline, fn(frame) {
          process.send(emitted, frame)
          Ok(Continue)
        })
      let assert delivery.Failed(error, 0, False) = outcome
      drain(emitted) |> should.equal([])
      let assert Ok(frame) = projection.failure(error, 0)
      sdk_shape.error_event(frame, 0) |> should.be_ok
      await_eof(one, 200)
      runtime.active_leases(engine) |> should.equal(Ok(0))
      counts(two).0 |> should.equal(0)
      Nil
    },
    fn() {
      let _ = runtime.stop(engine)
      Nil
    },
  )
  Nil
}
