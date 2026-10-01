/// SYNTHETIC Chat fixtures. No provider, native client or CPA executions.
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
import mimic/protocol/chat/stream
import mimic/protocol/responses/http
import mimic/providers/contracts as c
import mimic/providers/kimi_compat/adapter
import mimic/providers/kimi_compat/request
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{type Header, Header}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

type Server

/// Reuse the existing synthetic real-socket fixture without another parser.
@external(erlang, "mimic_egress_test_ffi", "start")
fn server_start(response: BitArray) -> Result(Server, String)

@external(erlang, "mimic_egress_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_egress_test_ffi", "requests")
fn observed(server: Server) -> List(BitArray)

@external(erlang, "mimic_egress_test_ffi", "stop")
fn stop(server: Server) -> Nil

type Call {
  Pull
  Cancel
}

const model = "kimi-k2.8"

fn req() -> c.Request {
  c.Request(
    request.provider,
    "api_key",
    model,
    "chat",
    "chat/completions",
    c.Streaming,
    [],
    "synthetic-client:synthetic-session",
    None,
    "{\"model\":\"kimi-k2.8\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}",
  )
}

fn start(origin: String) -> runtime.Runtime {
  let assert Ok(store) = storage.new(directory())
  credentials.save_api_key(
    store,
    credentials.key(request.provider, "api_key", "synthetic-account"),
    "synthetic-generic-kimi-key",
  )
  |> should.be_ok
  let assert Ok(registered) = request.registration(model)
  let assert Ok(catalog) = registry.new([registered])
  let assert Ok(pool) =
    runtime.start(store, catalog, [
      runtime.Account(
        request.provider,
        "api_key",
        "synthetic-account",
        origin,
        fleet.LocalLoopback,
        2,
        [model],
        credentials.StaticKey,
      ),
    ])
  pool
}

fn sse_headers() -> List(Header) {
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

fn event(choices: String, extra: String) -> String {
  "data: {\"id\":\"synthetic-chat\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\""
  <> model
  <> "\",\"choices\":"
  <> choices
  <> extra
  <> "}\n\n"
}

fn prefix() -> String {
  event(
    "[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning_content\":\"synthetic 想🌍\",\"content\":\"你好\",\"refusal\":null,\"vendor\":{\"model\":\"kimi-for-coding\"}},\"finish_reason\":null,\"logprobs\":{\"content\":[]}}]",
    ",\"system_fingerprint\":\"fp_synthetic\",\"vendor\":{\"audio\":{\"type\":\"input_audio\"}}",
  )
}

fn terminal() -> String {
  event("[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]", "")
  <> "data: [DONE]\n\n"
}

fn full() -> String {
  prefix()
  <> event(
    "[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_synthetic\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"model\\\":\"},\"vendor\":42}]},\"finish_reason\":null}]",
    "",
  )
  <> event(
    "[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"kimi-for-coding\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]",
    ",\"opaque\":[null,true,{\"x\":\"synthetic\"}]",
  )
  <> event(
    "[]",
    ",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7,\"completion_tokens_details\":{\"reasoning_tokens\":2},\"vendor\":99}",
  )
  <> "data: [DONE]\n\n"
}

fn run(
  pool: runtime.Runtime,
  chunks: List(BitArray),
) -> #(Result(stream.Outcome, c.Failure), List(stream.Event), List(Call)) {
  let calls = process.new_subject()
  let emitted = process.new_subject()
  let assert Ok(opened) =
    runtime.open(pool, stub(chunks, 200, sse_headers(), calls), req())
  let outcome =
    adapter.run_chat_for(opened, req(), fn(event) {
      process.send(emitted, event)
      Ok(http.Continue)
    })
  runtime.active_leases(pool) |> should.equal(Ok(0))
  #(outcome, drain(emitted), drain(calls))
}

