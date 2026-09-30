import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir

/// Only uncompressed frames are supported. Gzip fails explicitly, not as UTF-8.
pub type Frame {
  Data(BitArray)
  End
}

pub opaque type Decoder {
  Decoder(pending: BitArray, ended: Bool, failed: Bool)
}

pub fn new() -> Decoder {
  Decoder(<<>>, False, False)
}

pub fn envelope(payload: BitArray) -> BitArray {
  <<0, { bit_array.byte_size(payload) }:32-big, payload:bits>>
}

/// A successful End is required; socket EOF alone never manufactures success.
pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  case decoder {
    Decoder(<<>>, True, False) -> Ok(Nil)
    _ -> Error("devin stream missing terminal frame or truncated")
  }
}

pub fn feed(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, List(Frame)), String) {
  let #(next, frames, error) = feed_prefix(decoder, bytes)
  case error {
    None -> Ok(#(next, frames))
    Some(error) -> Error(error)
  }
}

/// Emit the valid prefix even if a later frame in this chunk is invalid.
/// A decoder returned with an error must not be fed again.
pub fn feed_prefix(
  decoder: Decoder,
  bytes: BitArray,
) -> #(Decoder, List(Frame), Option(String)) {
  case decoder.failed {
    True -> #(decoder, [], Some("devin connect decoder failed"))
    False -> feed_bytes(decoder, bytes)
  }
}

fn feed_bytes(
  decoder: Decoder,
  bytes: BitArray,
) -> #(Decoder, List(Frame), Option(String)) {
  // Each frame is bounded below before buffering an incomplete payload. A
  // transport read can legitimately contain multiple complete bounded frames;
  // rejecting the sum would make valid-prefix semantics depend on packet size.
  consume(<<decoder.pending:bits, bytes:bits>>, decoder.ended, [])
}

fn consume(
  bytes: BitArray,
  ended: Bool,
  frames: List(Frame),
) -> #(Decoder, List(Frame), Option(String)) {
  case bytes, ended {
    <<>>, _ -> #(Decoder(<<>>, ended, False), list.reverse(frames), None)
    _, True -> {
      // A terminal marker followed by bytes in this same feed was not a
      // successful end. Retain preceding data, but do not emit End.
      let frames = case frames {
        [End, ..previous] -> previous
        _ -> frames
      }
      #(
        Decoder(<<>>, True, True),
        list.reverse(frames),
        Some("devin data after terminal frame"),
      )
    }
    <<flag, _:bits>>, _ if flag != 0 && flag != 2 -> #(
      Decoder(<<>>, False, True),
      list.reverse(frames),
      Some("unsupported devin connect flag or compression"),
    )
    <<_, size:32-big, _:bits>>, _ if size > 8_388_608 -> #(
      Decoder(<<>>, False, True),
      list.reverse(frames),
      Some("devin connect frame limit"),
    )
    <<flag, size:32-big, payload:bytes-size(size), rest:bits>>, _ -> {
      case flag {
        0 -> consume(rest, False, [Data(payload), ..frames])
        _ -> {
          case trailer(payload) {
            Ok(_) -> consume(rest, True, [End, ..frames])
            Error(error) -> #(
              Decoder(<<>>, False, True),
              list.reverse(frames),
              Some(error),
            )
          }
        }
      }
    }
    _, _ -> #(Decoder(bytes, False, False), list.reverse(frames), None)
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
