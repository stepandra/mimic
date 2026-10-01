import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import mimic/providers/contracts.{
  type BinaryMedia, type Failure, type HttpRequest, ConnectProto, Failure, Http1,
  InvalidConfiguration, InvalidResponse, NotSent, Proto, Unavailable, Uncertain,
  Unsupported,
}
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

@external(erlang, "mimic_egress_ffi", "write")
fn write_bytes(
  socket: Socket,
  bytes: BitArray,
  timeout: Int,
) -> Result(Nil, String)

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

/// Single-request pull transport. The execution process owns the socket;
/// process death closes it. No reuse across credentials and no automatic replay.
pub opaque type Stream {
  Stream(socket: Socket, framing: Framing, pending: Int, total: Int)
}

type ResponseMedia {
  JsonSse
  Binary(BinaryMedia)
}

@external(erlang, "mimic_egress_ffi", "connect_with_ca")
fn connect_with_ca(
  host: String,
  port: Int,
  tls: Bool,
  timeout: Int,
  ca_file: Option(String),
) -> Result(Socket, String)

pub fn stream_open(
  endpoint: String,
  capture: Capture,
  ca_file: Option(String),
) -> Result(#(Int, List(Header), Stream), Failure) {
  use origin <- result.try(
    parse_origin(endpoint)
    |> result.replace_error(Failure(InvalidConfiguration, NotSent, None)),
  )
  use _ <- result.try(
    case
      capture.endpoint == endpoint
      && capture.http_version == "HTTP/1.1"
      && string.starts_with(capture.target, "/")
      && !string.starts_with(capture.target, "//")
      && values(capture.headers, "upgrade") == []
      && values(capture.headers, "expect") == []
      && values(capture.headers, "te") == []
      && approved_host(capture.headers, origin)
      && valid_text_body(capture.body)
    {
      True -> Ok(Nil)
      False -> Error(Failure(InvalidConfiguration, NotSent, None))
    },
  )
  use raw <- result.try(
    wire.render_request(capture)
    |> result.replace_error(Failure(InvalidConfiguration, NotSent, None)),
  )
  send_stream(
    origin,
    capture.method,
    bit_array.from_string(raw),
    ca_file,
    JsonSse,
  )
}

/// Explicit binary-only boundary; never construct a Capture or UTF-8 String
/// from the body. Protocol/media requirements are validated before connecting.
pub fn stream_open_binary(
  endpoint: String,
  plan: HttpRequest,
  ca_file: Option(String),
) -> Result(#(Int, List(Header), Stream), Failure) {
  use _ <- result.try(case plan.protocol {
    Http1 -> Ok(Nil)
    _ -> Error(Failure(Unsupported, NotSent, None))
  })
  use origin <- result.try(
    parse_origin(endpoint)
    |> result.replace_error(Failure(InvalidConfiguration, NotSent, None)),
  )
  let length = bit_array.byte_size(plan.body)
  // CPA's default Go transport is not proof of actual Devin H1 compatibility.
  // Until separately qualified, binary H1 is for numeric-loopback fixtures only.
  use _ <- result.try(case origin.host == "127.0.0.1" || origin.host == "::1" {
    True -> Ok(Nil)
    False -> Error(Failure(Unsupported, NotSent, None))
  })
  use _ <- result.try(
    case
      plan.endpoint == endpoint
      && length <= max_body_bytes
      && bit_array.bit_size(plan.body) % 8 == 0
      && plan.method != ""
      && safe_header(plan.method)
      && string.starts_with(plan.target, "/")
      && !string.starts_with(plan.target, "//")
      && visible_ascii(bit_array.from_string(plan.target))
      && list.all(plan.headers, fn(header) {
        header.name != ""
        && safe_header(header.name)
        && safe_value(header.value)
        && string.byte_size(header.name) + string.byte_size(header.value) + 4
        <= max_line_bytes
      })
      && list.all(
        ["upgrade", "expect", "te", "transfer-encoding", "content-encoding"],
        fn(name) { values(plan.headers, name) == [] },
      )
      && approved_host(plan.headers, origin)
      && values(plan.headers, "content-length") == [int.to_string(length)]
      && media_matches(plan.headers, plan.media)
    {
      True -> Ok(Nil)
      False -> Error(Failure(InvalidConfiguration, NotSent, None))
    },
  )
  let first_line = plan.method <> " " <> plan.target <> " HTTP/1.1\r\n"
  let headers =
    first_line
    <> {
      list.map(plan.headers, fn(h) { h.name <> ": " <> h.value })
      |> string.join("\r\n")
    }
    <> "\r\n\r\n"
  use _ <- result.try(
    case
      string.byte_size(headers) <= max_header_bytes
      && string.byte_size(first_line) <= max_line_bytes
    {
      True -> Ok(Nil)
      False -> Error(Failure(InvalidConfiguration, NotSent, None))
    },
  )
  let raw = bit_array.append(bit_array.from_string(headers), plan.body)
  send_stream(origin, plan.method, raw, ca_file, Binary(plan.media))
}

