import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/protocol/responses/frames
import mimic/types.{type Header, Header}

/// A connection is owned by the process that opened it. Treat the value as
/// linear: after poll, use only the returned connection; errors are terminal.
pub opaque type Connection {
  Connection(
    socket: Socket,
    decoder: frames.Decoder,
    pending: BitArray,
    timeout_ms: Int,
    poll_ms: Int,
    max_message_bytes: Int,
    max_frame_bytes: Int,
  )
}

pub type Config {
  Config(
    ca_file: Option(String),
    timeout_ms: Int,
    poll_ms: Int,
    max_frame_bytes: Int,
    max_message_bytes: Int,
  )
}

type Origin {
  Origin(host: String, port: Int, tls: Bool, authority: String)
}

type Socket

@external(erlang, "mimic_egress_ffi", "connect_with_ca")
fn connect(
  host: String,
  port: Int,
  tls: Bool,
  timeout: Int,
  ca_file: Option(String),
) -> Result(Socket, String)

@external(erlang, "mimic_egress_ffi", "write")
fn write(socket: Socket, bytes: BitArray, timeout: Int) -> Result(Nil, String)

@external(erlang, "mimic_egress_ffi", "line")
fn line(socket: Socket, timeout: Int) -> Result(String, String)

@external(erlang, "mimic_egress_ffi", "close")
fn close_socket(socket: Socket) -> Nil

@external(erlang, "mimic_egress_ffi", "now_ms")
fn now_ms() -> Int

/// Reads at most 8192 bytes in raw mode. A timeout is idle, never EOF.
@external(erlang, "mimic_provider_ws_ffi", "recv")
fn recv(socket: Socket, timeout: Int) -> Result(Option(BitArray), String)

@external(erlang, "mimic_provider_ws_ffi", "random")
fn random(length: Int) -> BitArray

/// Only exact, direct http(s) account origins are accepted. Plain HTTP is
/// restricted to numeric loopback. TLS uses peer and hostname verification;
/// a private CA replaces the system trust roots for this connection.
pub fn open(
  approved_origin: String,
  endpoint: String,
  target: String,
  headers: List(Header),
  config: Config,
) -> Result(Connection, String) {
  use _ <- result.try(ensure(
    approved_origin == endpoint,
    "WS endpoint differs from approved origin",
  ))
  use origin <- result.try(parse_origin(endpoint))
  use _ <- result.try(ensure(
    config.timeout_ms > 0
      && config.timeout_ms <= 60_000
      && config.poll_ms > 0
      && config.poll_ms <= 60_000,
    "WS timeouts must be between 1 and 60000 ms",
  ))
  use decoder <- result.try(frames.new(
    frames.Client,
    config.max_frame_bytes,
    config.max_message_bytes,
  ))
  use _ <- result.try(ensure(valid_target(target), "invalid WS request target"))
  use _ <- result.try(ensure(
    list.all(headers, valid_request_header),
    "invalid or reserved WS request header",
  ))
  let nonce = random(16) |> bit_array.base64_encode(True)
  let request =
    "GET "
    <> target
    <> " HTTP/1.1\r\nHost: "
    <> origin.authority
    <> "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: "
    <> nonce
    <> "\r\n"
    <> string.join(
      list.map(headers, fn(h) { h.name <> ": " <> h.value <> "\r\n" }),
      "",
    )
    <> "\r\n"
  use _ <- result.try(ensure(
    string.byte_size(request) <= 16_384,
    "WS request headers exceed limit",
  ))
  use socket <- result.try(connect(
    origin.host,
    origin.port,
    origin.tls,
    config.timeout_ms,
    config.ca_file,
  ))
  let deadline = now_ms() + config.timeout_ms
  let opened = {
    use _ <- result.try(write(
      socket,
      bit_array.from_string(request),
      remaining(deadline),
    ))
    use status_line <- result.try(line(socket, remaining(deadline)))
    use status <- result.try(parse_status(status_line))
    use response_headers <- result.try(
      read_headers(socket, deadline, string.byte_size(status_line), []),
    )
    use _ <- result.try(ensure(
      list.all(response_headers, fn(h) {
        let name = string.lowercase(h.name)
        name != "content-length"
        && name != "transfer-encoding"
        && name != "content-encoding"
      }),
      "WS upgrade has unsupported HTTP framing",
    ))
    use _ <- result.try(frames.client_upgrade(status, response_headers, nonce))
    Ok(Connection(
      socket,
      decoder,
      <<>>,
      config.timeout_ms,
      config.poll_ms,
      config.max_message_bytes,
      config.max_frame_bytes,
    ))
  }
  case opened {
    Ok(connection) -> Ok(connection)
    Error(reason) -> {
      close_socket(socket)
      Error(reason)
    }
  }
}

