/// Bounded UTF-8 SSE framing shared by native protocol validators.
/// Extracted from the Responses byte scanner, not a competing SSE grammar.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Frame {
  Frame(name: String, data: String)
}

pub opaque type Decoder {
  Decoder(
    pending: BitArray,
    data: List(String),
    name: String,
    bytes: Int,
    skip_lf: Bool,
    cr_bytes: Int,
    first_line: Bool,
    max_bytes: Int,
  )
}

pub fn new(max_bytes: Int) -> Decoder {
  Decoder(<<>>, [], "", 0, False, 0, True, max_bytes)
}

/// Stop at one frame, leaving the untouched tail for the caller. An invalid
/// later frame can never erase a valid prefix because TCP coalesced the bytes.
pub fn feed_one(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, Option(Frame), BitArray), String) {
  use _ <- result.try(ensure(
    bit_array.bit_size(bytes) % 8 == 0,
    "SSE input must be byte aligned",
  ))
  use _ <- result.try(ensure(decoder.max_bytes > 0, "invalid SSE byte limit"))
  scan(decoder, bytes)
}

fn scan(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, Option(Frame), BitArray), String) {
  case bytes {
    <<>> -> Ok(#(decoder, None, <<>>))
    <<10, rest:bits>> if decoder.skip_lf -> {
      use _ <- result.try(ensure(
        decoder.cr_bytes + 1 <= decoder.max_bytes,
        "SSE frame exceeds byte limit",
      ))
      let count = case decoder.bytes {
        0 -> 0
        count -> count + 1
      }
      scan(Decoder(..decoder, skip_lf: False, bytes: count), rest)
    }
    _ -> {
      let decoder = Decoder(..decoder, skip_lf: False)
      let #(prefix, separator, rest) = split_line(bytes)
      let size = bit_array.byte_size(prefix)
      use _ <- result.try(ensure(
        decoder.bytes + size <= decoder.max_bytes,
        "SSE frame exceeds byte limit",
      ))
      let pending = <<decoder.pending:bits, copy_bytes(prefix):bits>>
      let decoder = Decoder(..decoder, bytes: decoder.bytes + size)
      case separator {
        0 -> Ok(#(Decoder(..decoder, pending: pending), None, <<>>))
        _ -> {
          use line <- result.try(
            bit_array.to_string(pending)
            |> result.replace_error("invalid UTF-8 in SSE"),
          )
          let line = case decoder.first_line {
            True ->
              case string.starts_with(line, "\u{FEFF}") {
                True -> string.drop_start(line, 1)
                False -> line
              }
            False -> line
          }
          let decoder =
            Decoder(
              ..decoder,
              pending: <<>>,
              skip_lf: separator == 13,
              cr_bytes: decoder.bytes + 1,
              first_line: False,
              bytes: decoder.bytes + 1,
            )
          use _ <- result.try(ensure(
            decoder.bytes <= decoder.max_bytes,
            "SSE frame exceeds byte limit",
          ))
          case line {
            "" -> {
              let frame =
                Frame(
                  decoder.name,
                  decoder.data |> list.reverse |> string.join("\n"),
                )
              Ok(#(
                Decoder(..decoder, data: [], name: "", bytes: 0),
                Some(frame),
                rest,
              ))
            }
            _ -> scan(line_received(decoder, line), rest)
          }
        }
      }
    }
  }
}

fn line_received(decoder: Decoder, line: String) -> Decoder {
  let #(field, value) = case string.split_once(line, ":") {
    Ok(#(field, value)) -> #(
      field,
      string.drop_start(value, case string.starts_with(value, " ") {
        True -> 1
        False -> 0
      }),
    )
    Error(_) -> #(line, "")
  }
  case field {
    "data" -> Decoder(..decoder, data: [value, ..decoder.data])
    "event" -> Decoder(..decoder, name: value)
    // Transport metadata, never model output; no automatic reconnect/replay.
    _ -> decoder
  }
}

pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  ensure(
    decoder.pending == <<>> && decoder.data == [] && decoder.name == "",
    "truncated SSE frame",
  )
}

/// Discard unfinished frame data on local cancellation.
pub fn reset(decoder: Decoder) -> Decoder {
  new(decoder.max_bytes)
}

@external(erlang, "mimic_responses_bytes_ffi", "split_line")
fn split_line(bytes: BitArray) -> #(BitArray, Int, BitArray)

@external(erlang, "binary", "copy")
fn copy_bytes(bytes: BitArray) -> BitArray

fn ensure(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}
