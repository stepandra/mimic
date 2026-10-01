/// Explicit direct synthetic HTTP/1.1 adapter. Fixed authority, no proxy/env,
/// redirects, DNS, retries, upgrade, compression, binary or close-delimited body.
/// HTTP interpretation is Gleam; the reused FFI only owns sockets.
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir/json_guard
import mimic/live/admission
import mimic/live/policy
import mimic/live/runner
import mimic/protocol/sse

type Socket

@external(erlang, "mimic_egress_ffi", "connect")
fn connect_socket(
  host: String,
  port: Int,
  tls: Bool,
  timeout: Int,
) -> Result(Socket, String)

@external(erlang, "mimic_egress_ffi", "write")
fn write(socket: Socket, data: String, timeout: Int) -> Result(Nil, String)

@external(erlang, "mimic_egress_ffi", "line")
fn line(socket: Socket, timeout: Int) -> Result(String, String)

@external(erlang, "mimic_egress_ffi", "bytes")
fn read_bytes(
  socket: Socket,
  count: Int,
  timeout: Int,
) -> Result(BitArray, String)

@external(erlang, "mimic_egress_ffi", "close")
fn close_socket(socket: Socket) -> Nil

type Stage {
  NeedHead
  Fixed(remaining: Int)
  Chunked(pending: Int)
  ChunkSeparator
}

pub opaque type Connection {
  Connection(
    socket: Socket,
    stage: Stage,
    response: BitArray,
    streaming: Bool,
    decoder: sse.Decoder,
    pending: BitArray,
  )
}

pub fn transport() -> runner.Transport(Connection) {
  runner.Transport(connect, send, next, fn(connection) {
    close_socket(connection.socket)
  })
}

fn remaining(deadline: Int) -> Result(Int, String) {
  case deadline - runner.now_ms() {
    left if left > 0 -> Ok(left)
    _ -> Error("live_http_deadline")
  }
}

fn connect(plan: policy.Plan, deadline: Int) -> Result(Connection, String) {
  // Defend again in the concrete adapter. It cannot become a remote client
  // just because a future admission constructor was added elsewhere.
  use allowed <- result.try(admission.synthetic(policy.request(plan).endpoint))
  use timeout <- result.try(remaining(deadline))
  use socket <- result.try(connect_socket(
    "127.0.0.1",
    admission.port(allowed),
    False,
    timeout,
  ))
  Ok(
    Connection(
      socket,
      NeedHead,
      <<>>,
      policy.streaming(plan),
      sse.new(policy.limits(plan).response_bytes),
      <<>>,
    ),
  )
}

fn send(
  connection: Connection,
  plan: policy.Plan,
  deadline: Int,
) -> Result(Connection, String) {
  let request = policy.request(plan)
  use allowed <- result.try(admission.synthetic(request.endpoint))
  let raw =
    request.method
    <> " "
    <> request.path
    <> " HTTP/1.1\r\n"
    <> "Host: 127.0.0.1:"
    <> int.to_string(admission.port(allowed))
    <> "\r\n"
    <> "Content-Type: application/json\r\n"
    <> "Accept: "
    <> case policy.streaming(plan) {
      True -> "text/event-stream"
      False -> "application/json"
    }
    <> "\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
    <> "Content-Length: "
    <> int.to_string(string.byte_size(request.body))
    <> "\r\n\r\n"
    <> request.body
  use timeout <- result.try(remaining(deadline))
  use _ <- result.try(write(connection.socket, raw, timeout))
  Ok(connection)
}

fn next(
  connection: Connection,
  available: Int,
  deadline: Int,
) -> Result(runner.Frame(Connection), String) {
  use _ <- result.try(remaining(deadline))
  case connection.streaming && connection.pending != <<>> {
    True -> next_event(connection, available, deadline)
    False -> next_wire(connection, available, deadline)
  }
}

fn next_event(
  connection: Connection,
  available: Int,
  deadline: Int,
) -> Result(runner.Frame(Connection), String) {
  use decoded <- result.try(sse.feed_one(connection.decoder, connection.pending))
  let #(decoder, frame, tail) = decoded
  let connection = Connection(..connection, decoder: decoder, pending: tail)
  case frame {
    None -> next(connection, available, deadline)
    Some(frame) ->
      case frame.data {
        "" | "[DONE]" -> next(connection, available, deadline)
        data ->
          case snapshot(data) {
            Ok(None) -> next(connection, available, deadline)
            Ok(Some(usage)) -> Ok(runner.ObservedUsage(usage, connection))
            Error("live_usage_contract_unsupported") -> Ok(runner.InvalidUsage)
            Error(error) -> Error(error)
          }
      }
  }
}

