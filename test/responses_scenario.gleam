import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/http
import mimic/protocol/responses/stream
import mimic/types.{type Header, Header}

// SYNTHETIC: actual TCP/HTTP loopback, no assembled ingress or live provider.
pub type Mode {
  Complete
  Incomplete
  RemoteError
  Disconnect
  Cancel
  DownstreamFailure
}

pub type Socket

@external(erlang, "mimic_responses_http_test_ffi", "listen")
fn listen() -> Result(#(Socket, Int), String)

@external(erlang, "mimic_responses_http_test_ffi", "accept")
fn accept(listener: Socket) -> Result(Socket, String)

@external(erlang, "mimic_responses_http_test_ffi", "connect")
fn connect(port: Int) -> Result(Socket, String)

@external(erlang, "mimic_responses_http_test_ffi", "line_mode")
fn line_mode(socket: Socket, enabled: Bool) -> Result(Nil, String)

@external(erlang, "mimic_responses_http_test_ffi", "read")
fn read(socket: Socket, count: Int) -> Result(Option(BitArray), String)

@external(erlang, "mimic_responses_http_test_ffi", "write")
fn write(socket: Socket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "mimic_responses_http_test_ffi", "close")
fn close(socket: Socket) -> Nil

fn write_text(socket: Socket, text: String) -> Nil {
  let assert Ok(Nil) = write(socket, bit_array.from_string(text))
  Nil
}

fn read_text(socket: Socket, count: Int) -> String {
  let assert Ok(Some(bytes)) = read(socket, count)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn read_headers(socket: Socket, count: Int) -> List(Header) {
  let assert True = count < 32
  case read_text(socket, 0) {
    "\r\n" -> []
    line -> {
      let assert Ok(#(name, value)) = string.split_once(line, ":")
      [Header(name, string.trim(value)), ..read_headers(socket, count + 1)]
    }
  }
}

fn body_length(headers: List(Header)) -> Int {
  let assert [header] =
    list.filter(headers, fn(h) { string.lowercase(h.name) == "content-length" })
  let assert Ok(length) = int.parse(header.value)
  length
}

fn created() -> String {
  "data: {\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_http\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
}

fn terminal(mode: Mode) -> String {
  case mode {
    Complete ->
      "data: {\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_http\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":2,\"output_tokens\":0,\"total_tokens\":2}}}\n\n"
    Incomplete ->
      "data: {\"type\":\"response.incomplete\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_http\",\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n"
    _ ->
      "data: {\"type\":\"error\",\"error\":{\"code\":\"synthetic_failure\",\"message\":\"local mock only\"}}\n\n"
  }
}

pub fn exercise(mode: Mode) -> List(String) {
  let assert Ok(#(listener, port)) = listen()
  let ready = process.new_subject()
  let stopped = process.new_subject()
  let emitted = process.new_subject()
  let _pid =
    process.spawn(fn() {
      let ack = process.new_subject()
      process.send(ready, ack)
      let assert Ok(socket) = accept(listener)
      let assert Ok(Nil) = line_mode(socket, True)
      read_text(socket, 0) |> should.equal("POST /v1/responses HTTP/1.1\r\n")
      let request_headers = read_headers(socket, 0)
      let assert Ok(Nil) = line_mode(socket, False)
      let body = read_text(socket, body_length(request_headers))
      let assert Ok(request) = responses.decode_request(body)
      request.model |> should.equal("synthetic-local-model")
      request.stream |> should.be_true
      // Close-delimited HTTP response; framing policy belongs to the transport.
      write_text(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nConnection: close\r\n\r\n",
      )
      write_text(socket, created())
      // No terminal bytes are sent until the *decoded first event* is delivered.
      // This catches full-stream buffering with a real socket, not a timing claim.
      let assert Ok(Nil) = process.receive(ack, 3000)
      case mode {
        Disconnect -> {
          close(socket)
          process.send(stopped, True)
        }
        Cancel | DownstreamFailure -> {
          read(socket, 0) |> should.equal(Ok(None))
          close(socket)
          process.send(stopped, True)
        }
        _ -> {
          write_text(socket, terminal(mode))
          // Early terminal must cause the client owner to cancel/close.
          read(socket, 0) |> should.equal(Ok(None))
          close(socket)
          process.send(stopped, True)
        }
      }
    })
  let assert Ok(ack) = process.receive(ready, 3000)
  let assert Ok(socket) = connect(port)
  let assert Ok(request) =
    responses.decode_request(
      "{\"model\":\"synthetic-local-model\",\"stream\":true,\"input\":\"synthetic only\"}",
    )
  let body = responses.encode_request(request)
  write_text(
    socket,
    "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
      <> int.to_string(bit_array.byte_size(bit_array.from_string(body)))
      <> "\r\n\r\n"
      <> body,
  )
  let assert Ok(Nil) = line_mode(socket, True)
  read_text(socket, 0) |> should.equal("HTTP/1.1 200 OK\r\n")
  let headers = read_headers(socket, 0)
  let assert Ok(Nil) = line_mode(socket, False)
  let assert Ok(state) = http.open_sse(200, headers)
  let outcome =
    http.run(
      state,
      socket,
      fn(socket) {
        use data <- result.try(read(socket, 0))
        Ok(option_map_socket(data, socket))
      },
      close,
      fn(event) {
        process.send(emitted, event.name)
        case event.name {
          "response.created" -> process.send(ack, Nil)
          _ -> Nil
        }
        case mode {
          Cancel -> Ok(http.Cancel)
          DownstreamFailure -> Error("synthetic downstream disconnected")
          _ -> Ok(http.Continue)
        }
      },
    )
  case mode {
    Complete -> outcome |> should.equal(Ok(stream.Completed))
    Incomplete -> outcome |> should.equal(Ok(stream.Incomplete))
    RemoteError -> outcome |> should.equal(Ok(stream.RemoteError))
    Cancel -> outcome |> should.equal(Ok(stream.Cancelled))
    DownstreamFailure ->
      outcome
      |> should.equal(
        Error(http.Downstream("synthetic downstream disconnected")),
      )
    Disconnect ->
      outcome
      |> should.equal(
        Error(http.Protocol("Responses disconnected before protocol terminal")),
      )
  }
  process.receive(stopped, 3000) |> should.equal(Ok(True))
  close(listener)
  drain(emitted)
}

fn option_map_socket(
  data: Option(BitArray),
  socket: Socket,
) -> Option(#(BitArray, Socket)) {
  case data {
    None -> None
    Some(data) -> Some(#(data, socket))
  }
}

fn drain(subject: process.Subject(String)) -> List(String) {
  case process.receive(subject, 0) {
    Ok(value) -> [value, ..drain(subject)]
    Error(_) -> []
  }
}

/// Run independently: gleam run -m responses_scenario
pub fn main() {
  let modes = [
    Complete,
    Incomplete,
    RemoteError,
    Disconnect,
    Cancel,
    DownstreamFailure,
  ]
  let observations =
    list.map(modes, fn(mode) { ir.Array(list.map(exercise(mode), ir.String)) })
  io.println(
    ir.stringify(
      ir.Object([
        #("synthetic", ir.Boolean(True)),
        #("assembled_ingress", ir.Boolean(False)),
        #("real_loopback_http", ir.Boolean(True)),
        #("observed_event_sequences", ir.Array(observations)),
      ]),
    ),
  )
}
