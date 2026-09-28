import gleam/bit_array
import gleam/bytes_tree
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/types.{type Header, Header as HttpHeader}

/// The local endpoint's role. A server receives masked frames; a client
/// receives unmasked frames. There is no mask-key generator in this module.
pub type Role {
  Server
  Client
}

pub type Event {
  Text(String)
  Ping(BitArray)
  Pong(BitArray)
  Close(Option(Int), Option(String))
}

type Phase {
  Header
  Length(fin: Bool, opcode: Int, tag: Int)
  Mask(fin: Bool, opcode: Int, length: Int)
  Payload(fin: Bool, opcode: Int, length: Int, mask: Option(BitArray))
}

/// Failed feeds are terminal: discard the decoder and close the socket. A
/// successful feed retains at most one bounded frame and one bounded message.
pub opaque type Decoder {
  Decoder(
    role: Role,
    max_frame_bytes: Int,
    max_message_bytes: Int,
    phase: Phase,
    pending: bytes_tree.BytesTree,
    pending_size: Int,
    needed: Int,
    fragmented: Bool,
    message: bytes_tree.BytesTree,
    message_size: Int,
    closed: Bool,
  )
}

/// Limits are configurable up to 1 MiB, never unbounded.
pub fn new(
  role: Role,
  max_frame_bytes: Int,
  max_message_bytes: Int,
) -> Result(Decoder, String) {
  use _ <- result.try(ensure(
    max_frame_bytes > 0
      && max_message_bytes > 0
      && max_frame_bytes <= 1_048_576
      && max_message_bytes <= 1_048_576,
    "WS limits must be between 1 and 1048576 bytes",
  ))
  Ok(Decoder(
    role,
    max_frame_bytes,
    max_message_bytes,
    Header,
    bytes_tree.new(),
    0,
    2,
    False,
    bytes_tree.new(),
    0,
    False,
  ))
}

/// Accept arbitrary byte chunk boundaries, including within headers, mask
/// keys and UTF-8 sequences. Events are emitted only for completed frames.
/// No events are returned from an invalid feed, even if an earlier frame in
/// that same chunk was valid.
pub fn feed(
  decoder: Decoder,
  chunk: BitArray,
) -> Result(#(Decoder, List(Event)), String) {
  use _ <- result.try(ensure(
    bit_array.bit_size(chunk) % 8 == 0,
    "WS input must be byte aligned",
  ))
  scan(decoder, chunk, [])
}

/// On transport EOF validate framing independently of Responses completion.
/// A completed response does not make a truncated WS frame or unclean close OK.
pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  case decoder.closed, decoder.phase, decoder.pending_size, decoder.fragmented {
    True, _, _, _ -> Ok(Nil)
    False, Header, 0, False -> Error("WS disconnected without close")
    _, _, _, _ -> Error("WS disconnected with incomplete frame or message")
  }
}

