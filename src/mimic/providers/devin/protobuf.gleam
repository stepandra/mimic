import gleam/bit_array
import gleam/list
import gleam/result

/// Minimal protobuf wire codec. No schemas, credentials, or I/O live here.
pub type Field {
  Varint(Int, Int)
  Bytes(Int, BitArray)
  Fixed64(Int, BitArray)
  Fixed32(Int, BitArray)
}

pub fn uint(value: Int) -> BitArray {
  case value < 128 {
    True -> <<value>>
    False -> <<{ value % 128 + 128 }, { uint(value / 128) }:bits>>
  }
}

pub fn encode(fields: List(Field)) -> BitArray {
  fields
  |> list.map(fn(field) {
    case field {
      Varint(tag, value) -> <<{ uint(tag * 8) }:bits, { uint(value) }:bits>>
      Bytes(tag, value) -> <<
        { uint(tag * 8 + 2) }:bits,
        { uint(bit_array.byte_size(value)) }:bits,
        value:bits,
      >>
      Fixed64(tag, value) -> <<{ uint(tag * 8 + 1) }:bits, value:bits>>
      Fixed32(tag, value) -> <<{ uint(tag * 8 + 5) }:bits, value:bits>>
    }
  })
  |> bit_array.concat
}

pub fn text(tag: Int, value: String) -> Field {
  Bytes(tag, bit_array.from_string(value))
}

pub fn message(tag: Int, fields: List(Field)) -> Field {
  Bytes(tag, encode(fields))
}

pub fn decode(bytes: BitArray) -> Result(List(Field), String) {
  decode_fields(bytes, [], 0)
}

fn decode_fields(
  bytes: BitArray,
  fields: List(Field),
  count: Int,
) -> Result(List(Field), String) {
  case bytes {
    <<>> -> Ok(list.reverse(fields))
    _ if count >= 65_536 -> Error("devin protobuf field limit")
    _ -> {
      use #(key, rest) <- result.try(read_uint(bytes, 0, 1, 0))
      let tag = key / 8
      use _ <- result.try(case tag > 0 && tag <= 536_870_911 {
        True -> Ok(Nil)
        False -> Error("invalid devin protobuf tag")
      })
      use #(field, rest) <- result.try(case key % 8, rest {
        0, _ -> {
          use #(value, rest) <- result.try(read_uint(rest, 0, 1, 0))
          Ok(#(Varint(tag, value), rest))
        }
        1, <<value:bytes-size(8), rest:bits>> ->
          Ok(#(Fixed64(tag, value), rest))
        5, <<value:bytes-size(4), rest:bits>> ->
          Ok(#(Fixed32(tag, value), rest))
        2, _ -> {
          use #(size, rest) <- result.try(read_uint(rest, 0, 1, 0))
          case rest {
            <<value:bytes-size(size), rest:bits>> ->
              Ok(#(Bytes(tag, value), rest))
            _ -> Error("truncated devin protobuf bytes")
          }
        }
        _, _ -> Error("unsupported or truncated devin protobuf field")
      })
      decode_fields(rest, [field, ..fields], count + 1)
    }
  }
}

fn read_uint(
  bytes: BitArray,
  value: Int,
  factor: Int,
  count: Int,
) -> Result(#(Int, BitArray), String) {
  case bytes {
    <<byte, rest:bits>> if count < 9 || { count == 9 && byte <= 1 } -> {
      let value = value + byte % 128 * factor
      case byte < 128 {
        True -> Ok(#(value, rest))
        False -> read_uint(rest, value, factor * 128, count + 1)
      }
    }
    _ -> Error("invalid devin protobuf varint")
  }
}