fn cancel_count(calls: List(Call)) -> Int {
  list.count(calls, fn(call) { call == Cancel })
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

pub fn every_byte_boundary_and_one_byte_chunks_preserve_documents_test() {
  let pool = start("http://127.0.0.1:8000")
  let fixture =
    event(
      "[{\"index\":0,\"delta\":{\"content\":\"synthetic 你好🌍\"},\"finish_reason\":\"stop\"}]",
      ",\"opaque\":{\"model\":\"kimi-for-coding\"}",
    )
    <> "data: [DONE]\n\n"
  let bytes = bit_array.from_string(fixture)
  let size = bit_array.byte_size(bytes)
  let #(outcome, expected, _) = run(pool, [bytes])
  outcome |> should.equal(Ok(stream.Completed))
  list.repeat(Nil, size + 1)
  |> list.index_map(fn(_, index) { index })
  |> list.each(fn(split) {
    let assert Ok(front) = bit_array.slice(bytes, 0, split)
    let assert Ok(back) = bit_array.slice(bytes, split, size - split)
    let #(outcome, events, calls) = run(pool, [front, back])
    outcome |> should.equal(Ok(stream.Completed))
    events |> should.equal(expected)
    cancel_count(calls) |> should.equal(1)
  })
  let #(outcome, events, calls) = run(pool, chunks(bytes, 1))
  outcome |> should.equal(Ok(stream.Completed))
  events |> should.equal(expected)
  cancel_count(calls) |> should.equal(1)
  runtime.stop(pool) |> should.be_ok
}

pub fn full_native_semantic_fields_and_opaque_values_survive_test() {
  let pool = start("http://127.0.0.1:8000")
  let #(outcome, events, calls) =
    run(pool, chunks(bit_array.from_string(full()), 7))
  outcome |> should.equal(Ok(stream.Completed))
  cancel_count(calls) |> should.equal(1)
  let assert [stream.Event(first), _, _, stream.Event(usage), stream.Done] =
    events
  let assert Ok(expected) =
    ir.parse(
      prefix()
      |> string.drop_start(6)
      |> string.trim,
    )
  first |> should.equal(expected)
  let assert Ok(expected_usage) =
    ir.parse(
      "{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7,\"completion_tokens_details\":{\"reasoning_tokens\":2},\"vendor\":99}",
    )
  ir.field(usage, "usage")
  |> should.equal(Some(expected_usage))
  // Encoding uses the shared native Chat encoder, retaining the whole value.
  let assert Ok(#(_, encoded)) =
    string.split_once(stream.encode_event(stream.Event(first)), "data: ")
  ir.parse(string.trim(encoded)) |> should.equal(Ok(first))
  runtime.stop(pool) |> should.be_ok
}

pub fn valid_prefix_is_delivered_before_protocol_and_model_errors_test() {
  let pool = start("http://127.0.0.1:8000")
  list.each(
    [
      "data: {broken}\n\n",
      string.replace(terminal(), "\"kimi-k2.8\"", "\"kimi-for-coding\""),
      string.replace(terminal(), "\"synthetic-chat\"", "\"other-chat\""),
      "data: [DONE]\n\n",
      "",
      "data: {\"id\":\"duplicate\",\"id\":\"hidden\"}\n\n",
    ],
    fn(suffix) {
      let #(outcome, events, calls) =
        run(pool, [bit_array.from_string(prefix() <> suffix)])
      outcome
      |> should.equal(Error(c.Failure(c.InvalidResponse, c.Started, None)))
      list.length(events) |> should.equal(1)
      cancel_count(calls) |> should.equal(1)
    },
  )
  runtime.stop(pool) |> should.be_ok
}

pub fn named_remote_error_is_preserved_without_inventing_done_test() {
  let pool = start("http://127.0.0.1:8000")
  let error =
    "{\"error\":{\"message\":\"synthetic error\",\"code\":\"vendor_code\",\"opaque\":[1,2]},\"vendor\":{\"model\":\"kimi-for-coding\"}}"
  let #(outcome, events, calls) =
    run(pool, [
      bit_array.from_string(
        prefix() <> "event: error\ndata: " <> error <> "\n\n",
      ),
    ])
  outcome |> should.equal(Ok(stream.RemoteError))
  let assert [_, stream.NamedErrorEvent(document)] = events
  ir.parse(error) |> should.equal(Ok(document))
  cancel_count(calls) |> should.equal(1)
  runtime.stop(pool) |> should.be_ok
}

pub fn cancel_and_downstream_failure_stop_before_further_pull_test() {
  let pool = start("http://127.0.0.1:8000")
  list.each(
    [Ok(http.Cancel), Error("synthetic downstream closed")],
    fn(control) {
      let calls = process.new_subject()
      let emitted = process.new_subject()
      let assert Ok(opened) =
        runtime.open(
          pool,
          stub(
            [bit_array.from_string(prefix()), bit_array.from_string(terminal())],
            200,
            sse_headers(),
            calls,
          ),
          req(),
        )
      let outcome =
        adapter.run_chat_for(opened, req(), fn(event) {
          process.send(emitted, event)
          control
        })
      outcome
      |> should.equal(case control {
        Ok(_) -> Ok(stream.Cancelled)
        Error(_) -> Error(c.Failure(c.Cancelled, c.Started, None))
      })
      list.length(drain(emitted)) |> should.equal(1)
      drain(calls) |> should.equal([Pull, Cancel])
      runtime.active_leases(pool) |> should.equal(Ok(0))
    },
  )
  runtime.stop(pool) |> should.be_ok
}

pub fn invalid_headers_cancel_without_pulling_test() {
  let pool = start("http://127.0.0.1:8000")
  list.each(
    [
      #(302, sse_headers()),
      #(200, []),
      #(200, [Header("Content-Type", "application/json")]),
      #(200, [Header("Content-Type", "text/event-stream-bogus")]),
      #(200, [Header("Content-Type", "text/event-stream; charset=latin1")]),
      #(200, [Header("content-type", "text/event-stream"), ..sse_headers()]),
      #(200, [Header("Content-Encoding", "gzip"), ..sse_headers()]),
      #(200, [
        Header("Content-Encoding", "identity"),
        Header("content-encoding", "identity"),
        ..sse_headers()
      ]),
    ],
    fn(spec) {
      let #(status, headers) = spec
      let calls = process.new_subject()
      let assert Ok(opened) =
        runtime.open(pool, stub([], status, headers, calls), req())
      adapter.run_chat_for(opened, req(), fn(_) {
        panic as "Invalid headers reached downstream"
      })
      |> should.equal(Error(c.Failure(c.InvalidResponse, c.Started, None)))
      drain(calls) |> should.equal([Cancel])
      runtime.active_leases(pool) |> should.equal(Ok(0))
    },
  )
  runtime.stop(pool) |> should.be_ok
}

