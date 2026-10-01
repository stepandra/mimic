/// F14 SYNTHETIC native Messages fixtures. No live, CPA or native-client calls.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/responses/http as lifecycle
import mimic/providers/claude/http
import mimic/providers/claude/stream
import mimic/providers/contracts as c
import mimic/providers/kimi/adapter
import mimic/providers/kimi/models
import mimic/providers/kimi/request
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{type Header, Header}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

type Server

@external(erlang, "mimic_egress_test_ffi", "start")
fn server_start(response: BitArray) -> Result(Server, String)

@external(erlang, "mimic_egress_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_egress_test_ffi", "requests")
fn observed(server: Server) -> List(BitArray)

@external(erlang, "mimic_egress_test_ffi", "stop")
fn server_stop(server: Server) -> Nil

type Call {
  Pull
  Cancel
}

fn req(model: String) -> c.Request {
  c.Request(
    "kimi",
    "api_key",
    model,
    "anthropic",
    "messages",
    c.Streaming,
    [],
    "synthetic-client:synthetic-session",
    None,
    "{\"model\":\""
      <> model
      <> "\",\"stream\":true,\"max_tokens\":128,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}",
  )
}

fn start_pool(origin: String) -> runtime.Runtime {
  let assert Ok(store) = storage.new(directory())
  credentials.save_api_key(
    store,
    credentials.key("kimi", "api_key", "synthetic-account"),
    "synthetic-native-kimi-key",
  )
  |> should.be_ok
  let assert Ok(a) = models.registration("kimi-k2.8")
  let assert Ok(b) = models.registration("kimi-k3")
  let assert Ok(catalog) = registry.new([a, b])
  let assert Ok(pool) =
    runtime.start(store, catalog, [
      runtime.Account(
        "kimi",
        "api_key",
        "synthetic-account",
        origin,
        fleet.LocalLoopback,
        2,
        ["kimi-k2.8", "kimi-k3"],
        credentials.StaticKey,
      ),
    ])
  pool
}

fn headers() -> List(Header) {
  [Header("Content-Type", "text/event-stream; charset=utf-8")]
}

