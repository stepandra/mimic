import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/protocol/responses/frames
import mimic/protocol/responses/http
import mimic/protocol/responses/sparse
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket as ws
import mimic/types.{type Header, Header}
import responses_sparse_test as fixture

// SYNTHETIC loopback HTTP/RFC6455 transport tests. Not the root gateway, CPA,
// WSS/TLS, provider/native-client execution, or a measured external capture.
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

fn write_text(socket: Socket, text: String) {
  let assert Ok(Nil) = write(socket, bit_array.from_string(text))
  Nil
}

fn read_line(socket: Socket) -> String {
  let assert Ok(Some(bytes)) = read(socket, 0)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn read_headers(socket: Socket, count: Int) -> List(Header) {
  let assert True = count < 32
  case read_line(socket) {
    "\r\n" -> []
    line -> {
      let assert Ok(#(name, value)) = string.split_once(line, ":")
      [Header(name, string.trim(value)), ..read_headers(socket, count + 1)]
    }
  }
}

type HttpCase {
  Complete
  Corrupt
  Cancel
  WriteFailure
}

fn http_case(mode: HttpCase) {
  let assert Ok(#(listener, port)) = listen()
  let ready = process.new_subject()
  let stopped = process.new_subject()
  let emitted = process.new_subject()
  let cleaned = process.new_subject()
  let _server =
    process.spawn(fn() {
      let ack = process.new_subject()
      process.send(ready, ack)
      let assert Ok(socket) = accept(listener)
      let assert Ok(Nil) = line_mode(socket, True)
      read_line(socket) |> should.equal("POST /v1/responses HTTP/1.1\r\n")
      read_headers(socket, 0) |> list.length |> should.equal(2)
      let assert Ok(Nil) = line_mode(socket, False)
      write_text(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nConnection: close\r\n\r\n",
      )
      write_text(socket, "data: " <> fixture.metadata() <> "\n\n")
      // No remaining output before the decoded metadata event is delivered.
      process.receive(ack, 3000) |> should.equal(Ok(Nil))
      case mode {
        Cancel | WriteFailure -> read(socket, 1) |> should.equal(Ok(None))
        _ -> {
          write_text(
            socket,
            "data: "
              <> fixture.done()
              <> "\n\n"
              <> "data: "
              <> fixture.completed()
              <> "\n\n"
              <> case mode {
              Corrupt -> "data: {invalid}\n\n"
              _ -> ""
            },
          )
        }
      }
      close(socket)
      process.send(stopped, Nil)
    })
  let assert Ok(ack) = process.receive(ready, 3000)
  let assert Ok(socket) = connect(port)
  write_text(
    socket,
    "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n",
  )
  let assert Ok(Nil) = line_mode(socket, True)
  read_line(socket) |> should.equal("HTTP/1.1 200 OK\r\n")
  let headers = read_headers(socket, 0)
  let assert Ok(Nil) = line_mode(socket, False)
  let assert Ok(state) =
    http.open_sse_with_policy(200, headers, fixture.policy(sparse.Transparent))
  let outcome =
    http.run_wire_fold(
      state,
      socket,
      fn(socket) {
        use bytes <- result.try(read(socket, 1))
        Ok(case bytes {
          None -> None
          Some(bytes) -> Some(#(bytes, socket))
        })
      },
      fn(socket) {
        close(socket)
        process.send(cleaned, Nil)
      },
      [],
      fn(acc, event) {
        let data = stream.wire_data(event)
        process.send(emitted, data)
        case stream.wire_event(event).name {
          "codex.response.metadata" -> process.send(ack, Nil)
          _ -> Nil
        }
        case mode {
          Cancel -> Ok(#(list.append(acc, [data]), http.Cancel))
          WriteFailure -> Error("synthetic downstream failed")
          _ -> Ok(#(list.append(acc, [data]), http.Continue))
        }
      },
    )
  case mode {
    Complete -> {
      let assert Ok(#(stream.Completed, Some(report), data)) = outcome
      data
      |> should.equal([fixture.metadata(), fixture.done(), fixture.completed()])
      sparse.authority(report)
      |> should.equal(sparse.Ineligible([sparse.MissingCreated]))
    }
    Corrupt -> outcome |> should.equal(Error(http.Protocol("invalid JSON")))
    Cancel ->
      outcome
      |> should.equal(Ok(#(stream.Cancelled, None, [fixture.metadata()])))
    WriteFailure ->
      outcome
      |> should.equal(Error(http.Downstream("synthetic downstream failed")))
  }
  process.receive(stopped, 3000) |> should.equal(Ok(Nil))
  process.receive(cleaned, 0) |> should.equal(Ok(Nil))
  process.receive(cleaned, 0) |> should.be_error
  process.receive(emitted, 0) |> should.equal(Ok(fixture.metadata()))
  case mode {
    Complete | Corrupt -> {
      process.receive(emitted, 0) |> should.equal(Ok(fixture.done()))
      process.receive(emitted, 0) |> should.equal(Ok(fixture.completed()))
    }
    _ -> Nil
  }
  process.receive(emitted, 0) |> should.be_error
  close(listener)
}

pub fn http_fragmented_sparse_events_before_clean_eof_test() {
  http_case(Complete)
}

pub fn http_trailing_corruption_keeps_valid_prefix_not_report_test() {
  http_case(Corrupt)
}

pub fn http_local_cancel_closes_the_actual_owned_socket_test() {
  http_case(Cancel)
}

pub fn http_downstream_failure_closes_the_actual_owned_socket_test() {
  http_case(WriteFailure)
}

fn scope() -> ws.Scope {
  ws.Scope(
    "tenant",
    "codex",
    "synthetic-credential",
    "account",
    "synthetic",
    "client",
  )
}

fn key() -> String {
  "dGhlIHNhbXBsZSBub25jZQ=="
}

fn mask() -> Option(BitArray) {
  Some(<<1, 2, 3, 4>>)
}

fn read_frame(
  socket: Socket,
  decoder: frames.Decoder,
) -> Result(#(frames.Decoder, frames.Event), String) {
  use bytes <- result.try(read(socket, 1))
  case bytes {
    None -> Error("synthetic unexpected EOF")
    Some(bytes) -> {
      use pair <- result.try(frames.feed_one(decoder, bytes))
      let #(decoder, event, rest) = pair
      let assert <<>> = rest
      case event {
        None -> read_frame(socket, decoder)
        Some(event) -> Ok(#(decoder, event))
      }
    }
  }
}

type WsCase {
  WsComplete
  WsCorrupt
  WsCancel
}

fn websocket_case(mode: WsCase) {
  let assert Ok(#(listener, port)) = listen()
  let ready = process.new_subject()
  let stopped = process.new_subject()
  let _server =
    process.spawn(fn() {
      let ack = process.new_subject()
      process.send(ready, ack)
      let assert Ok(socket) = accept(listener)
      let assert Ok(Nil) = line_mode(socket, True)
      read_line(socket) |> should.equal("GET /v1/responses HTTP/1.1\r\n")
      let headers = read_headers(socket, 0)
      let assert Ok(upgrade) = frames.server_upgrade("GET", headers)
      let header_text =
        upgrade
        |> list.map(fn(header) { header.name <> ": " <> header.value <> "\r\n" })
        |> string.join("")
      write_text(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\n" <> header_text <> "\r\n",
      )
      let assert Ok(Nil) = line_mode(socket, False)
      let assert Ok(decoder) = frames.new(frames.Server, 1024, 1024)
      let assert Ok(#(decoder, frames.Text(create))) =
        read_frame(socket, decoder)
      let assert Ok(create) = ir.parse(create)
      ir.field(create, "type")
      |> should.equal(Some(ir.String("response.create")))
      ir.field(create, "model") |> should.equal(Some(ir.String("synthetic")))
      ir.field(create, "input") |> should.equal(Some(ir.Array([])))
      let assert Ok(bytes) =
        frames.encode_text(frames.Server, fixture.metadata(), None)
      let assert Ok(Nil) = write(socket, bytes)
      process.receive(ack, 3000) |> should.equal(Ok(Nil))
      case mode {
        WsCancel -> read(socket, 1) |> should.equal(Ok(None))
        _ -> {
          list.each([fixture.done(), fixture.completed()], fn(data) {
            let assert Ok(bytes) = frames.encode_text(frames.Server, data, None)
            let assert Ok(Nil) = write(socket, bytes)
          })
          case mode {
            WsCorrupt -> {
              // Masked upstream frame is invalid for the receiving client role.
              let assert Ok(bytes) =
                frames.encode_text(frames.Client, "bad", mask())
              let assert Ok(Nil) = write(socket, bytes)
              read(socket, 1) |> should.equal(Ok(None))
            }
            _ -> {
              let assert Ok(bytes) =
                frames.encode_close(frames.Server, Some(1000), "", None)
              let assert Ok(Nil) = write(socket, bytes)
              let assert Ok(#(_, frames.Close(Some(1000), _))) =
                read_frame(socket, decoder)
              Nil
            }
          }
        }
      }
      close(socket)
      process.send(stopped, Nil)
    })
  let assert Ok(ack) = process.receive(ready, 3000)
  let assert Ok(socket) = connect(port)
  write_text(
    socket,
    "GET /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: "
      <> key()
      <> "\r\n\r\n",
  )
  let assert Ok(Nil) = line_mode(socket, True)
  read_line(socket) |> should.equal("HTTP/1.1 101 Switching Protocols\r\n")
  let headers = read_headers(socket, 0)
  frames.client_upgrade(101, headers, key()) |> should.equal(Ok(Nil))
  let assert Ok(Nil) = line_mode(socket, False)
  let assert Ok(session) =
    ws.new_with_policy(
      scope(),
      "physical-socket",
      fixture.policy(sparse.Transparent),
    )
  let assert Ok(#(session, request)) =
    ws.create(
      session,
      scope(),
      "physical-socket",
      "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":[]}",
    )
  let assert Ok(create) = ws.encode_create(request)
  let assert Ok(bytes) = frames.encode_text(frames.Client, create, mask())
  let assert Ok(Nil) = write(socket, bytes)
  let assert Ok(decoder) = frames.new(frames.Client, 1024, 1024)
  let observed = process.new_subject()
  let result = ws_messages(socket, decoder, session, mode, ack, observed)
  case mode {
    WsComplete -> {
      let assert Ok(session) = result
      ws.create(
        session,
        scope(),
        "physical-socket",
        "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":[],\"previous_response_id\":\"resp_1\"}",
      )
      |> should.be_error
      Nil
    }
    WsCancel -> {
      result |> should.be_ok
      Nil
    }
    WsCorrupt -> {
      result |> should.be_error
      Nil
    }
  }
  close(socket)
  process.receive(stopped, 3000) |> should.equal(Ok(Nil))
  process.receive(observed, 0) |> should.equal(Ok(fixture.metadata()))
  case mode {
    WsCancel -> Nil
    _ -> {
      process.receive(observed, 0) |> should.equal(Ok(fixture.done()))
      process.receive(observed, 0) |> should.equal(Ok(fixture.completed()))
    }
  }
  process.receive(observed, 0) |> should.be_error
  close(listener)
}

fn ws_messages(
  socket: Socket,
  decoder: frames.Decoder,
  session: ws.Session,
  mode: WsCase,
  ack: process.Subject(Nil),
  observed: process.Subject(String),
) -> Result(ws.Session, String) {
  use pair <- result.try(read_frame(socket, decoder))
  let #(decoder, frame) = pair
  case frame {
    frames.Close(_, _) -> {
      use _ <- result.try(frames.finish(decoder))
      use _ <- result.try(ws.disconnected(session))
      let assert Ok(bytes) =
        frames.encode_close(frames.Client, Some(1000), "", mask())
      let assert Ok(Nil) = write(socket, bytes)
      Ok(session)
    }
    frames.Text(data) -> {
      use pair <- result.try(ws.receive_wire(
        session,
        scope(),
        "physical-socket",
        data,
      ))
      process.send(observed, stream.wire_data(pair.1))
      case data == fixture.metadata() {
        True -> process.send(ack, Nil)
        False -> Nil
      }
      case mode {
        WsCancel -> {
          let #(session, cleanup) = ws.cancel(pair.0)
          cleanup |> should.be_true
          close(socket)
          Ok(session)
        }
        _ -> ws_messages(socket, decoder, pair.0, mode, ack, observed)
      }
    }
    _ -> Error("unexpected synthetic WS control")
  }
}

pub fn websocket_upgrade_masked_create_fragmented_sparse_and_close_test() {
  websocket_case(WsComplete)
}

pub fn websocket_transport_corruption_does_not_erase_valid_prefix_test() {
  websocket_case(WsCorrupt)
}

pub fn websocket_local_cancel_closes_the_actual_owned_socket_test() {
  websocket_case(WsCancel)
}