/// Sends one complete masked text frame. Any I/O error invalidates the socket.
pub fn send(connection: Connection, text: String) -> Result(Nil, String) {
  let size = string.byte_size(text)
  let attempted = {
    use _ <- result.try(ensure(
      size <= connection.max_frame_bytes && size <= connection.max_message_bytes,
      "WS outgoing message exceeds byte limit",
    ))
    use encoded <- result.try(frames.encode_text(
      frames.Client,
      text,
      Some(random(4)),
    ))
    write(connection.socket, encoded, connection.timeout_ms)
  }
  case attempted {
    Ok(_) -> Ok(Nil)
    Error(reason) -> {
      close_socket(connection.socket)
      Error(reason)
    }
  }
}

/// At most one bounded raw read per poll. Input is fed to the shared decoder
/// one event at a time so an earlier complete text is delivered before a later
/// malformed frame in the same network read. The unread tail is retained in
/// the returned connection. EOF, close and malformed framing are terminal.
pub fn poll(
  connection: Connection,
) -> Result(#(Connection, Option(String)), String) {
  let attempted = case connection.pending {
    <<>> -> {
      use chunk <- result.try(recv(connection.socket, connection.poll_ms))
      case chunk {
        None -> Ok(#(connection, None))
        Some(bytes) -> scan_pending(Connection(..connection, pending: bytes))
      }
    }
    _ -> scan_pending(connection)
  }
  case attempted {
    Ok(value) -> Ok(value)
    Error(reason) -> {
      close_socket(connection.socket)
      Error(reason)
    }
  }
}

fn scan_pending(
  connection: Connection,
) -> Result(#(Connection, Option(String)), String) {
  use decoded <- result.try(frames.feed_one(
    connection.decoder,
    connection.pending,
  ))
  let next = Connection(..connection, decoder: decoded.0, pending: decoded.2)
  case decoded.1 {
    None -> Ok(#(next, None))
    Some(event) -> {
      use text <- result.try(handle_event(next, event))
      case text {
        Some(_) -> Ok(#(next, text))
        None ->
          case next.pending {
            <<>> -> Ok(#(next, None))
            _ -> scan_pending(next)
          }
      }
    }
  }
}

fn handle_event(
  connection: Connection,
  event: frames.Event,
) -> Result(Option(String), String) {
  case event {
    frames.Text(text) -> Ok(Some(text))
    frames.Ping(payload) -> {
      use pong <- result.try(frames.encode_pong(
        frames.Client,
        payload,
        Some(random(4)),
      ))
      use _ <- result.try(write(connection.socket, pong, connection.timeout_ms))
      Ok(None)
    }
    frames.Pong(_) -> Ok(None)
    frames.Close(code, reason) -> {
      let reply =
        frames.encode_close(
          frames.Client,
          code,
          case reason {
            None -> ""
            Some(text) -> text
          },
          Some(random(4)),
        )
      case reply {
        Ok(bytes) -> {
          let _ = write(connection.socket, bytes, connection.timeout_ms)
          Error("WS peer closed connection")
        }
        Error(_) -> Error("WS peer closed connection")
      }
    }
  }
}

pub fn close(connection: Connection) -> Nil {
  let frame =
    frames.encode_close(frames.Client, Some(1000), "", Some(random(4)))
  case frame {
    Ok(bytes) -> {
      let _ = write(connection.socket, bytes, connection.timeout_ms)
      Nil
    }
    Error(_) -> Nil
  }
  close_socket(connection.socket)
}

fn parse_origin(endpoint: String) -> Result(Origin, String) {
  use parsed <- result.try(
    uri.parse(endpoint) |> result.replace_error("invalid WS origin"),
  )
  case parsed {
    uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      port: port,
      path: "",
      query: None,
      fragment: None,
      userinfo: None,
    )
      if host != ""
    -> {
      use _ <- result.try(ensure(
        !string.contains(host, ":"),
        "IPv6 WS origins are unsupported by the socket primitive",
      ))
      use tls <- result.try(case scheme {
        "http" -> Ok(False)
        "https" -> Ok(True)
        _ -> Error("WS origin must use http or https")
      })
      use _ <- result.try(ensure(
        tls || numeric_loopback(host),
        "plain WS requires numeric loopback origin",
      ))
      use port_number <- result.try(case port {
        None ->
          Ok(case tls {
            True -> 443
            False -> 80
          })
        Some(number) if number > 0 && number < 65_536 -> Ok(number)
        _ -> Error("invalid WS origin port")
      })
      let authority = case port {
        None -> host
        Some(_) -> host <> ":" <> int.to_string(port_number)
      }
      Ok(Origin(host, port_number, tls, authority))
    }
    _ -> Error("WS origin must have no path, query or credentials")
  }
}

fn numeric_loopback(host: String) -> Bool {
  case string.split(host, ".") {
    ["127", a, b, c] ->
      list.all([a, b, c], fn(part) {
        case int.parse(part) {
          Ok(number) ->
            number >= 0 && number <= 255 && int.to_string(number) == part
          Error(_) -> False
        }
      })
    _ -> False
  }
}

fn valid_target(target: String) -> Bool {
  string.starts_with(target, "/")
  && !string.starts_with(target, "//")
  && target_bytes(bit_array.from_string(target))
}

fn target_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>>
      if byte >= 33 && byte <= 126 && byte != 35 && byte != 92
    -> target_bytes(rest)
    _ -> False
  }
}

fn valid_request_header(header: Header) -> Bool {
  let name = string.lowercase(header.name)
  header_name(header.name)
  && !list.contains(
    [
      "host", "upgrade", "connection", "content-length", "transfer-encoding",
      "content-encoding", "expect", "te", "trailer", "proxy-connection",
    ],
    name,
  )
  && !string.starts_with(name, "sec-websocket")
  && !string.starts_with(name, "proxy-")
  && field_bytes(bit_array.from_string(header.value))
}

fn header_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(c) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~",
      c,
    )
  })
}