fn scan(
  decoder: Decoder,
  chunk: BitArray,
  events: List(Event),
) -> Result(#(Decoder, List(Event)), String) {
  case decoder.closed {
    True ->
      case chunk {
        <<>> -> Ok(#(decoder, list.reverse(events)))
        _ -> Error("WS bytes after close")
      }
    False ->
      case chunk {
        <<>> -> Ok(#(decoder, list.reverse(events)))
        _ -> {
          let take =
            int.min(
              decoder.needed - decoder.pending_size,
              bit_array.byte_size(chunk),
            )
          let assert <<prefix:bits-size(take * 8), rest:bits>> = chunk
          // Copy the bounded slice: a subbinary retained across feeds must
          // not pin an arbitrarily large caller-supplied network chunk.
          let pending = bytes_tree.append(decoder.pending, copy_bytes(prefix))
          let size = decoder.pending_size + take
          let decoder = Decoder(..decoder, pending: pending, pending_size: size)
          case size == decoder.needed {
            False -> Ok(#(decoder, list.reverse(events)))
            True -> {
              let bytes = bytes_tree.to_bit_array(pending)
              let decoder =
                Decoder(..decoder, pending: bytes_tree.new(), pending_size: 0)
              use pair <- result.try(advance(decoder, bytes))
              let events = case pair.1 {
                None -> events
                Some(event) -> [event, ..events]
              }
              scan(pair.0, rest, events)
            }
          }
        }
      }
  }
}

fn advance(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, Option(Event)), String) {
  case decoder.phase {
    Header -> {
      let assert <<first:8, second:8>> = bytes
      let fin = int.bitwise_and(first, 128) != 0
      let opcode = int.bitwise_and(first, 15)
      let masked = int.bitwise_and(second, 128) != 0
      let tag = int.bitwise_and(second, 127)
      use _ <- result.try(ensure(
        int.bitwise_and(first, 112) == 0,
        "WS reserved bits are unsupported",
      ))
      use _ <- result.try(ensure(
        opcode == 0
          || opcode == 1
          || opcode == 2
          || opcode == 8
          || opcode == 9
          || opcode == 10,
        "WS reserved opcode",
      ))
      use _ <- result.try(ensure(
        case decoder.role {
          Server -> masked
          Client -> !masked
        },
        "WS mask does not match endpoint role",
      ))
      use _ <- result.try(ensure(
        opcode < 8 || fin && tag <= 125,
        "WS control frame must be final and at most 125 bytes",
      ))
      use _ <- result.try(ensure(
        case opcode {
          0 -> decoder.fragmented
          1 -> !decoder.fragmented
          2 -> False
          _ -> True
        },
        "WS continuation order invalid or binary message unsupported",
      ))
      case tag {
        126 | 127 ->
          Ok(#(
            Decoder(
              ..decoder,
              phase: Length(fin, opcode, tag),
              needed: case tag {
                126 -> 2
                _ -> 8
              },
            ),
            None,
          ))
        _ -> length_ready(decoder, fin, opcode, tag)
      }
    }
    Length(fin, opcode, tag) -> {
      let length = case tag, bytes {
        126, <<n:16>> -> n
        127, <<n:64>> -> n
        _, _ -> 0
      }
      use _ <- result.try(ensure(
        case tag {
          126 -> length >= 126
          _ -> length > 65_535 && length < 9_223_372_036_854_775_808
        },
        "WS nonminimal or invalid extended length",
      ))
      length_ready(decoder, fin, opcode, length)
    }
    Mask(fin, opcode, length) ->
      payload_ready(decoder, fin, opcode, length, Some(bytes))
    Payload(fin, opcode, _, mask) -> {
      let bytes = case mask {
        None -> bytes
        Some(key) -> xor_mask(bytes, key)
      }
      frame_ready(decoder, fin, opcode, bytes)
    }
  }
}

fn length_ready(
  decoder: Decoder,
  fin: Bool,
  opcode: Int,
  length: Int,
) -> Result(#(Decoder, Option(Event)), String) {
  use _ <- result.try(ensure(
    length <= decoder.max_frame_bytes,
    "WS frame exceeds byte limit",
  ))
  use _ <- result.try(ensure(
    opcode != 0
      && opcode != 1
      || decoder.message_size + length <= decoder.max_message_bytes,
    "WS message exceeds byte limit",
  ))
  case decoder.role {
    Server ->
      Ok(#(
        Decoder(..decoder, phase: Mask(fin, opcode, length), needed: 4),
        None,
      ))
    Client -> payload_ready(decoder, fin, opcode, length, None)
  }
}

fn payload_ready(
  decoder: Decoder,
  fin: Bool,
  opcode: Int,
  length: Int,
  mask: Option(BitArray),
) -> Result(#(Decoder, Option(Event)), String) {
  case length {
    0 -> frame_ready(decoder, fin, opcode, <<>>)
    _ ->
      Ok(#(
        Decoder(
          ..decoder,
          phase: Payload(fin, opcode, length, mask),
          needed: length,
        ),
        None,
      ))
  }
}

