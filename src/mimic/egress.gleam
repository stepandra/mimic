import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import mimic/types.{
  type Capture, type Header, type WireResponse, Header, WireResponse,
}
import mimic/wire

const timeout_ms = 5000

const call_timeout_ms = 12_000

const max_header_bytes = 65_536

const max_line_bytes = 8192

const max_body_bytes = 8_388_608

pub opaque type Client {
  Client(subject: process.Subject(Message), pid: process.Pid)
}

type Origin {
  Origin(scheme: String, host: String, port: Int)
}

type State {
  State(origin: Origin, socket: Option(Socket))
}

type Message {
  Send(Capture, process.Subject(Result(WireResponse, String)))
  Close(process.Subject(Result(Nil, String)))
}

type Reply(value) {
  Answer(value)
  ActorDown
}

type Socket

@external(erlang, "mimic_egress_ffi", "connect")
fn connect(
  host: String,
  port: Int,
  tls: Bool,
  timeout: Int,
) -> Result(Socket, String)

@external(erlang, "mimic_egress_ffi", "write")
fn write(socket: Socket, bytes: String, timeout: Int) -> Result(Nil, String)

@external(erlang, "mimic_egress_ffi", "line")
fn line(socket: Socket, timeout: Int) -> Result(String, String)

@external(erlang, "mimic_egress_ffi", "bytes")
fn bytes(socket: Socket, length: Int, timeout: Int) -> Result(BitArray, String)

@external(erlang, "mimic_egress_ffi", "probe")
fn probe(socket: Socket) -> Result(Bool, String)

@external(erlang, "mimic_egress_ffi", "close")
fn close_socket(socket: Socket) -> Nil

@external(erlang, "mimic_egress_ffi", "now_ms")
fn now_ms() -> Int

/// Opens a serial, reusable direct HTTP/1.1 client. The first connection is
/// established by `send`, so a stopped upstream does not prevent allocation.
pub fn start(endpoint: String) -> Result(Client, String) {
  use origin <- result.try(parse_origin(endpoint))
  let initial = State(origin, None)
  case actor.new(initial) |> actor.on_message(handle) |> actor.start() {
    Ok(actor.Started(pid, subject)) -> Ok(Client(subject, pid))
    Error(_) -> Error("could not start egress actor")
  }
}

/// One request is written at most once. On any uncertain write/read error the
/// socket is discarded; a subsequent call may open a new connection.
pub fn send(client: Client, capture: Capture) -> Result(WireResponse, String) {
  let Client(subject, pid) = client
  ask(subject, pid, fn(reply) { Send(capture, reply) })
}

pub fn close(client: Client) -> Result(Nil, String) {
  let Client(subject, pid) = client
  ask(subject, pid, Close)
}

pub fn cli(_args: List(String)) -> Result(String, String) {
  Error("egress is a library client; use start/send/close")
}

fn ask(
  subject: process.Subject(Message),
  pid: process.Pid,
  make_message: fn(process.Subject(Result(value, String))) -> Message,
) -> Result(value, String) {
  let reply = process.new_subject()
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Answer)
    |> process.select_specific_monitor(monitor, fn(_) { ActorDown })
  process.send(subject, make_message(reply))
  let response = process.selector_receive(selector, call_timeout_ms)
  process.demonitor_process(monitor)
  case response {
    Ok(Answer(value)) -> value
    Ok(ActorDown) -> Error("egress client stopped")
    Error(_) -> {
      // An unanswered queued call must not later transmit a request.
      process.kill(pid)
      Error("egress call timed out; client closed")
    }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Send(capture, reply) -> {
      let #(next, outcome) = perform(state, capture)
      process.send(reply, outcome)
      actor.continue(next)
    }
    Close(reply) -> {
      discard(state.socket)
      process.send(reply, Ok(Nil))
      actor.stop()
    }
  }
}

