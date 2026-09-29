/// SYNTHETIC loopback HTTP/1.1 Chat SSE; no live Kimi calls or credentials.
/// The fixture writes frame fragments to a socket, while runtime owns the
/// request, transport, stream lease, and cancellation.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/chat/stream
import mimic/protocol/responses/http
import mimic/providers/contracts
import mimic/providers/kimi/adapter
import mimic/providers/kimi/models
import mimic/providers/kimi/request as kimi_request
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{type Header, Header}

type Socket

type Mode {
  Complete
  Disconnect
  Cancel
}

@external(erlang, "mimic_responses_http_test_ffi", "listen")
fn listen() -> Result(#(Socket, Int), String)

@external(erlang, "mimic_responses_http_test_ffi", "accept")
fn accept(listener: Socket) -> Result(Socket, String)

@external(erlang, "mimic_responses_http_test_ffi", "line_mode")
fn line_mode(socket: Socket, enabled: Bool) -> Result(Nil, String)

@external(erlang, "mimic_responses_http_test_ffi", "read")
fn read(socket: Socket, count: Int) -> Result(Option(BitArray), String)

@external(erlang, "mimic_responses_http_test_ffi", "write")
fn write(socket: Socket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "mimic_responses_http_test_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn state_directory() -> String

fn send(socket: Socket, text: String) {
  write(socket, bit_array.from_string(text)) |> should.equal(Ok(Nil))
}

fn chunk(socket: Socket, bytes: BitArray) {
  send(socket, int.to_base16(bit_array.byte_size(bytes)) <> "\r\n")
  write(socket, bytes) |> should.equal(Ok(Nil))
  send(socket, "\r\n")
}

fn text_chunk(socket: Socket, value: String) {
  chunk(socket, bit_array.from_string(value))
}

fn text(socket: Socket, size: Int) -> String {
  let assert Ok(Some(bytes)) = read(socket, size)
  let assert Ok(value) = bit_array.to_string(bytes)
  value
}

fn headers(socket: Socket, count: Int) -> List(Header) {
  let assert True = count < 32
  case text(socket, 0) {
    "\r\n" -> []
    line -> {
      let assert Ok(#(name, value)) = string.split_once(line, ":")
      [Header(name, string.trim(value)), ..headers(socket, count + 1)]
    }
  }
}

fn header(headers: List(Header), name: String) -> String {
  let assert Ok(found) =
    list.find(headers, fn(h) { string.lowercase(h.name) == name })
  found.value
}

fn event(choices: String, extra: String) -> String {
  "data: {\"id\":\"synthetic-chat\",\"object\":\"chat.completion.chunk\",\"model\":\"kimi-for-coding\",\"choices\":"
  <> choices
  <> extra
  <> "}\n\n"
}

fn reasoning() -> String {
  event(
    "[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning_content\":\"synthetic 思考\"},\"finish_reason\":null}]",
    "",
  )
}

fn tool_start() -> String {
  event(
    "[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\"}}]},\"finish_reason\":null}]",
    "",
  )
}

fn tool_end() -> String {
  event(
    "[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"synthetic\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]",
    "",
  )
}

fn usage() -> String {
  event(
    "[]",
    ",\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5},\"native_extension\":true",
  )
}

fn serve(
  listener: Socket,
  mode: Mode,
  ready: process.Subject(#(process.Subject(Nil), process.Subject(Nil))),
  observed: process.Subject(#(String, List(Header), String)),
  stopped: process.Subject(Bool),
) {
  let proceed = process.new_subject()
  let ack = process.new_subject()
  process.send(ready, #(proceed, ack))
  let assert Ok(socket) = accept(listener)
  let assert Ok(Nil) = line_mode(socket, True)
  let line = text(socket, 0)
  let request_headers = headers(socket, 0)
  let assert Ok(Nil) = line_mode(socket, False)
  let assert Ok(length) = int.parse(header(request_headers, "content-length"))
  let body = text(socket, length)
  process.send(observed, #(line, request_headers, body))
  send(
    socket,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n",
  )
  // Split within the UTF-8 codepoint as well as across the SSE frame.
  let assert Ok(#(prefix, suffix)) = string.split_once(reasoning(), "思")
  let bytes = bit_array.from_string("思")
  let assert Ok(first) = bit_array.slice(bytes, 0, 1)
  let assert Ok(rest) = bit_array.slice(bytes, 1, 2)
  text_chunk(socket, prefix)
  chunk(socket, first)
  // The client must have opened the actual runtime response before the rest.
  process.receive(proceed, 3000) |> should.equal(Ok(Nil))
  chunk(socket, rest)
  text_chunk(socket, suffix)
  process.receive(ack, 3000) |> should.equal(Ok(Nil))
  case mode {
    Complete -> {
      // Event delivery gates subsequent bytes: this cannot pass by buffering
      // the entire HTTP response before invoking the callback.
      list.each(
        [tool_start(), tool_end(), usage(), "data: [DONE]\n\n"],
        fn(frame) {
          let #(front, back) = case string.split_once(frame, "arguments") {
            Ok(#(before, after)) ->
              case string.split_once(after, "synthetic") {
                // The second tool delta is split *inside* its argument value.
                Ok(#(start, end)) -> #(
                  before <> "arguments" <> start <> "synt",
                  "hetic" <> end,
                )
                Error(_) -> #(before <> "arg", "uments" <> after)
              }
            Error(_) -> #(frame, "")
          }
          text_chunk(socket, front)
          case back {
            "" -> Nil
            _ -> text_chunk(socket, back)
          }
          case frame {
            "data: [DONE]\n\n" -> send(socket, "0\r\n\r\n")
            _ -> Nil
          }
          process.receive(ack, 3000) |> should.equal(Ok(Nil))
        },
      )
      read(socket, 0) |> should.equal(Ok(None))
      close(socket)
    }
    Disconnect -> close(socket)
    Cancel -> {
      // Synchronous callback cancellation closes the upstream connection
      // without waiting for another frame or a server-side terminal.
      read(socket, 0) |> should.equal(Ok(None))
      close(socket)
    }
  }
  process.send(stopped, True)
}

fn run_case(
  mode: Mode,
) -> #(Result(stream.Outcome, contracts.Failure), List(stream.Event)) {
  let assert Ok(#(listener, port)) = listen()
  let ready = process.new_subject()
  let observed = process.new_subject()
  let stopped = process.new_subject()
  let emitted = process.new_subject()
  let _server =
    process.spawn(fn() { serve(listener, mode, ready, observed, stopped) })
  let assert Ok(#(proceed, ack)) = process.receive(ready, 3000)
  let assert Ok(store) = storage.new(state_directory())
  credentials.save_api_key(
    store,
    credentials.key("kimi", "api_key", "synthetic-account"),
    "synthetic-loopback-key",
  )
  |> should.be_ok
  let assert Ok(model) = models.registration("kimi-k2.8")
  let assert Ok(catalog) = registry.new([model])
  let assert Ok(pool) =
    runtime.start(store, catalog, [
      runtime.Account(
        "kimi",
        "api_key",
        "synthetic-account",
        "http://127.0.0.1:" <> int.to_string(port),
        fleet.LocalLoopback,
        1,
        ["kimi-k2.8"],
        credentials.StaticKey,
      ),
    ])
  let request =
    contracts.Request(
      "kimi",
      "api_key",
      "kimi-k2.8",
      "chat",
      "chat/completions",
      contracts.Streaming,
      [contracts.Stream, contracts.Tools],
      "synthetic-session",
      None,
      "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic prompt\"}],\"stream\":true}",
    )
  let assert Ok(response) =
    runtime.open(
      pool,
      kimi_request.http_at(fn(_) { Ok("/tenant/kimi") }, None),
      request,
    )
  response.account |> should.equal("synthetic-account")
  process.send(proceed, Nil)
  let outcome =
    adapter.run_chat_for(response, request, fn(event) {
      process.send(emitted, event)
      process.send(ack, Nil)
      case mode {
        Cancel -> Ok(http.Cancel)
        _ -> Ok(http.Continue)
      }
    })
  let assert Ok(#(line, request_headers, body)) =
    process.receive(observed, 3000)
  line |> should.equal("POST /tenant/kimi/v1/chat/completions HTTP/1.1\r\n")
  header(request_headers, "authorization")
  |> should.equal("Bearer synthetic-loopback-key")
  header(request_headers, "accept") |> should.equal("text/event-stream")
  let assert Ok(document) = ir.parse(body)
  ir.string_field(document, "model") |> should.equal(Ok("kimi-for-coding"))
  ir.field(document, "stream") |> should.equal(Some(ir.Boolean(True)))
  process.receive(stopped, 3000) |> should.equal(Ok(True))
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
  close(listener)
  #(outcome, drain(emitted))
}

fn drain(subject: process.Subject(stream.Event)) -> List(stream.Event) {
  case process.receive(subject, 0) {
    Ok(value) -> [value, ..drain(subject)]
    Error(_) -> []
  }
}

fn document(event: stream.Event) -> ir.Value {
  let assert stream.Event(value) = event
  ir.field(value, "model") |> should.equal(Some(ir.String("kimi-k2.8")))
  value
}

fn choice(document: ir.Value) -> ir.Value {
  let assert Ok(choices) = ir.required(document, "choices")
  let assert Ok([first]) = ir.as_array(choices)
  first
}

fn delta(choice: ir.Value) -> ir.Value {
  let assert Ok(value) = ir.required(choice, "delta")
  value
}

fn tool_arguments(choice: ir.Value) -> String {
  let assert Ok(calls) = ir.required(delta(choice), "tool_calls")
  let assert Ok([call]) = ir.as_array(calls)
  let assert Ok(function) = ir.required(call, "function")
  let assert Ok(args) = ir.string_field(function, "arguments")
  args
}

pub fn native_chat_stream_restores_model_tools_reasoning_usage_and_done_test() {
  let #(outcome, events) = run_case(Complete)
  outcome |> should.equal(Ok(stream.Completed))
  let assert [reason, first, last, stats, stream.Done] = events
  ir.string_field(delta(choice(document(reason))), "reasoning_content")
  |> should.equal(Ok("synthetic 思考"))
  let first_choice = choice(document(first))
  tool_arguments(first_choice) |> should.equal("{\"q\":")
  let assert Ok(calls) = ir.required(delta(first_choice), "tool_calls")
  let assert Ok([call]) = ir.as_array(calls)
  ir.string_field(call, "id") |> should.equal(Ok("call_1"))
  let assert Ok(function) = ir.required(call, "function")
  ir.string_field(function, "name") |> should.equal(Ok("lookup"))
  let last_choice = choice(document(last))
  tool_arguments(last_choice) |> should.equal("\"synthetic\"}")
  ir.field(last_choice, "finish_reason")
  |> should.equal(Some(ir.String("tool_calls")))
  let stats = document(stats)
  let assert Ok(usage) = ir.required(stats, "usage")
  ir.field(usage, "prompt_tokens") |> should.equal(Some(ir.Integer(2)))
  ir.field(usage, "completion_tokens") |> should.equal(Some(ir.Integer(3)))
  ir.field(usage, "total_tokens") |> should.equal(Some(ir.Integer(5)))
  ir.field(stats, "native_extension") |> should.equal(Some(ir.Boolean(True)))
}

pub fn native_chat_disconnect_is_not_a_terminal_and_releases_lease_test() {
  let #(outcome, events) = run_case(Disconnect)
  outcome
  |> should.equal(
    Error(contracts.Failure(contracts.InvalidResponse, contracts.Started, None)),
  )
  let assert [reason] = events
  ir.string_field(delta(choice(document(reason))), "reasoning_content")
  |> should.equal(Ok("synthetic 思考"))
}

pub fn native_chat_synchronous_cancel_closes_socket_and_releases_lease_test() {
  let #(outcome, events) = run_case(Cancel)
  outcome |> should.equal(Ok(stream.Cancelled))
  let assert [reason] = events
  ir.string_field(delta(choice(document(reason))), "reasoning_content")
  |> should.equal(Ok("synthetic 思考"))
}