fn field_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> if byte == 9 || { byte >= 32 && byte <= 126 } ->
      field_bytes(rest)
    _ -> False
  }
}

fn parse_status(raw: String) -> Result(Int, String) {
  case string.split_once(raw, "\r\n") {
    Ok(#(line, "")) ->
      case string.split(line, " ") {
        ["HTTP/1.1", "101", ..] -> Ok(101)
        _ -> Error("WS upgrade requires HTTP/1.1 101")
      }
    _ -> Error("invalid WS upgrade status line")
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
  use _ <- result.try(ensure(
    size <= 16_384 && string.byte_size(raw) <= 8192,
    "WS response headers exceed limit",
  ))
  case raw {
    "\r\n" -> Ok(list.reverse(reversed))
    _ -> {
      use header <- result.try(parse_header(raw))
      read_headers(socket, deadline, size, [header, ..reversed])
    }
  }
}

fn parse_header(raw: String) -> Result(Header, String) {
  case string.split_once(raw, "\r\n") {
    Ok(#(value, "")) ->
      case string.split_once(value, ":") {
        Ok(#(name, field)) -> {
          let header = Header(name, string.trim(field))
          case header_name(name) && field_bytes(bit_array.from_string(field)) {
            True -> Ok(header)
            False -> Error("invalid WS response header")
          }
        }
        _ -> Error("invalid WS response header")
      }
    _ -> Error("invalid WS response header")
  }
}

fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - now_ms())
}

fn ensure(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}
