import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir/json_guard

/// A lossless JSON tree. Unknown vendor extensions remain data, never discarded.
pub type Value {
  Null
  Boolean(Bool)
  Integer(Int)
  Decimal(Float)
  String(String)
  Array(List(Value))
  Object(List(#(String, Value)))
}

pub type Origin {
  Anthropic
  Openai
  Constructed
}

pub type Content {
  Text(text: String, extensions: List(#(String, Value)))
  ToolCall(
    id: String,
    name: String,
    input: Value,
    /// Preserve whitespace/formatting inside OpenAI's JSON-encoded arguments
    /// string on native roundtrips; ignored if `input` is changed.
    raw_arguments: Option(String),
    extensions: List(#(String, Value)),
  )
  ToolResult(id: String, content: Value, extensions: List(#(String, Value)))
  Thinking(
    text: String,
    signature: Option(String),
    extensions: List(#(String, Value)),
  )
  /// An unrecognised block is retained for native roundtrips, but cannot be
  /// projected into another dialect without an explicit codec.
  Unknown(Value)
}

pub type Turn {
  Turn(
    role: String,
    content: List(Content),
    /// Anthropic and OpenAI both permit string content; retain its original shape.
    content_is_string: Bool,
    extensions: List(#(String, Value)),
  )
}

pub type Request {
  Request(
    model: String,
    system: Option(Value),
    system_role: String,
    turns: List(Turn),
    max_tokens: Option(Int),
    /// Original token-limit spelling (Anthropic: max_tokens; OpenAI also
    /// accepts max_completion_tokens). Encoders use their own spelling across
    /// dialects, but preserve this one in native roundtrips.
    token_limit_field: String,
    stream: Option(Bool),
    extensions: List(#(String, Value)),
    origin: Origin,
  )
}

pub type Usage {
  Usage(
    input_tokens: Int,
    output_tokens: Int,
    extensions: List(#(String, Value)),
  )
}

pub type Response {
  Response(
    id: String,
    model: String,
    content: List(Content),
    content_is_string: Bool,
    stop_reason: Option(String),
    usage: Option(Usage),
    message_extensions: List(#(String, Value)),
    choice_extensions: List(#(String, Value)),
    extensions: List(#(String, Value)),
    origin: Origin,
  )
}

pub type StreamEvent {
  MessageStart(Response)
  ContentStart(index: Int, content: Content)
  TextDelta(index: Int, text: String)
  ToolInputDelta(index: Int, partial_json: String)
  ContentStop(index: Int)
  MessageDelta(stop_reason: Option(String), usage: Option(Usage))
  MessageStop
  StreamError(Value)
}

/// Reject ambiguous decoded object keys before a dictionary chooses a winner.
/// Native structural fidelity does not preserve formatting or numeric spelling.
pub fn parse(source: String) -> Result(Value, String) {
  parse_bounded(source, 16_777_216, 128, 1_048_576)
}

/// Smaller boundary budgets can be selected without introducing another codec.
/// Limits count UTF-8 bytes, nested containers and JSON values respectively.
pub fn parse_bounded(
  source: String,
  max_bytes: Int,
  max_depth: Int,
  max_values: Int,
) -> Result(Value, String) {
  use _ <- result.try(json_guard.validate(
    source,
    max_bytes,
    max_depth,
    max_values,
  ))
  case json.parse(source, decode.dynamic) {
    Ok(value) -> from_dynamic(value)
    Error(_) -> Error("invalid JSON")
  }
}

fn from_dynamic(value: Dynamic) -> Result(Value, String) {
  case dynamic.classify(value) {
    "Nil" -> Ok(Null)
    "Bool" ->
      decode.run(value, decode.bool) |> result.map(Boolean) |> decode_error
    "Int" ->
      decode.run(value, decode.int) |> result.map(Integer) |> decode_error
    "Float" ->
      decode.run(value, decode.float) |> result.map(Decimal) |> decode_error
    "String" ->
      decode.run(value, decode.string) |> result.map(String) |> decode_error
    "List" -> {
      case decode.run(value, decode.list(of: decode.dynamic)) {
        Ok(items) -> list.try_map(items, from_dynamic) |> result.map(Array)
        Error(_) -> Error("invalid JSON array")
      }
    }
    "Dict" -> {
      case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
        Ok(entries) ->
          dict.to_list(entries)
          |> list.try_map(fn(entry) {
            let #(key, item) = entry
            from_dynamic(item) |> result.map(fn(decoded) { #(key, decoded) })
          })
          |> result.map(Object)
        Error(_) -> Error("invalid JSON object")
      }
    }
    _ -> Error("unsupported JSON value")
  }
}

fn decode_error(
  value: Result(a, List(decode.DecodeError)),
) -> Result(a, String) {
  result.map_error(value, fn(_) { "invalid JSON value" })
}

pub fn stringify(value: Value) -> String {
  to_json(value) |> json.to_string
}

pub fn to_json(value: Value) -> json.Json {
  case value {
    Null -> json.null()
    Boolean(value) -> json.bool(value)
    Integer(value) -> json.int(value)
    Decimal(value) -> json.float(value)
    String(value) -> json.string(value)
    Array(values) -> json.array(values, to_json)
    Object(fields) ->
      json.object(
        list.map(fields, fn(field) {
          let #(key, value) = field
          #(key, to_json(value))
        }),
      )
  }
}

pub fn field(value: Value, key: String) -> Option(Value) {
  case value {
    Object(fields) ->
      case list.find(fields, fn(entry) { entry.0 == key }) {
        Ok(entry) -> Some(entry.1)
        Error(_) -> None
      }
    _ -> None
  }
}

pub fn required(value: Value, key: String) -> Result(Value, String) {
  case field(value, key) {
    Some(value) -> Ok(value)
    None -> Error("missing required field: " <> key)
  }
}

pub fn as_object(value: Value) -> Result(List(#(String, Value)), String) {
  case value {
    Object(fields) -> Ok(fields)
    _ -> Error("expected JSON object")
  }
}

pub fn as_array(value: Value) -> Result(List(Value), String) {
  case value {
    Array(items) -> Ok(items)
    _ -> Error("expected JSON array")
  }
}

pub fn as_string(value: Value) -> Result(String, String) {
  case value {
    String(text) -> Ok(text)
    _ -> Error("expected JSON string")
  }
}

pub fn as_int(value: Value) -> Result(Int, String) {
  case value {
    Integer(number) -> Ok(number)
    _ -> Error("expected JSON integer")
  }
}

pub fn as_bool(value: Value) -> Result(Bool, String) {
  case value {
    Boolean(boolean) -> Ok(boolean)
    _ -> Error("expected JSON boolean")
  }
}

pub fn string_field(value: Value, key: String) -> Result(String, String) {
  use item <- result.try(required(value, key))
  as_string(item)
}

pub fn optional_string(
  value: Value,
  key: String,
) -> Result(Option(String), String) {
  case field(value, key) {
    None | Some(Null) -> Ok(None)
    Some(item) -> as_string(item) |> result.map(Some)
  }
}

pub fn optional_int(value: Value, key: String) -> Result(Option(Int), String) {
  case field(value, key) {
    None | Some(Null) -> Ok(None)
    Some(item) -> as_int(item) |> result.map(Some)
  }
}

pub fn optional_bool(
  value: Value,
  key: String,
  default: Bool,
) -> Result(Bool, String) {
  case field(value, key) {
    None -> Ok(default)
    Some(item) -> as_bool(item)
  }
}

pub fn extras(value: Value, known: List(String)) -> List(#(String, Value)) {
  case value {
    Object(fields) ->
      list.filter(fields, fn(field) { !list.contains(known, field.0) })
    _ -> []
  }
}

pub fn with_optional(
  fields: List(#(String, Value)),
  key: String,
  value: Option(Value),
) -> List(#(String, Value)) {
  case value {
    Some(value) -> list.append(fields, [#(key, value)])
    None -> fields
  }
}

pub fn option_string(value: Option(String)) -> Option(Value) {
  case value {
    Some(value) -> Some(String(value))
    None -> None
  }
}

pub fn option_int(value: Option(Int)) -> Option(Value) {
  case value {
    Some(value) -> Some(Integer(value))
    None -> None
  }
}
