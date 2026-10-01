// MIMIC F44: incremental chunk framing shared by read_body and stream.
// Socket reads and route dispatch stay outside this pure decoder.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Error {
  Invalid
  TooLarge
}

type Phase {
  Size
  Data(Int)
  Terminator
  Trailers
}

pub opaque type Decoder {
  Decoder(
    phase: Phase,
    pending: BitArray,
    total: Int,
    limit: Int,
    metadata: Int,
  )
}

pub type Step {
  NeedData(decoder: Decoder, bytes: Int)
  Chunk(data: BitArray, decoder: Decoder)
  Complete(tail: BitArray)
}

const max_line_bytes = 8192

const max_metadata_bytes = 65_536

pub fn new(data: BitArray, limit: Int) -> Decoder {
  Decoder(Size, data, 0, limit, 0)
}

pub fn append(decoder: Decoder, data: BitArray) -> Decoder {
  Decoder(..decoder, pending: bit_array.append(decoder.pending, data))
}

@external(erlang, "mist_ffi", "binary_match")
fn binary_match(data: BitArray, pattern: BitArray) -> Result(#(Int, Int), Nil)

fn line(decoder: Decoder) -> Result(Step, Error) {
  case binary_match(decoder.pending, <<"\r\n":utf8>>) {
    Error(_) ->
      case
        bit_array.byte_size(decoder.pending) > max_line_bytes
        || decoder.metadata + bit_array.byte_size(decoder.pending)
        > max_metadata_bytes
      {
        True -> Error(Invalid)
        // Reading one metadata byte cannot prefetch an unchecked chunk body.
        False -> Ok(NeedData(decoder, 1))
      }
    Ok(#(length, _)) -> {
      let metadata = decoder.metadata + length + 2
      use _ <- result.try(
        case length > max_line_bytes || metadata > max_metadata_bytes {
          True -> Error(Invalid)
          False -> Ok(Nil)
        },
      )
      let assert <<value:bytes-size(length), 13, 10, rest:bytes>> =
        decoder.pending
      use value <- result.try(
        bit_array.to_string(value) |> result.replace_error(Invalid),
      )
      let decoder = Decoder(..decoder, pending: rest, metadata:)
      case decoder.phase {
        Size -> {
          use size <- result.try(chunk_size(value))
          case decoder.total + size > decoder.limit {
            True -> Error(TooLarge)
            False ->
              case size {
                0 -> next(Decoder(..decoder, phase: Trailers), 1)
                _ ->
                  Ok(NeedData(
                    Decoder(
                      ..decoder,
                      phase: Data(size),
                      total: decoder.total + size,
                    ),
                    0,
                  ))
              }
          }
        }
        Trailers ->
          case value {
            "" -> Ok(Complete(rest))
            _ -> {
              use _ <- result.try(validate_trailer(value))
              next(decoder, 1)
            }
          }
        _ -> Error(Invalid)
      }
    }
  }
}

fn is_hex(codepoint: Int) -> Bool {
  codepoint >= 48
  && codepoint <= 57
  || codepoint >= 65
  && codepoint <= 70
  || codepoint >= 97
  && codepoint <= 102
}

fn chunk_size(value: String) -> Result(Int, Error) {
  let #(size, extension) =
    string.split_once(value, ";") |> result.unwrap(#(value, ""))
  let valid =
    size != ""
    && string.byte_size(size) <= 16
    && list.all(string.to_utf_codepoints(size), fn(codepoint) {
      is_hex(string.utf_codepoint_to_int(codepoint))
    })
    && list.all(string.to_utf_codepoints(extension), fn(codepoint) {
      let codepoint = string.utf_codepoint_to_int(codepoint)
      codepoint == 9 || codepoint >= 32 && codepoint <= 126
    })
  case valid {
    True -> int.base_parse(size, 16) |> result.replace_error(Invalid)
    False -> Error(Invalid)
  }
}

fn validate_trailer(value: String) -> Result(Nil, Error) {
  use #(name, value) <- result.try(
    string.split_once(value, ":") |> result.replace_error(Invalid),
  )
  let forbidden = [
    "content-length", "transfer-encoding", "host", "authorization", "cookie",
    "origin", "x-csrf-token", "connection", "upgrade",
  ]
  let valid =
    name != ""
    && list.all(string.to_utf_codepoints(name), fn(codepoint) {
      let codepoint = string.utf_codepoint_to_int(codepoint)
      codepoint >= 33
      && codepoint <= 126
      && !list.contains(
        [34, 40, 41, 44, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 123, 125],
        codepoint,
      )
    })
    && !list.contains(forbidden, string.lowercase(name))
    && list.all(string.to_utf_codepoints(value), fn(codepoint) {
      let codepoint = string.utf_codepoint_to_int(codepoint)
      codepoint == 9 || codepoint >= 32 && codepoint != 127
    })
  case valid {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

/// Emit at most wanted bytes, or the exact number needed to advance framing.
/// NeedData(0) is an internal transition, never a request to recv(socket, 0).
pub fn next(decoder: Decoder, wanted: Int) -> Result(Step, Error) {
  case decoder.phase {
    Size | Trailers -> {
      use step <- result.try(line(decoder))
      case step {
        NeedData(decoder, 0) -> next(decoder, wanted)
        _ -> Ok(step)
      }
    }
    Data(left) ->
      case bit_array.byte_size(decoder.pending) {
        0 -> Ok(NeedData(decoder, int.min(left, wanted)))
        buffered -> {
          let take = int.min(int.min(left, wanted), buffered)
          let assert <<data:bytes-size(take), rest:bytes>> = decoder.pending
          let phase = case left - take {
            0 -> Terminator
            remaining -> Data(remaining)
          }
          Ok(Chunk(data, Decoder(..decoder, pending: rest, phase:)))
        }
      }
    Terminator ->
      case decoder.pending {
        <<13, 10, rest:bytes>> ->
          next(Decoder(..decoder, phase: Size, pending: rest), wanted)
        data ->
          case bit_array.byte_size(data) {
            size if size < 2 -> Ok(NeedData(decoder, 2 - size))
            _ -> Error(Invalid)
          }
      }
  }
}