fn stub(
  chunks: List(BitArray),
  status: Int,
  headers: List(Header),
  calls: process.Subject(Call),
) -> c.Adapter(List(BitArray)) {
  c.Adapter(
    fn(_, _) { Ok(c.Opened(status, headers, chunks)) },
    fn(chunks) {
      process.send(calls, Pull)
      case chunks {
        [] -> Ok(None)
        [bytes, ..rest] -> Ok(Some(#(bytes, rest)))
      }
    },
    fn(_) { process.send(calls, Cancel) },
    request.rejection,
  )
}

fn drain(subject: process.Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(value) -> [value, ..drain(subject)]
    Error(_) -> []
  }
}

fn frame(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

fn start_document(model: String) -> String {
  "{\"type\":\"message_start\",\"model\":\"kimi-for-coding\",\"message\":{\"id\":\"msg_synthetic_shared\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\""
  <> model
  <> "\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":3,\"output_tokens\":0,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":2,\"vendor\":{\"model\":\"kimi-for-coding\"}},\"vendor\":{\"model\":\"kimi-for-coding\",\"signature\":\"synthetic\"}},\"vendor\":{\"model\":\"kimi-for-coding\"}}"
}

fn start(model: String) -> String {
  "event: message_start\nid: synthetic-id\n: synthetic-comment\nretry: 123\nx-synthetic: keep\ndata: "
  <> start_document(model)
  <> "\n\n"
}

fn expected_start(model: String) -> String {
  let assert Ok(value) = ir.parse(start_document(model))
  "event: message_start\nid: synthetic-id\n: synthetic-comment\nretry: 123\nx-synthetic: keep\ndata: "
  <> ir.stringify(value)
  <> "\n\n"
}

fn ping() -> String {
  frame("ping", "{\"type\":\"ping\",\"model\":\"kimi-for-coding\"}")
}

fn stop() -> String {
  frame("message_stop", "{\"type\":\"message_stop\"}")
}

fn content() -> String {
  frame(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"synthetic-initial\"},\"vendor\":{\"model\":\"kimi-for-coding\"}}",
  )
  <> frame(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"synthetic 思考🌍\"}}",
  )
  <> frame(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"synthetic-signed-byte-string\"}}",
  )
  <> frame(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
  <> frame(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"synthetic-redacted\"}}",
  )
  <> frame(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":1}",
  )
  <> frame(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_synthetic_shared\",\"name\":\"lookup\",\"input\":{\"model\":\"kimi-for-coding\"},\"vendor\":true}}",
  )
  <> frame(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"model\\\":\\\"kimi-for-coding\\\"}\"},\"vendor\":{\"model\":\"kimi-for-coding\"}}",
  )
  <> frame(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":2}",
  )
  <> frame(
    "synthetic_future",
    "{\"type\":\"synthetic_future\",\"message\":{\"model\":\"kimi-for-coding\"},\"opaque\":[null,true,42]}",
  )
  <> frame(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":7,\"cache_read_input_tokens\":4,\"vendor\":[1,2]}}",
  )
}

fn complete(upstream: String) -> String {
  start(upstream) <> content() <> stop()
}

fn chunks(bytes: BitArray, width: Int) -> List(BitArray) {
  let size = bit_array.byte_size(bytes)
  case size <= width {
    True -> [bytes]
    False -> {
      let assert Ok(front) = bit_array.slice(bytes, 0, width)
      let assert Ok(back) = bit_array.slice(bytes, width, size - width)
      [front, ..chunks(back, width)]
    }
  }
}

fn decode(
  state: http.State,
  chunks: List(BitArray),
  emitted: List(String),
) -> #(Result(stream.Status, String), List(String)) {
  case chunks {
    [] -> #(http.finish(state), emitted)
    [chunk, ..rest] -> {
      let batch = http.feed_partial(state, chunk)
      let emitted = list.append(emitted, batch.frames)
      case batch.next {
        Error(error) -> #(Error(error), emitted)
        Ok(next) -> decode(next, rest, emitted)
      }
    }
  }
}

fn run(
  pool: runtime.Runtime,
  chunks: List(BitArray),
) -> #(Result(stream.Status, c.Failure), List(String), List(Call)) {
  let calls = process.new_subject()
  let emitted = process.new_subject()
  let assert Ok(opened) =
    runtime.open(pool, stub(chunks, 200, headers(), calls), req("kimi-k2.8"))
  let outcome =
    adapter.run_messages_for(opened, req("kimi-k2.8"), fn(frame) {
      process.send(emitted, frame)
      Ok(lifecycle.Continue)
    })
  runtime.active_leases(pool) |> should.equal(Ok(0))
  #(outcome, drain(emitted), drain(calls))
}

pub fn every_byte_split_and_line_endings_restore_only_owned_model_test() {
  let expected = expected_start("kimi-k2.8") <> content() <> stop()
  list.each(["\n", "\r\n", "\r"], fn(newline) {
    let fixture =
      "\u{FEFF}" <> string.replace(complete("kimi-for-coding"), "\n", newline)
    let bytes = bit_array.from_string(fixture)
    let size = bit_array.byte_size(bytes)
    list.repeat(Nil, size + 1)
    |> list.index_map(fn(_, index) { index })
    |> list.each(fn(split) {
      let assert Ok(front) = bit_array.slice(bytes, 0, split)
      let assert Ok(back) = bit_array.slice(bytes, split, size - split)
      let #(status, frames) =
        decode(
          http.new_with_model("kimi-for-coding", "kimi-k2.8"),
          [front, back],
          [],
        )
      status |> should.equal(Ok(stream.Completed))
      string.join(frames, "") |> should.equal(expected)
    })
  })
}

pub fn actual_runner_one_byte_chunks_preserve_tools_signatures_and_usage_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  let #(status, frames, calls) =
    run(pool, chunks(bit_array.from_string(complete("kimi-for-coding")), 1))
  status |> should.equal(Ok(stream.Completed))
  string.join(frames, "")
  |> should.equal(expected_start("kimi-k2.8") <> content() <> stop())
  list.count(calls, fn(call) { call == Cancel }) |> should.equal(1)
  let assert Ok(#(state, _)) =
    stream.feed(
      stream.new_with_model("kimi-for-coding", "kimi-k2.8"),
      complete("kimi-for-coding"),
    )
  stream.usage(state)
  |> should.equal(stream.Usage(Some(3), Some(7), Some(1), Some(4)))
  runtime.stop(pool) |> should.be_ok
}

pub fn default_claude_observer_and_runner_keep_original_raw_frames_test() {
  let fixture = complete("kimi-for-coding")
  let assert Ok(#(state, frames)) = stream.feed(stream.new(), fixture)
  string.join(frames, "") |> should.equal(fixture)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let pool = start_pool("http://127.0.0.1:8000")
  let calls = process.new_subject()
  let emitted = process.new_subject()
  let assert Ok(opened) =
    runtime.open(
      pool,
      stub([bit_array.from_string(fixture)], 200, headers(), calls),
      req("kimi-k2.8"),
    )
  http.run(opened, fn(frame) {
    process.send(emitted, frame)
    Ok(lifecycle.Continue)
  })
  |> should.equal(Ok(stream.Completed))
  string.join(drain(emitted), "") |> should.equal(fixture)
  drain(calls) |> should.equal([Pull, Cancel])
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}

pub fn valid_prefix_precedes_model_missing_wrong_or_duplicate_errors_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  list.each(
    [
      start("kimi-k2.8"),
      start("other-upstream"),
      string.replace(
        start("kimi-for-coding"),
        "\"model\":\"kimi-for-coding\",",
        "",
      ),
      string.replace(
        start("kimi-for-coding"),
        "\"model\":\"kimi-for-coding\"",
        "\"model\":\"kimi-for-coding\",\"model\":\"hidden\"",
      ),
      string.replace(
        start("kimi-for-coding"),
        "\"model\":\"kimi-for-coding\"",
        "\"model\":\"kimi-for-coding\",\"\\u006dodel\":\"hidden\"",
      ),
    ],
    fn(invalid) {
      let #(status, frames, calls) =
        run(pool, [bit_array.from_string(ping() <> invalid)])
      status
      |> should.equal(Error(c.Failure(c.InvalidResponse, c.Started, None)))
      frames |> should.equal([ping()])
      calls |> should.equal([Pull, Cancel])
    },
  )
  runtime.stop(pool) |> should.be_ok
}

pub fn valid_prefix_precedes_protocol_usage_utf8_and_eof_errors_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  list.each(
    [
      bit_array.from_string("data: {broken}\n\n"),
      bit_array.from_string(start("kimi-for-coding")),
      bit_array.from_string("data: [DONE]\n\n"),
      bit_array.from_string(
        "event: message_stop\ndata: {\"type\":\"ping\"}\n\n",
      ),
      bit_array.from_string(frame(
        "message_delta",
        "{\"type\":\"message_delta\",\"usage\":{\"output_tokens\":-1}}",
      )),
      bit_array.from_string(
        "data: {\"type\":\"message_delta\",\"type\":\"ping\"}\n\n",
      ),
      <<100, 97, 116, 97, 58, 32, 255, 10, 10>>,
      bit_array.from_string("data: {\"type\":\"message_stop\"}\n"),
      <<>>,
    ],
    fn(suffix) {
      let prefix = bit_array.from_string(start("kimi-for-coding"))
      let #(status, frames, calls) = run(pool, [<<prefix:bits, suffix:bits>>])
      status
      |> should.equal(Error(c.Failure(c.InvalidResponse, c.Started, None)))
      frames |> should.equal([expected_start("kimi-k2.8")])
      list.count(calls, fn(call) { call == Cancel }) |> should.equal(1)
    },
  )
  runtime.stop(pool) |> should.be_ok
}