fn perform(
  state: State,
  capture: Capture,
) -> #(State, Result(WireResponse, String)) {
  let attempt = do_send(state, capture)
  case attempt {
    Ok(#(socket, response, reusable)) -> {
      case reusable {
        True -> #(State(..state, socket: Some(socket)), Ok(response))
        False -> {
          close_socket(socket)
          #(State(..state, socket: None), Ok(response))
        }
      }
    }
    Error(reason) -> {
      discard(state.socket)
      #(State(..state, socket: None), Error(reason))
    }
  }
}

fn do_send(
  state: State,
  capture: Capture,
) -> Result(#(Socket, WireResponse, Bool), String) {
  use capture_origin <- result.try(parse_origin(capture.endpoint))
  use _ <- result.try(case capture_origin == state.origin {
    True -> Ok(Nil)
    False -> Error("capture endpoint differs from egress origin")
  })
  use _ <- result.try(case capture.http_version {
    "HTTP/1.1" -> Ok(Nil)
    _ -> Error("only HTTP/1.1 requests are supported")
  })
  use raw <- result.try(wire.render_request(capture))
  use _ <- result.try(
    case
      values(capture.headers, "upgrade") == []
      && values(capture.headers, "expect") == []
      && values(capture.headers, "te") == []
    {
      True -> Ok(Nil)
      False -> Error("upgrade, expect, or request trailers unsupported")
    },
  )
  use socket <- result.try(case state.socket {
    Some(existing) -> {
      use alive <- result.try(probe(existing))
      case alive {
        True -> Ok(existing)
        False -> {
          close_socket(existing)
          open(state.origin)
        }
      }
    }
    None -> open(state.origin)
  })
  // This socket belongs to the actor even if it was just connected. Close it
  // here on any failed operation, not just previously stored sockets.
  let started = now_ms()
  let deadline = started + timeout_ms
  let attempt = {
    use _ <- result.try(write(socket, raw, remaining(deadline)))
    read_response(socket, capture.method, started, deadline, 0)
  }
  case attempt {
    Ok(#(response, reusable)) ->
      Ok(#(socket, response, reusable && !has_close(capture.headers)))
    Error(reason) -> {
      close_socket(socket)
      Error(reason)
    }
  }
}

fn open(origin: Origin) -> Result(Socket, String) {
  connect(origin.host, origin.port, origin.scheme == "https", timeout_ms)
}

fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - now_ms())
}

fn discard(socket: Option(Socket)) {
  case socket {
    Some(socket) -> close_socket(socket)
    None -> Nil
  }
}

fn parse_origin(endpoint: String) -> Result(Origin, String) {
  use parsed <- result.try(
    uri.parse(endpoint) |> result.replace_error("invalid egress endpoint"),
  )
  case parsed {
    uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      port: port,
      path: path,
      query: None,
      fragment: None,
      userinfo: None,
    )
      if path == "" || path == "/"
    -> {
      case scheme, host, port {
        "http", _, None if host != "" -> Ok(Origin(scheme, host, 80))
        "https", _, None if host != "" -> Ok(Origin(scheme, host, 443))
        "http", _, Some(p) if host != "" && p > 0 && p < 65_536 ->
          Ok(Origin(scheme, host, p))
        "https", _, Some(p) if host != "" && p > 0 && p < 65_536 ->
          Ok(Origin(scheme, host, p))
        _, _, _ ->
          Error("only direct http/https origins with valid ports are supported")
      }
    }
    _ ->
      Error(
        "egress endpoint must be a direct origin without path or credentials",
      )
  }
}

fn read_response(
  socket: Socket,
  method: String,
  started: Int,
  deadline: Int,
  interim: Int,
) -> Result(#(WireResponse, Bool), String) {
  use status_line <- result.try(line(socket, remaining(deadline)))
  let ttft_ms = now_ms() - started
  use status <- result.try(parse_status(status_line))
  use headers <- result.try(
    read_headers(socket, deadline, string.byte_size(status_line), []),
  )
  let no_interim_framing =
    values(headers, "content-length") == []
    && values(headers, "transfer-encoding") == []
  case status < 200 {
    True if interim < 4 && no_interim_framing ->
      read_response(socket, method, started, deadline, interim + 1)
    True -> Error("unsupported informational response framing")
    False -> read_body(socket, method, status, headers, ttft_ms, deadline)
  }
}

