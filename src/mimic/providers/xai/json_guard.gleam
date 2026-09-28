/// OAuth trust-boundary guard. Parse syntax with the shared JSON parser, then
/// reject duplicate keys (including escaped-equivalent keys) at every depth.
/// A first/last-wins map must never decide a grant, endpoint or cooldown.
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import mimic/ir

pub fn parse(source: String) -> Result(ir.Value, String) {
  use _ <- result.try(case string.byte_size(source) <= 1_048_576 {
    True -> Ok(Nil)
    False -> Error("xAI OAuth JSON exceeds byte limit")
  })
  use value <- result.try(ir.parse(source))
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
        [] -> Error("invalid xAI OAuth JSON object")
      }
    <<34, rest:bytes>> -> {
      use token <- result.try(quoted(rest, [<<34>>]))
      case whitespace(token.1) {
        <<58, _:bytes>> -> {
          use text <- result.try(
            bit_array.to_string(token.0)
            |> result.map_error(fn(_) { "invalid xAI OAuth JSON key" }),
          )
          use key <- result.try(ir.parse(text))
          use key <- result.try(ir.as_string(key))
          case objects {
            [keys, ..parents] ->
              case dict.has_key(keys, key) {
                True -> Error("duplicate xAI OAuth JSON key")
                False -> scan(token.1, [dict.insert(keys, key, Nil), ..parents])
              }
            [] -> Error("invalid xAI OAuth JSON key")
          }
        }
        _ -> scan(token.1, objects)
      }
    }
    <<_, rest:bytes>> -> scan(rest, objects)
    _ -> Error("invalid xAI OAuth JSON encoding")
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
    _ -> Error("invalid xAI OAuth JSON string")
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