pub fn valid_prefix_error_all_byte_splits_test() {
  let bytes =
    bit_array.from_string(start("kimi-for-coding") <> "data: {broken}\n\n")
  let size = bit_array.byte_size(bytes)
  list.repeat(Nil, size + 1)
  |> list.index_map(fn(_, index) { index })
  |> list.each(fn(split) {
    let assert Ok(a) = bit_array.slice(bytes, 0, split)
    let assert Ok(b) = bit_array.slice(bytes, split, size - split)
    let #(status, frames) =
      decode(http.new_with_model("kimi-for-coding", "kimi-k2.8"), [a, b], [])
    status |> should.be_error
    frames |> should.equal([expected_start("kimi-k2.8")])
  })
}

pub fn named_error_is_terminal_without_invented_stop_or_done_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  let error =
    frame(
      "error",
      "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"synthetic error\",\"opaque\":[1,2]},\"message\":{\"model\":\"kimi-for-coding\"}}",
    )
  list.each(["", start("kimi-for-coding")], fn(prefix) {
    let #(status, frames, calls) =
      run(pool, [bit_array.from_string(prefix <> error <> "ignored")])
    status |> should.equal(Ok(stream.Failed(stream.Overloaded)))
    string.join(frames, "")
    |> should.equal(case prefix {
      "" -> error
      _ -> expected_start("kimi-k2.8") <> error
    })
    calls |> should.equal([Pull, Cancel])
  })
  runtime.stop(pool) |> should.be_ok
}

