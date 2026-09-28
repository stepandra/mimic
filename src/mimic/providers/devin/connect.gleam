import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir

/// Only uncompressed frames are supported. Gzip fails explicitly, not as UTF-8.
pub type Frame {
  Data(BitArray)
  End
}

pub opaque type Decoder {
  Decoder(pending: BitArray, ended: Bool)
}

pub fn new() -> Decoder {
  Decoder(<<>>, False)
}

pub fn envelope(payload: BitArray) -> BitArray {
  <<0, { bit_array.byte_size(payload) }:32-big, payload:bits>>
}

/// A successful End is required; socket EOF alone never manufactures success.
pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  case decoder {
    Decoder(<<>>, True) -> Ok(Nil)
    _ -> Error("devin stream missing terminal frame or truncated")
  }
}

pub fn feed(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, List(Frame)), String) {
  case
    bit_array.byte_size(bytes) + bit_array.byte_size(decoder.pending)
    > 8_388_613
  {
    True -> Error("devin connect buffer limit")
    False -> consume(<<decoder.pending:bits, bytes:bits>>, decoder.ended, [])
  }
}

fn consume(
  bytes: BitArray,
  ended: Bool,
  frames: List(Frame),
) -> Result(#(Decoder, List(Frame)), String) {
  case bytes, ended {
    <<>>, _ -> Ok(#(Decoder(<<>>, ended), list.reverse(frames)))
    _, True -> Error("devin data after terminal frame")
    <<flag, _:bits>>, _ if flag != 0 && flag != 2 ->
      Error("unsupported devin connect flag or compression")
    <<_, size:32-big, _:bits>>, _ if size > 8_388_608 ->
      Error("devin connect frame limit")
    <<flag, size:32-big, payload:bytes-size(size), rest:bits>>, _ -> {
      case flag {
        0 -> consume(rest, False, [Data(payload), ..frames])
        _ -> {
          use _ <- result.try(trailer(payload))
          consume(rest, True, [End, ..frames])
        }
      }
    }
    _, _ -> Ok(#(Decoder(bytes, False), list.reverse(frames)))
  }
}

/// Return fixed diagnostics only: a trailer message can echo private material.
pub fn trailer(payload: BitArray) -> Result(Nil, String) {
  use text <- result.try(
    bit_array.to_string(payload)
    |> result.replace_error("invalid devin trailer UTF-8"),
  )
  use value <- result.try(
    ir.parse(text) |> result.replace_error("invalid devin trailer JSON"),
  )
  use _ <- result.try(
    ir.as_object(value) |> result.replace_error("invalid devin trailer object"),
  )
  case ir.field(value, "error") {
    None | Some(ir.Null) -> Ok(Nil)
    Some(error) -> {
      let code = ir.string_field(error, "code") |> result.unwrap("")
      let message =
        ir.string_field(error, "message")
        |> result.unwrap("")
        |> string.lowercase
      let status = trailer_status(code, message)
      Error("devin upstream trailer status " <> status)
    }
  }
}

fn trailer_status(code: String, message: String) -> String {
  case string.lowercase(code) {
    "unauthenticated" -> "401"
    "resource_exhausted" -> "429"
    "permission_denied" ->
      case string.contains(message, "high demand") {
        True -> "429"
        False -> "403"
      }
    "unavailable" -> "503"
    "canceled" -> "499"
    "deadline_exceeded" -> "504"
    "invalid_argument" ->
      case string.contains(message, "internal error") {
        True -> "502"
        False -> "400"
      }
    "failed_precondition" ->
      case
        list.any(["quota", "credit", "acu", "exhausted", "limit"], fn(word) {
          string.contains(message, word)
        })
      {
        True -> "429"
        False -> "400"
      }
    _ -> "502"
  }
}
