// MIMIC modifications to Mist 6.0.3: validate raw security/framing headers
// and retain per-request HTTP/1 body boundaries before route dispatch.
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result
import gleam/string
import glisten.{type Socket}
import glisten/transport.{type Transport}
import gramps/websocket
import mist/internal/buffer.{type Buffer, Buffer}
import mist/internal/clock
import mist/internal/encoder
import mist/internal/file
import mist/internal/http/body as chunked

pub type ResponseData {
  Websocket
  Bytes(BytesTree)
  Chunked
  File(descriptor: file.FileDescriptor, offset: Int, length: Int)
  ServerSentEvents
}

pub type Connection {
  Connection(
    body: Body,
    socket: Socket,
    transport: Transport,
    factory_name: process.Name(
      factory.Message(
        fn() -> Result(actor.Started(process.Pid), actor.StartError),
        process.Pid,
      ),
    ),
  )
}

pub type Handler =
  fn(Request(Connection)) -> response.Response(ResponseData)

pub type PacketType {
  Http
  HttphBin
  HttpBin
}

pub type HttpUri {
  AbsPath(BitArray)
}

pub type HttpPacket {
  HttpRequest(Dynamic, HttpUri, #(Int, Int))
  HttpHeader(Int, Atom, BitArray, BitArray)
}

pub type DecodedPacket {
  BinaryData(HttpPacket, BitArray)
  EndOfHeaders(BitArray)
  MoreData(Option(Int))
  Http2Upgrade(BitArray)
}

pub type DecodeError {
  MalformedRequest
  InvalidMethod
  InvalidPath
  UnknownHeader
  UnknownMethod
  // TODO:  better name?
  InvalidBody
  BodyTooLarge
  DiscardPacket
  NoHostHeader
  InvalidHttpVersion
}

pub fn from_header(value: BitArray) -> String {
  let assert Ok(value) = bit_array.to_string(value)

  string.lowercase(value)
}

// These fields must have one unambiguous value before the header Dict erases
// duplicate occurrences. In particular, do not coalesce list-valued headers
// such as Connection or Accept here.
fn singleton_header(field: String) -> Bool {
  case field {
    "authorization"
    | "origin"
    | "x-csrf-token"
    | "cookie"
    | "content-type"
    | "content-length"
    | "transfer-encoding"
    | "host"
    | "upgrade"
    | "sec-websocket-key"
    | "sec-websocket-version"
    | "sec-websocket-protocol"
    | "sec-websocket-extensions" -> True
    _ -> False
  }
}

fn trim_ows(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.drop_while(fn(char) { char == " " || char == "\t" })
  |> list.reverse
  |> list.drop_while(fn(char) { char == " " || char == "\t" })
  |> list.reverse
  |> string.concat
}

// Upgrade byte ownership and rejected-upgrade closure must use the same HTTP
// OWS rule. Unicode whitespace is not HTTP optional whitespace.
fn websocket_upgrade(value: String) -> Bool {
  string.lowercase(trim_ows(value)) == "websocket"
}

// Connection is a case-insensitive token list, including repeated fields on
// responses. Close wins regardless of token/field order.
pub fn connection_has_close(headers: List(#(String, String))) -> Bool {
  list.any(headers, fn(header) {
    string.lowercase(header.0) == "connection"
    && list.any(string.split(header.1, ","), fn(token) {
      string.lowercase(trim_ows(token)) == "close"
    })
  })
}

fn header_value(
  field: String,
  value: BitArray,
  headers: Dict(String, String),
) -> Result(String, DecodeError) {
  use value <- result.try(
    bit_array.to_string(value) |> result.replace_error(MalformedRequest),
  )
  case field {
    "content-length" -> {
      let value = trim_ows(value)
      case
        dict.has_key(headers, "transfer-encoding")
        || value == ""
        || !list.all(string.to_utf_codepoints(value), fn(char) {
          let char = string.utf_codepoint_to_int(char)
          char >= 48 && char <= 57
        })
      {
        True -> Error(MalformedRequest)
        False ->
          int.parse(value)
          |> result.replace_error(MalformedRequest)
          |> result.replace(value)
      }
    }
    "transfer-encoding" -> {
      let value = string.lowercase(trim_ows(value))
      case dict.has_key(headers, "content-length") || value != "chunked" {
        True -> Error(MalformedRequest)
        False -> Ok(value)
      }
    }
    "connection" ->
      case dict.get(headers, field) {
        Ok(previous) -> Ok(previous <> ", " <> value)
        Error(_) -> Ok(value)
      }
    _ -> Ok(value)
  }
}

// Supported HTTP/1 head boundary, independent of fragmentation: request line,
// raw fields (including duplicates), and separators share one byte/deadline
// budget. Body bytes and pipelined requests are not charged to this head.
const max_head_bytes = 65_536

const max_head_fields = 100

const head_timeout_ms = 15_000

type HeadBudget {
  HeadBudget(remaining: Int, fields: Int, deadline: Int)
}

fn new_head_budget() -> HeadBudget {
  HeadBudget(max_head_bytes, 0, monotonic_ms() + head_timeout_ms)
}

fn check_head(budget: HeadBudget) -> Result(Nil, DecodeError) {
  case budget.remaining > 0 && monotonic_ms() < budget.deadline {
    True -> Ok(Nil)
    False -> Error(MalformedRequest)
  }
}

fn consume_head(
  budget: HeadBudget,
  before: BitArray,
  rest: BitArray,
  fields: Int,
) -> Result(HeadBudget, DecodeError) {
  let consumed = bit_array.byte_size(before) - bit_array.byte_size(rest)
  let remaining = budget.remaining - consumed
  let fields = budget.fields + fields
  case
    consumed <= 0
    || remaining < 0
    || fields > max_head_fields
    || monotonic_ms() >= budget.deadline
  {
    True -> Error(MalformedRequest)
    False -> Ok(HeadBudget(..budget, remaining:, fields:))
  }
}

fn head_options(budget: HeadBudget) -> List(#(Atom, Int)) {
  // Bound the decoder's current raw packet too, including an unfinished line.
  [#(atom.create("packet_size"), budget.remaining)]
}

fn read_head_data(
  bs: BitArray,
  socket: Socket,
  transport: Transport,
  needed: Option(Int),
  budget: HeadBudget,
) -> Result(BitArray, DecodeError) {
  // Decode first, then apply this pending-byte check: a coalesced body/tail
  // can legitimately make the whole socket buffer larger than the head limit.
  let timeout = int.max(0, budget.deadline - monotonic_ms())
  use _ <- result.try(
    case
      bit_array.byte_size(bs) >= budget.remaining
      || option.unwrap(needed, 0) > budget.remaining
      || timeout == 0
    {
      True -> Error(MalformedRequest)
      False -> Ok(Nil)
    },
  )
  use data <- result.try(
    transport.receive_timeout(transport, socket, 0, timeout)
    |> result.replace_error(MalformedRequest),
  )
  case data {
    <<>> -> Error(MalformedRequest)
    _ -> Ok(<<bs:bits, data:bits>>)
  }
}

pub fn parse_headers(
  bs: BitArray,
  socket: Socket,
  transport: Transport,
  headers: Dict(String, String),
) -> Result(#(Dict(String, String), BitArray), DecodeError) {
  parse_headers_head(
    bs,
    socket,
    transport,
    headers,
    HeadBudget(..new_head_budget(), fields: dict.size(headers)),
  )
}

fn parse_headers_head(
  bs: BitArray,
  socket: Socket,
  transport: Transport,
  headers: Dict(String, String),
  budget: HeadBudget,
) -> Result(#(Dict(String, String), BitArray), DecodeError) {
  use _ <- result.try(check_head(budget))
  case decode_packet(HttphBin, bs, head_options(budget)) {
    Ok(BinaryData(HttpHeader(_, _field, field, value), rest)) -> {
      use budget <- result.try(consume_head(budget, bs, rest, 1))
      let field = from_header(field)
      use _ <- result.try(
        case singleton_header(field) && dict.has_key(headers, field) {
          True -> Error(MalformedRequest)
          False -> Ok(Nil)
        },
      )
      use value <- result.try(header_value(field, value, headers))
      headers
      |> dict.insert(field, value)
      |> parse_headers_head(rest, socket, transport, _, budget)
    }
    Ok(EndOfHeaders(rest)) -> {
      use _ <- result.try(consume_head(budget, bs, rest, 0))
      Ok(#(headers, rest))
    }
    Ok(MoreData(size)) -> {
      use next <- result.try(read_head_data(bs, socket, transport, size, budget))
      parse_headers_head(next, socket, transport, headers, budget)
    }
    _other -> Error(UnknownHeader)
  }
}

pub fn read_data(
  socket: Socket,
  transport: Transport,
  buffer: Buffer,
  error: DecodeError,
) -> Result(BitArray, DecodeError) {
  use _ <- result.try(case buffer.remaining < 0 {
    True -> Error(error)
    False -> Ok(Nil)
  })
  // TODO:  don't hard-code these, probably
  let to_read = int.min(buffer.remaining, 1_000_000)
  let timeout = 15_000
  use data <- result.try(
    socket
    |> transport.receive_timeout(transport, _, to_read, timeout)
    |> result.replace_error(error),
  )
  let next_buffer =
    Buffer(remaining: int.max(0, buffer.remaining - to_read), data: <<
      buffer.data:bits,
      data:bits,
    >>)

  case next_buffer.remaining > 0 {
    True -> read_data(socket, transport, next_buffer, error)
    False -> Ok(next_buffer.data)
  }
}

pub type HttpVersion {
  Http1
  Http11
}

pub fn version_to_string(version: HttpVersion) {
  case version {
    Http1 -> "1.0"
    Http11 -> "1.1"
  }
}

pub type ParsedRequest {
  Http1Request(
    request: request.Request(Connection),
    version: HttpVersion,
    buffered_tail: BitArray,
  )
  Upgrade(BitArray)
}

@external(erlang, "mist_ffi", "decode_atom")
fn decode_atom(value: Dynamic) -> Result(atom.Atom, Nil)

fn decode_http_method(value: Dynamic) -> Result(http.Method, Nil) {
  let options = atom.create("OPTIONS")
  let get = atom.create("GET")
  let head = atom.create("HEAD")
  let post = atom.create("POST")
  let put = atom.create("PUT")
  let delete = atom.create("DELETE")
  let trace = atom.create("TRACE")

  case decode_atom(value) {
    Ok(method) if method == options -> Ok(http.Options)
    Ok(method) if method == get -> Ok(http.Get)
    Ok(method) if method == head -> Ok(http.Head)
    Ok(method) if method == post -> Ok(http.Post)
    Ok(method) if method == put -> Ok(http.Put)
    Ok(method) if method == delete -> Ok(http.Delete)
    Ok(method) if method == trace -> Ok(http.Trace)
    _ -> {
      case decode.run(value, decode.string) {
        Ok(str) -> http.parse_method(str)
        _ -> Error(Nil)
      }
    }
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(
  bs: BitArray,
  conn: Connection,
) -> Result(ParsedRequest, DecodeError) {
  parse_request_head(bs, conn, new_head_budget())
}

fn parse_request_head(
  bs: BitArray,
  conn: Connection,
  budget: HeadBudget,
) -> Result(ParsedRequest, DecodeError) {
  use _ <- result.try(check_head(budget))
  case decode_packet(HttpBin, bs, head_options(budget)) {
    Ok(BinaryData(HttpRequest(http_method, AbsPath(path), version), rest)) -> {
      use budget <- result.try(consume_head(budget, bs, rest, 0))
      use method <- result.try(
        http_method
        |> decode_http_method
        |> result.replace_error(UnknownMethod),
      )
      use #(headers, rest) <- result.try(parse_headers_head(
        rest,
        conn.socket,
        conn.transport,
        dict.new(),
        budget,
      ))
      // Gleam's Request does not carry the HTTP version. Reject upgrades
      // before constructing it, while ordinary HTTP/1.0 remains supported.
      use _ <- result.try(
        case
          version,
          dict.has_key(headers, "upgrade")
          || dict.has_key(headers, "transfer-encoding")
        {
          #(1, 0), True -> Error(MalformedRequest)
          _, _ -> Ok(Nil)
        },
      )
      use path <- result.try(
        path
        |> bit_array.to_string
        |> result.replace_error(InvalidPath),
      )
      use #(path, query) <- result.try(
        get_path_and_query(path)
        |> result.replace_error(InvalidPath),
      )
      let scheme = case conn.transport {
        transport.Ssl(..) -> http.Https
        transport.Tcp(..) -> http.Http
      }
      use host_header <- result.try(
        dict.get(headers, "host")
        |> result.replace_error(NoHostHeader),
      )
      let #(hostname, port) =
        host_header
        |> string.split_once(":")
        |> result.unwrap(#(host_header, ""))

      let port = case int.parse(port) {
        Ok(port) -> port
        Error(_) ->
          case scheme {
            http.Https -> 443
            http.Http -> 80
          }
      }

      let #(body, buffered_tail) = frame_body(headers, rest)
      let req =
        request.Request(
          body: Connection(..conn, body:),
          headers: dict.to_list(headers),
          host: hostname,
          method: method,
          path: path,
          port: option.Some(port),
          query: option.from_result(query),
          scheme: scheme,
        )
      case version {
        #(1, 0) -> Ok(Http1Request(req, Http1, buffered_tail))
        #(1, 1) -> Ok(Http1Request(req, Http11, buffered_tail))
        _ -> Error(InvalidHttpVersion)
      }
    }
    // "\r\nSM\r\n\r\n"
    Ok(Http2Upgrade(<<
      13:int,
      10:int,
      83:int,
      77:int,
      13:int,
      10:int,
      13:int,
      10:int,
      data:bits,
    >>)) -> {
      Ok(Upgrade(data))
    }
    Ok(MoreData(size)) -> {
      use next <- result.try(read_head_data(
        bs,
        conn.socket,
        conn.transport,
        size,
        budget,
      ))
      parse_request_head(next, conn, budget)
    }
    _ -> Error(DiscardPacket)
  }
}

pub type Body {
  // Keep Initial for bodyless HTTP/1 and WS upgrade bytes, and the Connection
  // tuple layout stable for the gateway's pinned Erlang socket FFI.
  Initial(BitArray)
  // Nonempty HTTP/1 bodies get fresh request-local subjects. The permit makes
  // completion one-shot; no connection-wide registry or extra actor is needed.
  Framed(data: BitArray, completion: Subject(BitArray), permit: Subject(Nil))
  Stream(
    selector: Selector(BitArray),
    data: BitArray,
    remaining: Int,
    attempts: Int,
  )
}

fn framed(data: BitArray) -> Body {
  let permit = process.new_subject()
  process.send(permit, Nil)
  Framed(data, process.new_subject(), permit)
}

fn content_length(headers: List(#(String, String))) -> Int {
  headers
  |> list.key_find("content-length")
  |> result.try(int.parse)
  |> result.unwrap(0)
}

fn frame_body(
  headers: Dict(String, String),
  rest: BitArray,
) -> #(Body, BitArray) {
  let length = content_length(dict.to_list(headers))
  case dict.get(headers, "transfer-encoding"), dict.get(headers, "upgrade") {
    Ok("chunked"), _ -> #(framed(rest), <<>>)
    _, Ok(upgrade) if length == 0 -> {
      // The gateway also performs its own WS handoff using Initial(rest).
      // An ordinary read_body still returns an empty HTTP body in this case.
      case websocket_upgrade(upgrade) {
        True -> #(Initial(rest), <<>>)
        False -> #(Initial(<<>>), rest)
      }
    }
    _, _ ->
      case rest {
        <<body:bytes-size(length), tail:bytes>> -> {
          let body = case length {
            0 -> Initial(body)
            _ -> framed(body)
          }
          #(body, tail)
        }
        _ -> #(framed(rest), <<>>)
      }
  }
}

fn complete_body(conn: Connection, tail: BitArray) -> Nil {
  case conn.body {
    Framed(_, completion, permit) ->
      case process.receive(permit, 0) {
        Ok(_) -> process.send(completion, tail)
        Error(_) -> Nil
      }
    _ -> Nil
  }
}

fn body_completed(conn: Connection) -> Bool {
  case conn.body {
    Framed(_, completion, _) ->
      case process.receive(completion, 0) {
        Ok(tail) -> {
          // Peek, do not steal the connection loop's tail. Repeated terminal
          // stream tokens must not read a new request from the socket.
          process.send(completion, tail)
          True
        }
        Error(_) -> False
      }
    Initial(_) -> True
    _ -> False
  }
}

pub fn body_tail(req: Request(Connection)) -> Result(BitArray, Nil) {
  case req.body.body {
    Framed(_, completion, permit) -> {
      // Retire the unused permit too when a route leaves its body unread.
      let _ = process.receive(permit, 0)
      process.receive(completion, 0) |> result.replace_error(Nil)
    }
    Initial(_) ->
      // Never reinterpret WebSocket bytes when an upgrade was rejected.
      case request.get_header(req, "upgrade") {
        Ok(value) ->
          case websocket_upgrade(value) {
            True -> Error(Nil)
            False -> Ok(<<>>)
          }
        Error(_) -> Ok(<<>>)
      }
    Stream(..) -> Error(Nil)
  }
}

/// Called by the request owner before a terminal chunked response handoff.
/// Peek only: leave the body-completion tail for its existing owner, and never
/// drain unread request input to make a downstream close observer safe.
pub fn request_body_completed(conn: Connection) -> Bool {
  body_completed(conn)
}

pub type BodyReader {
  FixedReader(buffer: Buffer, deadline: Int)
  ChunkedReader(decoder: chunked.Decoder, deadline: Int)
}

pub type BodyStep {
  BodyChunk(data: BitArray, reader: BodyReader)
  BodyDone
}

@external(erlang, "mist_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

pub fn body_reader(
  req: Request(Connection),
  limit: Int,
) -> Result(BodyReader, DecodeError) {
  let length = content_length(req.headers)
  use _ <- result.try(case limit < 0 || length > limit {
    True -> Error(BodyTooLarge)
    False -> Ok(Nil)
  })
  use _ <- result.try(handle_continue(req))
  let deadline = monotonic_ms() + 15_000
  case req.body.body {
    Initial(data) | Framed(data, ..) ->
      case request.get_header(req, "transfer-encoding") {
        Ok("chunked") -> Ok(ChunkedReader(chunked.new(data, limit), deadline))
        _ -> {
          let #(data, _) = buffer.slice(buffer.new(data), length)
          Ok(FixedReader(
            Buffer(length - bit_array.byte_size(data), data),
            deadline,
          ))
        }
      }
    _ -> Error(InvalidBody)
  }
}

fn read_body_data(
  req: Request(Connection),
  amount: Int,
  deadline: Int,
) -> Result(BitArray, DecodeError) {
  let timeout = deadline - monotonic_ms()
  case amount > 0 && timeout > 0 {
    True ->
      transport.receive_timeout(
        req.body.transport,
        req.body.socket,
        int.min(amount, 1_000_000),
        timeout,
      )
      |> result.replace_error(InvalidBody)
    False -> Error(InvalidBody)
  }
}

pub fn read_body_chunk(
  req: Request(Connection),
  reader: BodyReader,
  size: Int,
) -> Result(BodyStep, DecodeError) {
  use _ <- result.try(case size > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidBody)
  })
  case body_completed(req.body) {
    True -> Ok(BodyDone)
    False -> advance_body_reader(req, reader, size)
  }
}

fn advance_body_reader(
  req: Request(Connection),
  reader: BodyReader,
  size: Int,
) -> Result(BodyStep, DecodeError) {
  case reader {
    FixedReader(buffer, deadline) ->
      case buffer.data, buffer.remaining {
        <<>>, 0 -> {
          complete_body(req.body, <<>>)
          Ok(BodyDone)
        }
        <<>>, remaining -> {
          use data <- result.try(read_body_data(
            req,
            int.min(size, remaining),
            deadline,
          ))
          let buffer = Buffer(remaining - bit_array.byte_size(data), data)
          read_body_chunk(req, FixedReader(buffer, deadline), size)
        }
        _, _ -> {
          let #(data, rest) = buffer.slice(buffer, size)
          Ok(BodyChunk(
            data,
            FixedReader(Buffer(..buffer, data: rest), deadline),
          ))
        }
      }
    ChunkedReader(decoder, deadline) -> {
      use step <- result.try(
        chunked.next(decoder, size)
        |> result.map_error(fn(error) {
          case error {
            chunked.Invalid -> InvalidBody
            chunked.TooLarge -> BodyTooLarge
          }
        }),
      )
      case step {
        chunked.Complete(tail) -> {
          complete_body(req.body, tail)
          Ok(BodyDone)
        }
        chunked.Chunk(data, next) ->
          Ok(BodyChunk(data, ChunkedReader(next, deadline)))
        chunked.NeedData(next, amount) -> {
          use data <- result.try(read_body_data(req, amount, deadline))
          read_body_chunk(
            req,
            ChunkedReader(chunked.append(next, data), deadline),
            size,
          )
        }
      }
    }
  }
}

fn collect_body(
  req: Request(Connection),
  reader: BodyReader,
  body: BytesTree,
) -> Result(Request(BitArray), DecodeError) {
  use step <- result.try(read_body_chunk(req, reader, 65_536))
  case step {
    BodyDone -> Ok(request.set_body(req, bytes_tree.to_bit_array(body)))
    BodyChunk(data, next) ->
      collect_body(req, next, bytes_tree.append(body, data))
  }
}

pub fn read_body(
  req: Request(Connection),
  limit: Int,
) -> Result(Request(BitArray), DecodeError) {
  let stream_length = case req.body.body {
    Stream(data: data, remaining: remaining, ..) ->
      remaining + bit_array.byte_size(data)
    _ -> 0
  }
  use _ <- result.try(case stream_length > limit || limit < 0 {
    True -> Error(BodyTooLarge)
    False -> Ok(Nil)
  })
  case req.body.body {
    Initial(_) | Framed(..) -> {
      use reader <- result.try(body_reader(req, limit))
      collect_body(req, reader, bytes_tree.new())
    }
    Stream(
      selector: selector,
      data: data,
      remaining: remaining,
      attempts: attempts,
    )
      if remaining > 0
    -> {
      let res =
        selector
        |> process.selector_receive(1000)
        |> result.replace_error(InvalidBody)
      use next <- result.try(res)
      let got = bit_array.byte_size(next)
      let left = int.max(remaining - got, 0)
      let new_data = bit_array.append(data, next)
      case left {
        0 -> Ok(request.set_body(req, new_data))
        _rem ->
          read_body(
            request.set_body(
              req,
              Connection(
                ..req.body,
                body: Stream(selector, new_data, left, attempts + 1),
              ),
            ),
            limit,
          )
      }
    }
    Stream(data: data, ..) -> {
      Ok(request.set_body(req, data))
    }
  }
}

const websocket_key = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

pub type ShaHash {
  Sha
}

fn parse_websocket_key(key: String) -> String {
  key
  |> string.append(websocket_key)
  |> crypto_hash(Sha, _)
  |> base64_encode
}

pub fn upgrade_socket(
  req: Request(Connection),
  extensions: List(String),
) -> Result(Response(BytesTree), Request(Connection)) {
  use _ <- result.try(case req.body.body {
    Initial(_) -> Ok(Nil)
    // An HTTP request body is not a WebSocket frame buffer.
    Framed(..) | Stream(..) -> Error(req)
  })
  use _upgrade <- result.try(
    request.get_header(req, "upgrade")
    |> result.replace_error(req),
  )
  use key <- result.try(
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(req),
  )
  use _version <- result.try(
    request.get_header(req, "sec-websocket-version")
    |> result.replace_error(req),
  )

  let permessage_deflate = websocket.has_deflate(extensions)

  let accept_key = parse_websocket_key(key)

  let resp =
    response.new(101)
    |> response.set_body(bytes_tree.new())
    |> response.prepend_header("upgrade", "websocket")
    |> response.prepend_header("connection", "Upgrade")
    |> response.prepend_header("sec-websocket-accept", accept_key)

  case permessage_deflate {
    True ->
      Ok(response.prepend_header(
        resp,
        "sec-websocket-extensions",
        "permessage-deflate",
      ))
    False -> Ok(resp)
  }
}

// TODO: improve this error type
pub fn upgrade(
  socket: Socket,
  transport: Transport,
  extensions: List(String),
  req: Request(Connection),
) -> Result(Nil, Nil) {
  use resp <- result.try(
    upgrade_socket(req, extensions)
    |> result.replace_error(Nil),
  )

  use _sent <- result.try(
    resp
    |> add_default_headers(req.method == http.Head)
    |> maybe_keep_alive
    |> encoder.to_bytes_tree("1.1")
    |> transport.send(transport, socket, _)
    |> result.replace_error(Nil),
  )

  Ok(Nil)
}

pub fn add_date_header(resp: Response(any)) -> Response(any) {
  case response.get_header(resp, "date") {
    Error(_nil) -> response.set_header(resp, "date", clock.get_date())
    _ -> resp
  }
}

pub fn connection_close(resp: Response(any)) -> Response(any) {
  response.set_header(resp, "connection", "close")
}

pub fn keep_alive(resp: Response(any)) -> Response(any) {
  response.set_header(resp, "connection", "keep-alive")
}

pub fn maybe_keep_alive(resp: Response(any)) -> Response(any) {
  case response.get_header(resp, "connection") {
    Ok(_) -> resp
    _ -> response.set_header(resp, "connection", "keep-alive")
  }
}

fn maybe_drop_body(
  resp: Response(BytesTree),
  is_head_request: Bool,
) -> Response(BytesTree) {
  case is_head_request {
    True -> response.set_body(resp, bytes_tree.new())
    False -> resp
  }
}

pub fn add_content_length(
  when when: Bool,
  length length: Int,
) -> fn(Response(any)) -> Response(any) {
  fn(resp: Response(any)) {
    case when {
      True -> {
        let #(_existing, headers) =
          resp.headers
          |> list.key_pop("content-length")
          |> result.lazy_unwrap(fn() { #("", resp.headers) })

        Response(..resp, headers: headers)
        |> response.set_header("content-length", int.to_string(length))
      }
      False -> resp
    }
  }
}

pub fn add_default_headers(
  resp: Response(BytesTree),
  is_head_response: Bool,
) -> Response(BytesTree) {
  let body_size = bytes_tree.byte_size(resp.body)
  let #(_existing_content_length, headers) =
    resp.headers
    |> list.key_pop("content-length")
    |> result.lazy_unwrap(fn() { #("", resp.headers) })

  let resp = case resp.status, body_size {
    // explicitly drop
    n, _ if n >= 100 && n <= 199 -> Response(..resp, headers:)
    // explicitly drop
    n, _ if n == 204 -> Response(..resp, headers:)
    // don't add, don't drop
    n, 0 if n == 304 -> resp
    // don't add, don't drop
    _, 0 if is_head_response == True -> resp
    // explicitly overwrite
    _, _ ->
      response.set_header(resp, "content-length", int.to_string(body_size))
  }

  resp
  |> add_date_header
  |> maybe_drop_body(is_head_response)
}

fn is_continue(req: Request(Connection)) -> Bool {
  req.headers
  |> list.find(fn(tup) { tup.0 == "expect" && tup.1 == "100-continue" })
  |> result.is_ok
}

pub fn handle_continue(req: Request(Connection)) -> Result(Nil, DecodeError) {
  case is_continue(req) {
    True -> {
      response.new(100)
      |> response.set_body(bytes_tree.new())
      |> encoder.to_bytes_tree("1.1")
      |> transport.send(req.body.transport, req.body.socket, _)
      |> result.replace_error(MalformedRequest)
    }
    False -> Ok(Nil)
  }
}

@external(erlang, "mist_ffi", "decode_packet")
fn decode_packet(
  packet_type packet_type: PacketType,
  packet packet: BitArray,
  options options: List(a),
) -> Result(DecodedPacket, DecodeError)

@external(erlang, "crypto", "hash")
pub fn crypto_hash(hash hash: ShaHash, data data: String) -> String

@external(erlang, "base64", "encode")
pub fn base64_encode(data data: String) -> String

@external(erlang, "mist_ffi", "get_path_and_query")
fn get_path_and_query(
  str: String,
) -> Result(#(String, Result(String, Nil)), #(value, term))