pub fn cancel_and_downstream_error_never_pull_again_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  list.each([Ok(lifecycle.Cancel), Error("synthetic closed")], fn(control) {
    let calls = process.new_subject()
    let emitted = process.new_subject()
    let assert Ok(opened) =
      runtime.open(
        pool,
        stub(
          [
            bit_array.from_string(start("kimi-for-coding") <> content()),
            bit_array.from_string(stop()),
          ],
          200,
          headers(),
          calls,
        ),
        req("kimi-k2.8"),
      )
    adapter.run_messages_for(opened, req("kimi-k2.8"), fn(frame) {
      process.send(emitted, frame)
      control
    })
    |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
    drain(emitted) |> should.equal([expected_start("kimi-k2.8")])
    drain(calls) |> should.equal([Pull, Cancel])
    runtime.active_leases(pool) |> should.equal(Ok(0))
  })
  runtime.stop(pool) |> should.be_ok
}

pub fn invalid_headers_cancel_before_pull_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  list.each(
    [
      #(302, headers()),
      #(200, []),
      #(200, [Header("Content-Type", "application/json")]),
      #(200, [Header("Content-Type", "text/event-stream-bogus")]),
      #(200, [Header("Content-Type", "text/event-stream; charset=latin1")]),
      #(200, [Header("content-type", "text/event-stream"), ..headers()]),
      #(200, [Header("Content-Encoding", "gzip"), ..headers()]),
      #(200, [
        Header("Content-Encoding", "identity"),
        Header("content-encoding", "identity"),
        ..headers()
      ]),
    ],
    fn(spec) {
      let calls = process.new_subject()
      let assert Ok(opened) =
        runtime.open(pool, stub([], spec.0, spec.1, calls), req("kimi-k2.8"))
      adapter.run_messages_for(opened, req("kimi-k2.8"), fn(_) {
        panic as "Invalid headers reached downstream"
      })
      |> should.equal(Error(c.Failure(c.InvalidResponse, c.Started, None)))
      drain(calls) |> should.equal([Cancel])
      runtime.active_leases(pool) |> should.equal(Ok(0))
    },
  )
  runtime.stop(pool) |> should.be_ok
}