fn next_wire(
  connection: Connection,
  available: Int,
  deadline: Int,
) -> Result(runner.Frame(Connection), String) {
  case connection.stage {
    NeedHead -> read_head(connection, available, deadline)
    Fixed(0) -> end(connection)
    Fixed(left) ->
      data(
        connection,
        int.min(left, 4096),
        Fixed(left - int.min(left, 4096)),
        available,
        deadline,
        False,
      )
    Chunked(0) -> {
      use timeout <- result.try(remaining(deadline))
      use raw <- result.try(line(connection.socket, timeout))
      use size <- result.try(chunk_size(raw))
      case size {
        0 -> {
          use timeout <- result.try(remaining(deadline))
          use trailer <- result.try(line(connection.socket, timeout))
          case trailer {
            "\r\n" -> end(connection)
            _ -> Error("live_http_trailers_unsupported")
          }
        }
        _ if size > available -> Error("live_http_response_limit")
        _ ->
          next(
            Connection(..connection, stage: Chunked(size)),
            available,
            deadline,
          )
      }
    }
    Chunked(left) ->
      data(
        connection,
        int.min(left, 4096),
        Chunked(left - int.min(left, 4096)),
        available,
        deadline,
        left <= 4096,
      )
    ChunkSeparator -> {
      use timeout <- result.try(remaining(deadline))
      use separator <- result.try(read_bytes(connection.socket, 2, timeout))
      case separator {
        <<13, 10>> ->
          next(Connection(..connection, stage: Chunked(0)), available, deadline)
        _ -> Error("live_http_chunk_separator_invalid")
      }
    }
  }
}

fn data(
  connection: Connection,
  count: Int,
  stage: Stage,
  available: Int,
  deadline: Int,
  chunk_end: Bool,
) -> Result(runner.Frame(Connection), String) {
  use _ <- result.try(case count > 0 && count <= available {
    True -> Ok(Nil)
    False -> Error("live_http_response_limit")
  })
  use timeout <- result.try(remaining(deadline))
  use bytes <- result.try(read_bytes(connection.socket, count, timeout))
  let stage = case chunk_end {
    True -> ChunkSeparator
    False -> stage
  }
  let #(response, pending) = case connection.streaming {
    True -> #(<<>>, bytes)
    False -> #(bit_array.append(connection.response, bytes), <<>>)
  }
  // Raw network bytes are returned ONCE for runner byte/chunk accounting,
  // before any ordered usage observation. Usage-only events are not exempt.
  Ok(runner.Data(
    bytes,
    Connection(..connection, stage: stage, response: response, pending: pending),
  ))
}

fn read_head(
  connection: Connection,
  available: Int,
  deadline: Int,
) -> Result(runner.Frame(Connection), String) {
  use timeout <- result.try(remaining(deadline))
  use raw <- result.try(line(connection.socket, timeout))
  use status <- result.try(case string.split(raw, " ") {
    ["HTTP/1.1", code, ..] ->
      case string.byte_size(code) == 3 && string.ends_with(raw, "\r\n") {
        True ->
          int.parse(code) |> result.replace_error("live_http_status_invalid")
        False -> Error("live_http_status_invalid")
      }
    _ -> Error("live_http_status_invalid")
  })
  use headers <- result.try(
    headers(connection.socket, deadline, string.byte_size(raw), []),
  )
  use _ <- result.try(
    case
      values(headers, "content-encoding") == []
      && values(headers, "location") == []
      && values(headers, "upgrade") == []
      && values(headers, "trailer") == []
      && values(headers, "connection") != ["upgrade"]
      && values(headers, "content-type")
      == case connection.streaming {
        True -> ["text/event-stream"]
        False -> ["application/json"]
      }
    {
      True -> Ok(Nil)
      False -> Error("live_http_media_or_redirect_unsupported")
    },
  )
  use stage <- result.try(
    case
      values(headers, "content-length"),
      values(headers, "transfer-encoding")
    {
      [length], [] -> {
        use size <- result.try(
          int.parse(length) |> result.replace_error("live_http_length_invalid"),
        )
        case size >= 0 && size <= available && int.to_string(size) == length {
          True -> Ok(Fixed(size))
          False -> Error("live_http_length_or_limit_invalid")
        }
      }
      [], ["chunked"] -> Ok(Chunked(0))
      _, _ -> Error("live_http_framing_unsupported")
    },
  )
  Ok(runner.Head(status, Connection(..connection, stage: stage)))
}

fn headers(
  socket: Socket,
  deadline: Int,
  total: Int,
  accumulated: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  use _ <- result.try(case total <= 8192 && list.length(accumulated) <= 32 {
    True -> Ok(Nil)
    False -> Error("live_http_headers_limit")
  })
  use timeout <- result.try(remaining(deadline))
  use raw <- result.try(line(socket, timeout))
  use _ <- result.try(case total + string.byte_size(raw) <= 8192 {
    True -> Ok(Nil)
    False -> Error("live_http_headers_limit")
  })
  case raw {
    "\r\n" -> Ok(list.reverse(accumulated))
    _ -> {
      use header <- result.try(parse_header(raw))
      headers(socket, deadline, total + string.byte_size(raw), [
        header,
        ..accumulated
      ])
    }
  }
}