fn read_body(
  socket: Socket,
  method: String,
  status: Int,
  headers: List(Header),
  ttft_ms: Int,
  deadline: Int,
) -> Result(#(WireResponse, Bool), String) {
  use framing <- result.try(response_framing(status, method, headers))
  use _ <- result.try(supported_media(headers, framing))
  use body <- result.try(case framing {
    NoBody -> Ok(<<>>)
    Fixed(length) -> bytes(socket, length, remaining(deadline))
    Chunked -> read_chunks(socket, deadline, 0, [])
  })
  use text <- result.try(
    bit_array.to_string(body)
    |> result.replace_error("response body is not UTF-8; binary unsupported"),
  )
  let response = WireResponse(status, headers, text, ttft_ms)
  Ok(#(response, !has_close(headers)))
}

type Framing {
  NoBody
  Fixed(Int)
  Chunked
}

fn parse_status(value: String) -> Result(Int, String) {
  case string.split_once(value, "\r\n") {
    Ok(#(line, "")) ->
      case string.split(line, " ") {
        ["HTTP/1.1", code, ..] -> {
          case string.byte_size(code) == 3 {
            True -> {
              use status <- result.try(
                int.parse(code) |> result.replace_error("invalid HTTP status"),
              )
              case status >= 100 && status <= 599 && status != 101 {
                True -> Ok(status)
                False ->
                  Error("protocol upgrade or invalid HTTP status unsupported")
              }
            }
            False -> Error("invalid HTTP status code")
          }
        }
        _ -> Error("invalid HTTP/1.1 status line")
      }
    _ -> Error("only CRLF-terminated HTTP/1.1 responses are supported")
  }
}

fn read_headers(
  socket: Socket,
  deadline: Int,
  size: Int,
  reversed: List(Header),
) -> Result(List(Header), String) {
  use raw <- result.try(line(socket, remaining(deadline)))
  let size = size + string.byte_size(raw)
  case size > max_header_bytes || string.byte_size(raw) > max_line_bytes {
    True -> Error("response headers exceed limit")
    False ->
      case raw {
        "\r\n" -> Ok(list.reverse(reversed))
        _ -> {
          use header <- result.try(parse_header(raw))
          read_headers(socket, deadline, size, [header, ..reversed])
        }
      }
  }
}

fn parse_header(raw: String) -> Result(Header, String) {
  case string.split_once(raw, "\r\n") {
    Ok(#(line, "")) ->
      case string.split_once(line, ":") {
        Ok(#(name, value)) if name != "" -> {
          let value = string.trim(value)
          case safe_header(name) && safe_value(value) {
            True -> Ok(Header(name, value))
            False -> Error("invalid response header")
          }
        }
        _ -> Error("invalid response header framing")
      }
    _ -> Error("invalid response header framing")
  }
}

fn safe_header(name: String) -> Bool {
  // Header names are ASCII tokens, not arbitrary Unicode/control bytes.
  string.to_graphemes(name)
  |> list.all(fn(c) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~",
      c,
    )
  })
}

fn safe_value(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn response_framing(
  status: Int,
  method: String,
  headers: List(Header),
) -> Result(Framing, String) {
  let lengths = values(headers, "content-length")
  let encodings = values(headers, "transfer-encoding")
  let content_encodings = values(headers, "content-encoding")
  case
    list.length(lengths) > 1
    || list.length(encodings) > 1
    || lengths != []
    && encodings != []
    || status == 204
    && lengths != []
  {
    True -> Error("ambiguous response framing")
    False -> {
      let no_body = method == "HEAD" || status == 204 || status == 304
      case no_body {
        True -> {
          use _ <- result.try(case lengths {
            [] -> Ok(Nil)
            [raw] -> {
              use length <- result.try(
                int.parse(raw) |> result.replace_error("invalid Content-Length"),
              )
              case length >= 0 && int.to_string(length) == raw {
                True -> Ok(Nil)
                False -> Error("invalid Content-Length")
              }
            }
            _ -> Error("ambiguous Content-Length")
          })
          case encodings {
            [] -> Ok(NoBody)
            [raw] if raw == "chunked" -> Ok(NoBody)
            _ -> Error("unsupported transfer encoding")
          }
        }
        False ->
          case content_encodings, lengths, encodings {
            [], [], [encoding] ->
              case string.lowercase(string.trim(encoding)) {
                "chunked" -> Ok(Chunked)
                _ -> Error("unsupported transfer encoding")
              }
            [], [raw_length], [] -> {
              use length <- result.try(
                int.parse(raw_length)
                |> result.replace_error("invalid Content-Length"),
              )
              case
                length >= 0
                && length <= max_body_bytes
                && int.to_string(length) == raw_length
              {
                True -> Ok(Fixed(length))
                False -> Error("invalid or oversized Content-Length")
              }
            }
            [], [], [] -> Error("unframed response body unsupported")
            _, _, _ if content_encodings != [] ->
              Error("encoded response body unsupported")
            _, _, _ -> Error("ambiguous or unsupported response framing")
          }
      }
    }
  }
}

fn supported_media(
  headers: List(Header),
  framing: Framing,
) -> Result(Nil, String) {
  case framing, values(headers, "content-type") {
    NoBody, _ -> Ok(Nil)
    _, [] -> Ok(Nil)
    _, [raw] -> {
      let parts =
        raw
        |> string.lowercase
        |> string.split(on: ";")
        |> list.map(string.trim)
      let media = list.first(parts) |> result.unwrap("")
      let parameters = list.drop(parts, 1)
      case
        {
          media == "application/json"
          || media == "text/event-stream"
          || string.starts_with(media, "application/")
          && string.ends_with(media, "+json")
        }
        && list.all(parameters, fn(p) { p == "charset=utf-8" })
      {
        True -> Ok(Nil)
        False -> Error("only UTF-8 JSON or SSE response media supported")
      }
    }
    _, _ -> Error("ambiguous response Content-Type")
  }
}

fn values(headers: List(Header), key: String) -> List(String) {
  headers
  |> list.filter_map(fn(header) {
    let Header(name, value) = header
    case string.lowercase(name) == key {
      True -> Ok(value)
      False -> Error(Nil)
    }
  })
}

fn has_close(headers: List(Header)) -> Bool {
  values(headers, "connection")
  |> list.any(fn(value) {
    string.split(string.lowercase(value), ",")
    |> list.any(fn(token) { string.trim(token) == "close" })
  })
}

fn read_chunks(
  socket: Socket,
  deadline: Int,
  total: Int,
  reversed: List(BitArray),
) -> Result(BitArray, String) {
  use size_line <- result.try(line(socket, remaining(deadline)))
  use size <- result.try(parse_chunk_size(size_line))
  case size {
    0 -> {
      use trailer <- result.try(line(socket, remaining(deadline)))
      case trailer {
        "\r\n" -> Ok(bit_array.concat(list.reverse(reversed)))
        _ -> Error("chunked trailers unsupported")
      }
    }
    _ if size > max_body_bytes - total -> Error("response body exceeds limit")
    _ -> {
      use chunk <- result.try(bytes(socket, size, remaining(deadline)))
      use separator <- result.try(bytes(socket, 2, remaining(deadline)))
      case separator == <<13, 10>> {
        True -> read_chunks(socket, deadline, total + size, [chunk, ..reversed])
        False -> Error("invalid chunk separator")
      }
    }
  }
}

fn parse_chunk_size(raw: String) -> Result(Int, String) {
  case string.split_once(raw, "\r\n") {
    Ok(#(value, "")) -> {
      let #(hex, extension) = case string.split_once(value, ";") {
        Ok(#(hex, extension)) -> #(hex, extension)
        Error(_) -> #(value, "")
      }
      case
        hex == ""
        || string.byte_size(hex) > 8
        || !list.all(string.to_graphemes(hex), fn(c) {
          string.contains("0123456789abcdefABCDEF", c)
        })
        || !safe_value(extension)
      {
        True -> Error("invalid chunk length or extension")
        False ->
          int.base_parse(hex, 16)
          |> result.replace_error("invalid chunk length")
      }
    }
    _ -> Error("invalid chunk framing")
  }
}