pub fn request_bound_model_and_terminal_state_isolation_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  let calls_a = process.new_subject()
  let calls_b = process.new_subject()
  let emitted_a = process.new_subject()
  let emitted_b = process.new_subject()
  let a_req = c.Request(..req("kimi-k2.8"), session: "client-a:session")
  let b_req = c.Request(..req("kimi-k3"), session: "client-b:session")
  let assert Ok(a) =
    runtime.open(
      pool,
      stub(
        [bit_array.from_string(complete("kimi-for-coding"))],
        200,
        headers(),
        calls_a,
      ),
      a_req,
    )
  let assert Ok(b) =
    runtime.open(
      pool,
      stub([bit_array.from_string(complete("k3"))], 200, headers(), calls_b),
      b_req,
    )
  runtime.active_leases(pool) |> should.equal(Ok(2))
  adapter.run_messages_for(a, a_req, fn(frame) {
    process.send(emitted_a, frame)
    Ok(lifecycle.Continue)
  })
  |> should.equal(Ok(stream.Completed))
  runtime.active_leases(pool) |> should.equal(Ok(1))
  adapter.run_messages_for(b, b_req, fn(frame) {
    process.send(emitted_b, frame)
    Ok(lifecycle.Continue)
  })
  |> should.equal(Ok(stream.Completed))
  string.join(drain(emitted_a), "")
  |> should.equal(expected_start("kimi-k2.8") <> content() <> stop())
  string.join(drain(emitted_b), "")
  |> should.equal(expected_start("kimi-k3") <> content() <> stop())
  drain(calls_a) |> should.equal([Pull, Cancel])
  drain(calls_b) |> should.equal([Pull, Cancel])
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}

pub fn adopted_new_owner_runs_native_messages_and_cleans_once_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  let calls = process.new_subject()
  let assert Ok(opened) =
    runtime.open(
      pool,
      stub(
        [bit_array.from_string(complete("kimi-for-coding"))],
        200,
        headers(),
        calls,
      ),
      req("kimi-k2.8"),
    )
  let ready = process.new_subject()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      runtime.adopt(opened.stream) |> should.equal(Ok(Nil))
      process.send(ready, go)
      process.receive(go, 3000) |> should.equal(Ok(Nil))
      process.send(
        done,
        adapter.run_messages_for(opened, req("kimi-k2.8"), fn(_) {
          Ok(lifecycle.Continue)
        }),
      )
    })
  let assert Ok(go) = process.receive(ready, 3000)
  runtime.next(opened.stream) |> should.be_error
  runtime.adopt(opened.stream) |> should.be_error
  process.send(go, Nil)
  process.receive(done, 3000) |> should.equal(Ok(Ok(stream.Completed)))
  drain(calls) |> should.equal([Pull, Cancel])
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}

pub fn restored_output_and_original_input_event_limits_test() {
  // k3 -> kimi-k3 increases only the protocol field by 5 bytes.
  let empty =
    frame(
      "message_start",
      "{\"type\":\"message_start\",\"message\":{\"model\":\"k3\"},\"padding\":\"\"}",
    )
  let near_limit =
    string.replace(
      empty,
      "\"padding\":\"\"",
      "\"padding\":\""
        <> string.repeat("x", 1_048_576 - string.byte_size(empty))
        <> "\"",
    )
  string.byte_size(near_limit) |> should.equal(1_048_576)
  let native = http.feed_partial(http.new(), bit_array.from_string(near_limit))
  native.next |> should.be_ok
  native.frames |> should.equal([near_limit])
  let at_output_limit =
    string.replace(
      empty,
      "\"padding\":\"\"",
      "\"padding\":\""
        <> string.repeat("x", 1_048_571 - string.byte_size(empty))
        <> "\"",
    )
  let accepted =
    http.feed_partial(
      http.new_with_model("k3", "kimi-k3"),
      bit_array.from_string(at_output_limit),
    )
  accepted.next |> should.be_ok
  let assert [bounded] = accepted.frames
  string.byte_size(bounded) |> should.equal(1_048_576)
  let one_over =
    http.feed_partial(
      http.new_with_model("k3", "kimi-k3"),
      bit_array.from_string(string.replace(
        at_output_limit,
        "\"padding\":\"",
        "\"padding\":\"x",
      )),
    )
  one_over.next
  |> should.equal(Error("Restored Messages SSE event exceeds limit"))
  one_over.frames |> should.equal([])
  let restored =
    http.feed_partial(
      http.new_with_model("k3", "kimi-k3"),
      bit_array.from_string(ping() <> near_limit),
    )
  restored.next
  |> should.equal(Error("Restored Messages SSE event exceeds limit"))
  restored.frames |> should.equal([ping()])
  let oversized =
    near_limit |> string.replace("\"padding\":\"", "\"padding\":\"x")
  let rejected = http.feed_partial(http.new(), bit_array.from_string(oversized))
  rejected.next |> should.be_error
  rejected.frames |> should.equal([])
}