fn frame_ready(
  decoder: Decoder,
  fin: Bool,
  opcode: Int,
  payload: BitArray,
) -> Result(#(Decoder, Option(Event)), String) {
  let reset = Decoder(..decoder, phase: Header, needed: 2)
  case opcode {
    1 | 0 -> {
      let message = case payload {
        <<>> -> decoder.message
        _ -> bytes_tree.append(decoder.message, payload)
      }
      let size = decoder.message_size + bit_array.byte_size(payload)
      case fin {
        False ->
          Ok(#(
            Decoder(
              ..reset,
              fragmented: True,
              message: message,
              message_size: size,
            ),
            None,
          ))
        True -> {
          use text <- result.try(
            bit_array.to_string(bytes_tree.to_bit_array(message))
            |> result.map_error(fn(_) { "WS text message is not UTF-8" }),
          )
          Ok(#(
            Decoder(
              ..reset,
              fragmented: False,
              message: bytes_tree.new(),
              message_size: 0,
            ),
            Some(Text(text)),
          ))
        }
      }
    }
    9 -> Ok(#(reset, Some(Ping(payload))))
    10 -> Ok(#(reset, Some(Pong(payload))))
    8 -> {
      use close <- result.try(decode_close(payload))
      Ok(#(
        Decoder(
          ..reset,
          closed: True,
          fragmented: False,
          message: bytes_tree.new(),
          message_size: 0,
        ),
        Some(close),
      ))
    }
    _ -> Error("WS unsupported opcode")
  }
}

fn decode_close(payload: BitArray) -> Result(Event, String) {
  case payload {
    <<>> -> Ok(Close(None, None))
    <<_:8>> -> Error("WS close payload is missing status byte")
    <<code:16, reason:bits>> -> {
      use _ <- result.try(ensure(
        valid_close_code(code),
        "WS invalid close code",
      ))
      use text <- result.try(
        bit_array.to_string(reason)
        |> result.map_error(fn(_) { "WS close reason is not UTF-8" }),
      )
      Ok(Close(Some(code), Some(text)))
    }
    _ -> Error("WS close payload is not byte aligned")
  }
}

fn valid_close_code(code: Int) -> Bool {
  case code {
    n if n >= 1000 && n <= 1014 -> n != 1004 && n != 1005 && n != 1006
    n if n >= 3000 && n <= 4999 -> True
    _ -> False
  }
}

/// Encode one complete text message. Client masks are four bytes supplied by
/// the caller's cryptographically secure random source, never reused by us.
pub fn encode_text(
  role: Role,
  text: String,
  mask: Option(BitArray),
) -> Result(BitArray, String) {
  encode(role, 1, bit_array.from_string(text), mask)
}

pub fn encode_ping(
  role: Role,
  payload: BitArray,
  mask: Option(BitArray),
) -> Result(BitArray, String) {
  encode(role, 9, payload, mask)
}

pub fn encode_pong(
  role: Role,
  payload: BitArray,
  mask: Option(BitArray),
) -> Result(BitArray, String) {
  encode(role, 10, payload, mask)
}

pub fn encode_close(
  role: Role,
  code: Option(Int),
  reason: String,
  mask: Option(BitArray),
) -> Result(BitArray, String) {
  use payload <- result.try(case code {
    None ->
      case reason {
        "" -> Ok(<<>>)
        _ -> Error("WS close reason requires a status code")
      }
    Some(code) -> {
      use _ <- result.try(ensure(
        valid_close_code(code),
        "WS invalid close code",
      ))
      let reason_bytes = bit_array.from_string(reason)
      Ok(<<code:16, reason_bytes:bits>>)
    }
  })
  encode(role, 8, payload, mask)
}

fn encode(
  role: Role,
  opcode: Int,
  payload: BitArray,
  mask: Option(BitArray),
) -> Result(BitArray, String) {
  use _ <- result.try(ensure(
    bit_array.bit_size(payload) % 8 == 0,
    "WS payload must be byte aligned",
  ))
  let size = bit_array.byte_size(payload)
  use _ <- result.try(ensure(
    size <= 1_048_576,
    "WS encoded frame exceeds byte limit",
  ))
  use _ <- result.try(ensure(
    opcode == 1 || size <= 125,
    "WS control frame exceeds 125 bytes",
  ))
  use key <- result.try(case role, mask {
    Client, Some(key) ->
      case bit_array.byte_size(key) == 4 && bit_array.bit_size(key) == 32 {
        True -> Ok(Some(key))
        False -> Error("WS client mask must contain four bytes")
      }
    Server, None -> Ok(None)
    _, _ -> Error("WS mask does not match endpoint role")
  })
  let mask_bit = case key {
    None -> 0
    Some(_) -> 128
  }
  let first = 128 + opcode
  let header = case size {
    n if n <= 125 -> {
      let second = mask_bit + n
      <<first, second>>
    }
    n if n <= 65_535 -> {
      let second = mask_bit + 126
      <<first, second, n:16>>
    }
    n -> {
      let second = mask_bit + 127
      <<first, second, n:64>>
    }
  }
  case key {
    None -> Ok(<<header:bits, payload:bits>>)
    Some(key) -> {
      let masked = xor_mask(payload, key)
      Ok(<<header:bits, key:bits, masked:bits>>)
    }
  }
}