// CRLF is one Unicode grapheme. Never strip protocol delimiters by a
// grapheme count: doing so also removes the header/hex line's last character.
fn strip_crlf(raw: String) -> Result(String, String) {
  case string.split_once(raw, "\r\n") {
    Ok(#(value, "")) ->
      case !string.contains(value, "\r") && !string.contains(value, "\n") {
        True -> Ok(value)
        False -> Error("live_http_line_invalid")
      }
    _ -> Error("live_http_line_invalid")
  }
}

/// Pure call-site seam for exact HTTP delimiter regression tests.
pub fn parse_header(raw: String) -> Result(#(String, String), String) {
  use value <- result.try(strip_crlf(raw))
  use parts <- result.try(
    string.split_once(value, ":")
    |> result.replace_error("live_http_header_invalid"),
  )
  let #(name, value) = parts
  case name != "" && ascii_token(bit_array.from_string(name)) {
    True -> Ok(#(string.lowercase(name), string.trim(value)))
    False -> Error("live_http_header_invalid")
  }
}

fn ascii_token(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>>
      if byte >= 48
      && byte <= 57
      || byte >= 65
      && byte <= 90
      || byte >= 97
      && byte <= 122
    -> ascii_token(rest)
    <<33, rest:bytes>>
    | <<35, rest:bytes>>
    | <<36, rest:bytes>>
    | <<37, rest:bytes>>
    | <<38, rest:bytes>>
    | <<39, rest:bytes>>
    | <<42, rest:bytes>>
    | <<43, rest:bytes>>
    | <<45, rest:bytes>>
    | <<46, rest:bytes>>
    | <<94, rest:bytes>>
    | <<95, rest:bytes>>
    | <<96, rest:bytes>>
    | <<124, rest:bytes>>
    | <<126, rest:bytes>> -> ascii_token(rest)
    _ -> False
  }
}

fn values(headers: List(#(String, String)), name: String) -> List(String) {
  list.filter_map(headers, fn(header) {
    case header {
      #(key, value) if key == name -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

pub fn chunk_size(raw: String) -> Result(Int, String) {
  use hex <- result.try(strip_crlf(raw))
  case
    string.byte_size(hex) > 0
    && string.byte_size(hex) <= 8
    && list.all(string.to_graphemes(hex), fn(char) {
      string.contains("0123456789abcdefABCDEF", char)
    })
  {
    True ->
      int.base_parse(hex, 16) |> result.replace_error("live_http_chunk_invalid")
    False -> Error("live_http_chunk_extensions_or_size_unsupported")
  }
}

fn end(connection: Connection) -> Result(runner.Frame(Connection), String) {
  case connection.streaming {
    True -> {
      use _ <- result.try(sse.finish(connection.decoder))
      // The runner retains already observed counts; None never clears them.
      Ok(runner.End(None))
    }
    False -> {
      use body <- result.try(
        bit_array.to_string(connection.response)
        |> result.replace_error("live_http_binary_response_unsupported"),
      )
      case snapshot(body) {
        Ok(usage) -> Ok(runner.End(usage))
        Error("live_usage_contract_unsupported") -> Ok(runner.InvalidUsage)
        Error(error) -> Error(error)
      }
    }
  }
}

// Synthetic cumulative snapshots only, NOT a universal provider usage schema.
// Absent/null usage is unknown; asserted partial/delta/ill-typed usage rejects.
fn snapshot(body: String) -> Result(Option(runner.Usage), String) {
  let decoder = {
    use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
    use input <- decode.field("input_tokens", decode.int)
    use output <- decode.field("output_tokens", decode.int)
    case
      list.length(dict.keys(fields)) == 2
      && list.all(dict.keys(fields), fn(key) {
        list.contains(["input_tokens", "output_tokens"], key)
      })
    {
      True -> decode.success(runner.Usage(input, output))
      False -> decode.failure(runner.Usage(0, 0), "complete cumulative usage")
    }
  }
  use _ <- result.try(
    json_guard.validate(body, 65_536, 16, 8192)
    |> result.replace_error("live_http_response_json_unsupported"),
  )
  use fields <- result.try(
    json.parse(body, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("live_http_response_json_unsupported"),
  )
  case dict.get(fields, "usage") {
    Error(_) -> Ok(None)
    Ok(value) ->
      decode.run(value, decode.optional(decoder))
      |> result.replace_error("live_usage_contract_unsupported")
  }
}
