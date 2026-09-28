/// Raw OAuth JSON ambiguity gate. Run before decoding objects into dictionaries,
/// where repeated keys would be lost. No error includes source text or keys.
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/result
import mimic/ir

pub const max_bytes = 65_536

pub const max_depth = 32

pub const max_values = 4096

const invalid = "Invalid or ambiguous Claude OAuth JSON"

pub fn parse(source: String) -> Result(ir.Value, String) {
  parse_bounded(source, max_bytes, max_values)
}

/// Native inference JSON has a larger explicit byte/value budget than OAuth.
/// Keep grant parsing's original 64 KiB/4096-value limits unchanged.
pub fn parse_native(
  source: String,
  byte_limit: Int,
) -> Result(ir.Value, String) {
  parse_bounded(source, byte_limit, 65_536)
}

fn parse_bounded(
  source: String,
  byte_limit: Int,
  values: Int,
) -> Result(ir.Value, String) {
  let bytes = bit_array.from_string(source)
  use _ <- result.try(case bit_array.byte_size(bytes) <= byte_limit {
    True -> Ok(Nil)
    False -> Error(invalid)
  })
  use #(remaining, _) <- result.try(value(bytes, 0, values))
  case whitespace(remaining) {
    <<>> -> ir.parse(source) |> result.replace_error(invalid)
    _ -> Error(invalid)
  }
}

// The scan bounds recursion/work and detects duplicate decoded keys. The
// standard JSON parser remains authoritative for literal/number/string syntax.
fn value(bytes: BitArray, depth: Int, budget: Int) {
  case depth > max_depth || budget <= 0 {
    True -> Error(invalid)
    False ->
      case whitespace(bytes) {
        <<123, _:bits>> | <<91, _:bits>> if depth >= max_depth -> Error(invalid)
        <<123, rest:bits>> ->
          case whitespace(rest) {
            <<125, rest:bits>> -> Ok(#(rest, budget - 1))
            rest -> members(rest, dict.new(), depth + 1, budget - 1)
          }
        <<91, rest:bits>> ->
          case whitespace(rest) {
            <<93, rest:bits>> -> Ok(#(rest, budget - 1))
            rest -> elements(rest, depth + 1, budget - 1)
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

fn members(bytes: BitArray, keys: Dict(String, Nil), depth: Int, budget: Int) {
  use #(key, rest) <- result.try(key(whitespace(bytes)))
  use _ <- result.try(case dict.has_key(keys, key) {
    True -> Error(invalid)
    False -> Ok(Nil)
  })
  case whitespace(rest) {
    <<58, rest:bits>> -> {
      use #(rest, budget) <- result.try(value(rest, depth, budget))
      case whitespace(rest) {
        <<125, rest:bits>> -> Ok(#(rest, budget))
        <<44, rest:bits>> ->
          members(rest, dict.insert(keys, key, Nil), depth, budget)
        _ -> Error(invalid)
      }
    }
    _ -> Error(invalid)
  }
}

fn elements(bytes: BitArray, depth: Int, budget: Int) {
  use #(rest, budget) <- result.try(value(bytes, depth, budget))
  case whitespace(rest) {
    <<93, rest:bits>> -> Ok(#(rest, budget))
    <<44, rest:bits>> -> elements(rest, depth, budget)
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
      // This decodes escaped, UTF-8 and surrogate-pair spellings identically.
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