/// Validates a canonical 16-byte RFC6455 nonce before computing the accept
/// value. The caller must still verify HTTP Upgrade/Connection/version headers.
pub fn accept_key(key: String) -> Result(String, String) {
  let key = string.trim(key)
  use decoded <- result.try(
    bit_array.base64_decode(key)
    |> result.map_error(fn(_) { "WS key is not base64" }),
  )
  use _ <- result.try(ensure(
    bit_array.byte_size(decoded) == 16
      && bit_array.base64_encode(decoded, True) == key,
    "WS key must be canonical base64 of 16 bytes",
  ))
  Ok(
    sha1(bit_array.from_string(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    |> bit_array.base64_encode(True),
  )
}

pub fn verify_accept(key: String, received: String) -> Result(Nil, String) {
  use expected <- result.try(accept_key(key))
  ensure(string.trim(received) == expected, "WS accept key mismatch")
}

/// Authentication/origin policy MUST run before this helper. It only validates
/// an HTTP/1.1 Upgrade envelope and returns ordered handshake response headers.
/// No extensions or subprotocols are negotiated by this implementation.
pub fn server_upgrade(
  method: String,
  headers: List(Header),
) -> Result(List(Header), String) {
  use _ <- result.try(ensure(method == "GET", "WS upgrade requires GET"))
  use _ <- result.try(upgrade_tokens(headers))
  use version <- result.try(single_header(headers, "sec-websocket-version"))
  use _ <- result.try(ensure(version == "13", "WS version must be 13"))
  use key <- result.try(single_header(headers, "sec-websocket-key"))
  use accept <- result.try(accept_key(key))
  use _ <- result.try(ensure(
    header_values(headers, "sec-websocket-protocol") == [],
    "WS subprotocol negotiation is unsupported",
  ))
  // Offers of extensions can legally be declined: no extension response header.
  Ok([
    HttpHeader("Upgrade", "websocket"),
    HttpHeader("Connection", "Upgrade"),
    HttpHeader("Sec-WebSocket-Accept", accept),
  ])
}

pub fn client_upgrade(
  status: Int,
  headers: List(Header),
  key: String,
) -> Result(Nil, String) {
  use _ <- result.try(ensure(status == 101, "WS upgrade requires HTTP 101"))
  use _ <- result.try(upgrade_tokens(headers))
  use accept <- result.try(single_header(headers, "sec-websocket-accept"))
  use _ <- result.try(verify_accept(key, accept))
  ensure(
    header_values(headers, "sec-websocket-extensions") == []
      && header_values(headers, "sec-websocket-protocol") == [],
    "WS server negotiated unsupported extensions or subprotocol",
  )
}

fn upgrade_tokens(headers: List(Header)) -> Result(Nil, String) {
  use upgrade <- result.try(single_header(headers, "upgrade"))
  let connections =
    header_values(headers, "connection")
    |> list.flat_map(fn(value) { string.split(value, ",") })
    |> list.map(fn(value) { value |> string.trim |> string.lowercase })
  ensure(
    string.lowercase(upgrade) == "websocket"
      && list.contains(connections, "upgrade"),
    "invalid WS Upgrade or Connection header",
  )
}

fn header_values(headers: List(Header), name: String) -> List(String) {
  headers
  |> list.filter(fn(h) { string.lowercase(h.name) == name })
  |> list.map(fn(h) { string.trim(h.value) })
}

fn single_header(
  headers: List(Header),
  name: String,
) -> Result(String, String) {
  case header_values(headers, name) {
    [value] -> Ok(value)
    _ -> Error("WS requires exactly one " <> name)
  }
}

fn ensure(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

/// Pure bytewise XOR and SHA-1 primitives; framing decisions live above.
@external(erlang, "binary", "copy")
fn copy_bytes(bytes: BitArray) -> BitArray

@external(erlang, "mimic_responses_ws_ffi", "xor_mask")
fn xor_mask(payload: BitArray, mask: BitArray) -> BitArray

@external(erlang, "mimic_responses_ws_ffi", "sha1")
fn sha1(value: BitArray) -> BitArray
