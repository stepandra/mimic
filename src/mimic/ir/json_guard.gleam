/// Structural ambiguity/work gate before the standard JSON decoder builds maps.
/// Adapted from the existing Claude raw JSON guard; provider policy stays there.
/// Errors never include a key, literal, or source body.
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/result

const invalid = "invalid JSON"

pub fn validate(
  source: String,
  max_bytes: Int,
  max_depth: Int,
  max_values: Int,
) -> Result(Nil, String) {
  let bytes = bit_array.from_string(source)
  use _ <- result.try(
    case
      max_bytes > 0
      && max_depth > 0
      && max_values > 0
      && bit_array.byte_size(bytes) <= max_bytes
    {
      True -> Ok(Nil)
      False -> Error(invalid)
    },
  )
  use #(remaining, _) <- result.try(value(bytes, 0, max_depth, max_values))
  case whitespace(remaining) {
    <<>> -> Ok(Nil)
    _ -> Error(invalid)
  }
}

fn value(bytes: BitArray, depth: Int, max_depth: Int, budget: Int) {
  case depth > max_depth || budget <= 0 {
    True -> Error(invalid)
    False ->
      case whitespace(bytes) {
        <<123, _:bits>> | <<91, _:bits>> if depth >= max_depth -> Error(invalid)
        <<123, rest:bits>> ->
          case whitespace(rest) {
            <<125, rest:bits>> -> Ok(#(rest, budget - 1))
            rest -> members(rest, dict.new(), depth + 1, max_depth, budget - 1)
          }
        <<91, rest:bits>> ->
          case whitespace(rest) {
            <<93, rest:bits>> -> Ok(#(rest, budget - 1))
            rest -> elements(rest, depth + 1, max_depth, budget - 1)
          }
        <<34, rest:bits>> -> {
          use #(rest, _) <- result.try(quoted(rest, 1))
          Ok(#(rest, budget - 1))
        }
        bytes -> {
          use rest <- result.try(atom(bytes, 0))
          Ok(#(rest, budget - 1))
        }
      }
  }
}

fn members(
  bytes: BitArray,
  keys: Dict(String, Nil),
  depth: Int,
  max_depth: Int,
  budget: Int,
) {
  use #(key, rest) <- result.try(key(whitespace(bytes)))
  use _ <- result.try(case dict.has_key(keys, key) {
    True -> Error(invalid)
    False -> Ok(Nil)
  })
  case whitespace(rest) {
    <<58, rest:bits>> -> {
      use #(rest, budget) <- result.try(value(rest, depth, max_depth, budget))
      case whitespace(rest) {
        <<125, rest:bits>> -> Ok(#(rest, budget))
        <<44, rest:bits>> ->
          members(rest, dict.insert(keys, key, Nil), depth, max_depth, budget)
        _ -> Error(invalid)
      }
    }
    _ -> Error(invalid)
  }
}

fn elements(bytes: BitArray, depth: Int, max_depth: Int, budget: Int) {
  use #(rest, budget) <- result.try(value(bytes, depth, max_depth, budget))
  case whitespace(rest) {
    <<93, rest:bits>> -> Ok(#(rest, budget))
    <<44, rest:bits>> -> elements(rest, depth, max_depth, budget)
    _ -> Error(invalid)
  }
}

fn key(bytes: BitArray) {
  case bytes {
    <<34, rest:bits>> -> {
      use #(rest, length) <- result.try(quoted(rest, 1))
      use raw <- result.try(
        bit_array.slice(bytes, 0, length) |> result.replace_error(invalid),
      )
      use raw <- result.try(
        bit_array.to_string(raw) |> result.replace_error(invalid),
      )
      use key <- result.try(
        json.parse(raw, decode.string) |> result.replace_error(invalid),
      )
      Ok(#(key, rest))
    }
    _ -> Error(invalid)
  }
}

fn quoted(bytes: BitArray, length: Int) {
  case bytes {
    <<34, rest:bits>> -> Ok(#(rest, length + 1))
    <<92, _, rest:bits>> -> quoted(rest, length + 2)
    <<byte, rest:bits>> if byte >= 32 -> quoted(rest, length + 1)
    _ -> Error(invalid)
  }
}

fn atom(bytes: BitArray, length: Int) {
  case bytes {
    <<byte, rest:bits>>
      if byte != 32
      && byte != 9
      && byte != 10
      && byte != 13
      && byte != 44
      && byte != 93
      && byte != 125
    -> atom(rest, length + 1)
    _ if length > 0 -> Ok(bytes)
    _ -> Error(invalid)
  }
}

fn whitespace(bytes: BitArray) -> BitArray {
  case bytes {
    <<byte, rest:bits>> if byte == 32 || byte == 9 || byte == 10 || byte == 13 ->
      whitespace(rest)
    _ -> bytes
  }
}