fn visible_ascii(value: BitArray) -> Bool {
  case value {
    <<>> -> True
    <<byte, rest:bytes>> if byte >= 33 && byte <= 126 -> visible_ascii(rest)
    _ -> False
  }
}

fn valid_text_body(body: String) -> Bool {
  result.is_ok(bit_array.to_string(bit_array.from_string(body)))
}

fn media_matches(headers: List(Header), expected: BinaryMedia) -> Bool {
  let expected = case expected {
    ConnectProto -> "application/connect+proto"
    Proto -> "application/proto"
  }
  case values(headers, "content-type") {
    [value] -> string.lowercase(trim_http_ows(value)) == expected
    _ -> False
  }
}

fn send_stream(
  origin: Origin,
  method: String,
  raw: BitArray,
  ca_file: Option(String),
  media: ResponseMedia,
) -> Result(#(Int, List(Header), Stream), Failure) {
  use socket <- result.try(
    connect_with_ca(
      origin.host,
      origin.port,
      origin.scheme == "https",
      timeout_ms,
      ca_file,
    )
    |> result.replace_error(Failure(Unavailable, NotSent, None)),
  )
  let deadline = now_ms() + timeout_ms
  let answer = {
    use _ <- result.try(write_bytes(socket, raw, timeout_ms))
    read_stream_head(socket, method, deadline, 0, media)
  }
  case answer {
    Ok(#(status, headers, framing)) ->
      Ok(#(status, headers, Stream(socket, framing, 0, 0)))
    Error(_) -> {
      close_socket(socket)
      Error(Failure(Unavailable, Uncertain, None))
    }
  }
}

fn approved_host(headers: List(Header), origin: Origin) -> Bool {
  case values(headers, "host") {
    [value] ->
      case parse_origin(origin.scheme <> "://" <> value) {
        Ok(host) ->
          !string.contains(value, "/")
          && string.lowercase(host.host) == string.lowercase(origin.host)
          && host.port == origin.port
          && host.scheme == origin.scheme
        Error(_) -> False
      }
    _ -> False
  }
}

fn read_stream_head(
  socket: Socket,
  method: String,
  deadline: Int,
  interim: Int,
  media: ResponseMedia,
) -> Result(#(Int, List(Header), Framing), String) {
  use raw <- result.try(line(socket, remaining(deadline)))
  use status <- result.try(parse_status(raw))
  use headers <- result.try(
    read_headers(socket, deadline, string.byte_size(raw), []),
  )
  case status < 200 {
    True if interim < 4 && headers == [] ->
      read_stream_head(socket, method, deadline, interim + 1, media)
    True -> Error("Unsupported informational response")
    False -> {
      use framing <- result.try(response_framing(status, method, headers))
      use _ <- result.try(case media, framing {
        JsonSse, _ -> supported_media(headers, framing)
        Binary(expected), _ ->
          case media_matches(headers, expected) {
            True -> Ok(Nil)
            False ->
              case values(headers, "content-type"), framing {
                // No payload exists to interpret. A non-success empty rejection
                // may omit media, but conflicting/duplicate media never passes.
                [], NoBody -> Ok(Nil)
                [], Fixed(0) if status >= 300 -> Ok(Nil)
                _, _ -> Error("Unsupported binary response media")
              }
          }
      })
      Ok(#(status, headers, framing))
    }
  }
}

pub fn stream_next(
  stream: Stream,
) -> Result(Option(#(BitArray, Stream)), Failure) {
  stream_next_before(stream, now_ms() + timeout_ms)
}

/// Pull using one absolute deadline in `mimic_egress_ffi.now_ms()`'s monotonic
/// millisecond domain. Callers must use that same clock plus their total budget,
/// not epoch time, and reuse the deadline for every pull in the operation.
/// An expired deadline fails before any I/O, even with ready buffered bytes or
/// terminal framing. Each nested framing read checks the same deadline.
/// Like stream_next, this never closes: the caller owns exactly one cancel.
pub fn stream_next_before(
  stream: Stream,
  absolute_deadline_ms: Int,
) -> Result(Option(#(BitArray, Stream)), Failure) {
  case stream_read(stream, absolute_deadline_ms) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Failure(InvalidResponse, Uncertain, None))
  }
}

/// Close on every terminal result from stream_next. The runtime does this once
/// in its finally path; stream_next itself never closes behind its caller.
pub fn stream_cancel(stream: Stream) -> Nil {
  close_socket(stream.socket)
}

fn stream_read(
  stream: Stream,
  deadline: Int,
) -> Result(Option(#(BitArray, Stream)), String) {
  use _ <- result.try(stream_timeout(deadline))
  case stream.framing {
    NoBody | Fixed(0) -> Ok(None)
    Fixed(left) -> {
      let size = int.min(left, 16_384)
      use chunk <- result.try(stream_bytes(stream.socket, size, deadline))
      Ok(Some(#(chunk, Stream(..stream, framing: Fixed(left - size)))))
    }
    Chunked -> {
      use size <- result.try(case stream.pending {
        0 -> {
          use raw <- result.try(stream_line(stream.socket, deadline))
          parse_chunk_size(raw)
        }
        n -> Ok(n)
      })
      case size {
        0 -> {
          use trailer <- result.try(stream_line(stream.socket, deadline))
          case trailer {
            "\r\n" -> Ok(None)
            _ -> Error("Chunk trailers unsupported")
          }
        }
        _ if size > max_body_bytes - stream.total ->
          Error("Stream exceeds limit")
        _ -> {
          let count = int.min(size, 16_384)
          use chunk <- result.try(stream_bytes(stream.socket, count, deadline))
          use _ <- result.try(case count == size {
            True -> {
              use separator <- result.try(stream_bytes(
                stream.socket,
                2,
                deadline,
              ))
              case separator {
                <<13, 10>> -> Ok(Nil)
                _ -> Error("Invalid chunk separator")
              }
            }
            False -> Ok(Nil)
          })
          Ok(
            Some(#(
              chunk,
              Stream(
                ..stream,
                pending: size - count,
                total: stream.total + count,
              ),
            )),
          )
        }
      }
    }
  }
}

fn stream_timeout(deadline: Int) -> Result(Int, String) {
  let left = deadline - now_ms()
  case left > 0 {
    True -> Ok(left)
    False -> Error("Stream deadline expired")
  }
}

fn stream_line(socket: Socket, deadline: Int) -> Result(String, String) {
  use timeout <- result.try(stream_timeout(deadline))
  line(socket, timeout)
}

fn stream_bytes(
  socket: Socket,
  count: Int,
  deadline: Int,
) -> Result(BitArray, String) {
  use timeout <- result.try(stream_timeout(deadline))
  bytes(socket, count, timeout)
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
  use _ <- result.try(case valid_text_body(capture.body) {
    True -> Ok(Nil)
    False ->
      Error("request body is not UTF-8; binary requires an explicit plan")
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
          // Validate raw octets before any normalization. Unicode trim would
          // erase VT and non-HTTP whitespace/format bytes into valid tokens.
          case safe_header(name) && safe_value(value) {
            True -> Ok(Header(name, trim_http_ows(value)))
            False -> Error("invalid response header")
          }
        }
        _ -> Error("invalid response header framing")
      }
    _ -> Error("invalid response header framing")
  }
}

fn trim_http_ows(value: String) -> String {
  let bytes = drop_http_ows(bit_array.from_string(value))
  let end = field_end(bytes, 0, 0)
  // Only ASCII SP/HTAB octets are removed, so valid UTF-8 cannot be split.
  let assert Ok(bytes) = bit_array.slice(bytes, 0, end)
  let assert Ok(value) = bit_array.to_string(bytes)
  value
}

fn drop_http_ows(bytes: BitArray) -> BitArray {
  case bytes {
    <<byte, rest:bytes>> if byte == 32 || byte == 9 -> drop_http_ows(rest)
    _ -> bytes
  }
}

fn field_end(bytes: BitArray, offset: Int, end: Int) -> Int {
  case bytes {
    <<>> -> end
    <<byte, rest:bytes>> if byte == 32 || byte == 9 ->
      field_end(rest, offset + 1, end)
    <<_, rest:bytes>> -> field_end(rest, offset + 1, offset + 1)
    _ -> panic as "HTTP field octets must be byte aligned"
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
  field_octets(bit_array.from_string(value))
}

fn field_octets(value: BitArray) -> Bool {
  case value {
    <<>> -> True
    <<byte, rest:bytes>> if byte == 9 || { byte >= 32 && byte != 127 } ->
      field_octets(rest)
    _ -> False
  }
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
              case string.lowercase(trim_http_ows(encoding)) {
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
        |> list.map(trim_http_ows)
      let media = list.first(parts) |> result.unwrap("")
      let parameters = list.drop(parts, 1)
      case
        ascii_media_field(bit_array.from_string(raw))
        && case string.split(media, "/") {
          ["application", "json"] | ["text", "event-stream"] -> True
          ["application", subtype] ->
            string.byte_size(subtype) > 5
            && string.ends_with(subtype, "+json")
            && safe_header(subtype)
          _ -> False
        }
        && case parameters {
          [] | ["charset=utf-8"] -> True
          _ -> False
        }
      {
        True -> Ok(Nil)
        False -> Error("only UTF-8 JSON or SSE response media supported")
      }
    }
    _, _ -> Error("ambiguous response Content-Type")
  }
}

fn ascii_media_field(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> if byte == 9 || { byte >= 32 && byte <= 126 } ->
      ascii_media_field(rest)
    _ -> False
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
    |> list.any(fn(token) { trim_http_ows(token) == "close" })
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
