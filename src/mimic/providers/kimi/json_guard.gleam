/// Reject duplicate OAuth keys before a map decoder chooses a winner.
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import mimic/ir

pub fn parse(source: String) -> Result(ir.Value, String) {
  use value <- result.try(
    case bit_array.byte_size(bit_array.from_string(source)) {
      size if size <= 1_048_576 -> ir.parse(source)
      _ -> Error("Invalid Kimi OAuth response")
    },
  )
  use _ <- result.try(scan(bit_array.from_string(source), []))
  Ok(value)
}

fn scan(
  bytes: BitArray,
  objects: List(Dict(String, Nil)),
) -> Result(Nil, String) {
  case bytes {
    <<>> -> Ok(Nil)
    <<123, rest:bytes>> -> scan(rest, [dict.new(), ..objects])
    <<125, rest:bytes>> ->
      case objects {
        [_, ..parents] -> scan(rest, parents)
        [] -> Error("Invalid Kimi OAuth response")
      }
    <<34, rest:bytes>> -> {
      use token <- result.try(quoted(rest, [<<34>>]))
      case whitespace(token.1) {
        <<58, _:bytes>> -> {
          use text <- result.try(
            bit_array.to_string(token.0)
            |> result.map_error(fn(_) { "Invalid Kimi OAuth response" }),
          )
          use key <- result.try(ir.parse(text))
          use key <- result.try(ir.as_string(key))
          case objects {
            [keys, ..parents] ->
              case dict.has_key(keys, key) {
                True -> Error("Duplicate Kimi OAuth response key")
                False -> scan(token.1, [dict.insert(keys, key, Nil), ..parents])
              }
            [] -> Error("Invalid Kimi OAuth response")
          }
        }
        _ -> scan(token.1, objects)
      }
    }
    <<_, rest:bytes>> -> scan(rest, objects)
    _ -> Error("Invalid Kimi OAuth response")
  }
}

fn quoted(
  bytes: BitArray,
  parts: List(BitArray),
) -> Result(#(BitArray, BitArray), String) {
  case bytes {
    <<34, rest:bytes>> ->
      Ok(#(bit_array.concat(list.reverse([<<34>>, ..parts])), rest))
    <<92, byte, rest:bytes>> -> quoted(rest, [<<92, byte>>, ..parts])
    <<byte, rest:bytes>> -> quoted(rest, [<<byte>>, ..parts])
    _ -> Error("Invalid Kimi OAuth response")
  }
}

fn whitespace(bytes: BitArray) -> BitArray {
  case bytes {
    <<byte, rest:bytes>>
      if byte == 32 || byte == 9 || byte == 10 || byte == 13
    -> whitespace(rest)
    _ -> bytes
  }
}