pub fn real_loopback_uses_native_route_auth_and_streaming_body_test() {
  let payload = complete("kimi-for-coding")
  let assert Ok(server) =
    server_start(bit_array.from_string(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: "
      <> int.to_string(string.byte_size(payload))
      <> "\r\nConnection: close\r\n\r\n"
      <> payload,
    ))
  let pool = start_pool("http://127.0.0.1:" <> int.to_string(port(server)))
  let transport = request.http_at(fn(_) { Ok("/tenant/native/v1") }, None)
  let assert Ok(opened) = runtime.open(pool, transport, req("kimi-k2.8"))
  let emitted = process.new_subject()
  adapter.run_messages_for(opened, req("kimi-k2.8"), fn(frame) {
    process.send(emitted, frame)
    Ok(lifecycle.Continue)
  })
  |> should.equal(Ok(stream.Completed))
  string.join(drain(emitted), "")
  |> should.equal(expected_start("kimi-k2.8") <> content() <> stop())
  let assert [raw] = observed(server)
  let assert Ok(raw) = bit_array.to_string(raw)
  string.starts_with(
    raw,
    "POST /tenant/native/v1/messages?beta=true HTTP/1.1\r\n",
  )
  |> should.be_true
  string.contains(raw, "Accept: text/event-stream\r\n") |> should.be_true
  string.contains(raw, "anthropic-version: 2023-06-01\r\n") |> should.be_true
  string.contains(raw, "Authorization: Bearer synthetic-native-kimi-key\r\n")
  |> should.be_true
  string.contains(raw, "\"stream\":true") |> should.be_true
  string.contains(raw, "\"model\":\"kimi-for-coding\"") |> should.be_true
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
  server_stop(server)
}

pub fn selected_model_mapping_is_not_inferred_from_response_or_other_stream_test() {
  list.each(models.reference_ids(), fn(model) {
    let assert Some(upstream) = models.upstream_id(model)
    let #(status, frames) =
      decode(
        http.new_with_model(upstream, model),
        chunks(bit_array.from_string(complete(upstream)), 13),
        [],
      )
    status |> should.equal(Ok(stream.Completed))
    string.join(frames, "")
    |> should.equal(expected_start(model) <> content() <> stop())
  })
  // Two public aliases have the same upstream; neither may restore the other's ID.
  let a =
    http.feed_partial(
      http.new_with_model("kimi-for-coding", "kimi-k2.8"),
      bit_array.from_string(start("kimi-for-coding")),
    )
  let b =
    http.feed_partial(
      http.new_with_model("kimi-for-coding", "kimi-k2.7-code"),
      bit_array.from_string(start("kimi-for-coding")),
    )
  a.frames |> should.equal([expected_start("kimi-k2.8")])
  b.frames |> should.equal([expected_start("kimi-k2.7-code")])
}

pub fn invalid_runner_context_never_authorizes_empty_or_guessed_models_test() {
  let pool = start_pool("http://127.0.0.1:8000")
  list.each(
    [
      c.Request(..req("kimi-k2.8"), model: ""),
      c.Request(..req("kimi-k2.8"), model: "synthetic-unregistered"),
      c.Request(..req("kimi-k2.8"), provider: "openai-compatible-kimi"),
      c.Request(..req("kimi-k2.8"), protocol: "chat"),
      c.Request(..req("kimi-k2.8"), mode: c.Buffered),
    ],
    fn(invalid) {
      let calls = process.new_subject()
      let assert Ok(opened) =
        runtime.open(pool, stub([], 200, headers(), calls), req("kimi-k2.8"))
      adapter.run_messages_for(opened, invalid, fn(_) {
        panic as "Invalid context reached downstream"
      })
      |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
      drain(calls) |> should.equal([Cancel])
      runtime.active_leases(pool) |> should.equal(Ok(0))
    },
  )
  runtime.stop(pool) |> should.be_ok
}