pub fn simultaneous_streams_do_not_share_tool_or_terminal_state_test() {
  let pool = start("http://127.0.0.1:8000")
  let calls_a = process.new_subject()
  let calls_b = process.new_subject()
  let assert Ok(a) =
    runtime.open(
      pool,
      stub([bit_array.from_string(full())], 200, sse_headers(), calls_a),
      c.Request(..req(), session: "client-a:session"),
    )
  let assert Ok(b) =
    runtime.open(
      pool,
      stub(
        [
          bit_array.from_string(
            full()
            |> string.replace("lookup", "other_lookup")
            |> string.replace("call_synthetic", "other_call"),
          ),
        ],
        200,
        sse_headers(),
        calls_b,
      ),
      c.Request(..req(), session: "client-b:session"),
    )
  runtime.active_leases(pool) |> should.equal(Ok(2))
  adapter.run_chat_for(a, req(), fn(_) { Ok(http.Continue) })
  |> should.equal(Ok(stream.Completed))
  runtime.active_leases(pool) |> should.equal(Ok(1))
  adapter.run_chat_for(b, req(), fn(_) { Ok(http.Continue) })
  |> should.equal(Ok(stream.Completed))
  cancel_count(drain(calls_a)) |> should.equal(1)
  cancel_count(drain(calls_b)) |> should.equal(1)
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}

pub fn adopted_runner_owns_pull_and_cancel_test() {
  let pool = start("http://127.0.0.1:8000")
  let calls = process.new_subject()
  let assert Ok(opened) =
    runtime.open(
      pool,
      stub([bit_array.from_string(full())], 200, sse_headers(), calls),
      req(),
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
        adapter.run_chat_for(opened, req(), fn(_) { Ok(http.Continue) }),
      )
    })
  let assert Ok(go) = process.receive(ready, 3000)
  runtime.next(opened.stream) |> should.be_error
  runtime.adopt(opened.stream) |> should.be_error
  process.send(go, Nil)
  process.receive(done, 3000) |> should.equal(Ok(Ok(stream.Completed)))
  cancel_count(drain(calls)) |> should.equal(1)
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}

fn wire(payload: String) -> BitArray {
  bit_array.from_string(
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: "
    <> int.to_string(string.byte_size(payload))
    <> "\r\nConnection: close\r\n\r\n"
    <> payload,
  )
}

pub fn real_socket_native_chat_and_nested_media_rejection_test() {
  let assert Ok(server) = server_start(wire(full()))
  let pool = start("http://127.0.0.1:" <> int.to_string(port(server)))
  let transport = request.http_at(fn(_) { Ok("/tenant/generic/v1") }, None)
  let assert Ok(opened) = runtime.open(pool, transport, req())
  adapter.run_chat_for(opened, req(), fn(_) { Ok(http.Continue) })
  |> should.equal(Ok(stream.Completed))
  let assert [raw] = observed(server)
  let assert Ok(raw) = bit_array.to_string(raw)
  string.starts_with(
    raw,
    "POST /tenant/generic/v1/chat/completions HTTP/1.1\r\n",
  )
  |> should.be_true
  string.contains(raw, "Accept: text/event-stream\r\n") |> should.be_true
  string.contains(raw, req().body) |> should.be_true
  string.contains(string.lowercase(raw), "x-msh-") |> should.be_false
  list.each(["assistant", "tool", "system", "developer", "user"], fn(role) {
    let body =
      "{\"model\":\"kimi-k2.8\",\"stream\":true,\"messages\":[{\"role\":\""
      <> role
      <> "\",\"tool_call_id\":\"synthetic\",\"content\":[{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"AA==\",\"format\":\"wav\"}}]}]}"
    runtime.open(pool, transport, c.Request(..req(), body: body))
    |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  })
  list.length(observed(server)) |> should.equal(1)
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
  stop(server)
}
