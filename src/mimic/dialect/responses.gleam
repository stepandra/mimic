import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir

/// Native Responses documents remain the source of truth. Unknown fields,
/// encrypted reasoning and provider extensions are never projected through Chat.
pub type Request {
  Request(
    document: ir.Value,
    model: String,
    stream: Bool,
    previous_response_id: Option(String),
  )
}

pub type Status {
  Queued
  InProgress
  Completed
  Incomplete
  Failed
  Cancelled
}

pub type Response {
  Response(
    document: ir.Value,
    id: String,
    status: Status,
    output: List(ir.Value),
    usage: Option(ir.Usage),
  )
}

pub type ToolKind {
  Function
  Custom
}

pub type PendingCall {
  PendingCall(id: String, kind: ToolKind)
}

pub type CompactResponse {
  CompactResponse(
    document: ir.Value,
    id: String,
    output: List(ir.Value),
    usage: Option(ir.Usage),
  )
}

pub type Capabilities {
  Capabilities(
    native_documents: Bool,
    native_sse: Bool,
    compact_documents: Bool,
    websocket_messages: Bool,
    cross_dialect: Bool,
    physical_websocket: Bool,
  )
}

pub fn capabilities() -> Capabilities {
  Capabilities(True, True, True, True, False, False)
}

pub fn decode_request(source: String) -> Result(Request, String) {
  use value <- result.try(ir.parse(source))
  request_from_value(value)
}

pub fn request_from_value(value: ir.Value) -> Result(Request, String) {
  use _ <- result.try(ir.as_object(value))
  use model <- result.try(nonempty_string(value, "model"))
  use stream <- result.try(ir.optional_bool(value, "stream", False))
  use previous <- result.try(ir.optional_string(value, "previous_response_id"))
  use _ <- result.try(case previous {
    Some("") -> Error("previous_response_id must not be empty")
    _ -> Ok(Nil)
  })
  use _ <- result.try(case ir.field(value, "input") {
    None | Some(ir.String(_)) -> Ok(Nil)
    Some(ir.Array(items)) -> validate_items(items)
    _ -> Error("Responses input must be a string or array")
  })
  use _ <- result.try(case ir.field(value, "tools") {
    None -> Ok(Nil)
    Some(ir.Array(tools)) -> list.try_each(tools, validate_tool)
    _ -> Error("Responses tools must be an array")
  })
  use _ <- result.try(ir.optional_string(value, "instructions"))
  use _ <- result.try(optional_object(value, "reasoning"))
  use _ <- result.try(optional_object(value, "text"))
  use _ <- result.try(case ir.field(value, "max_output_tokens") {
    None -> Ok(0)
    _ -> nonnegative_int(value, "max_output_tokens")
  })
  Ok(Request(value, model, stream, previous))
}

pub fn encode_request(request: Request) -> String {
  ir.stringify(request.document)
}

pub fn decode_compact_request(source: String) -> Result(Request, String) {
  use request <- result.try(decode_request(source))
  case request.stream {
    True -> Error("Responses compact does not support streaming")
    False -> Ok(request)
  }
}

pub fn response_from_value(value: ir.Value) -> Result(Response, String) {
  use _ <- result.try(ir.as_object(value))
  use _ <- result.try(expect_string(value, "object", "response"))
  use id <- result.try(nonempty_string(value, "id"))
  use raw_status <- result.try(ir.string_field(value, "status"))
  use status <- result.try(case raw_status {
    "queued" -> Ok(Queued)
    "in_progress" -> Ok(InProgress)
    "completed" -> Ok(Completed)
    "incomplete" -> Ok(Incomplete)
    "failed" -> Ok(Failed)
    "cancelled" -> Ok(Cancelled)
    _ -> Error("unsupported Responses status: " <> raw_status)
  })
  use output <- result.try(ir.required(value, "output"))
  use output <- result.try(ir.as_array(output))
  use _ <- result.try(list.try_each(output, validate_output_item))
  use _ <- result.try(unique_output_ids(output, []))
  use _ <- result.try(pair_items(output, [], []))
  use usage <- result.try(usage_from_value(value))
  Ok(Response(value, id, status, output, usage))
}

pub fn decode_response(source: String) -> Result(Response, String) {
  use value <- result.try(ir.parse(source))
  response_from_value(value)
}

pub fn encode_response(response: Response) -> String {
  ir.stringify(response.document)
}

pub fn decode_compact_response(
  source: String,
) -> Result(CompactResponse, String) {
  use value <- result.try(ir.parse(source))
  use _ <- result.try(expect_string(value, "object", "response.compaction"))
  use id <- result.try(nonempty_string(value, "id"))
  // CPA's pinned compact executor test includes an envelope without output.
  // Absence is retained in document; the accessor does not invent wire fields.
  use output <- result.try(case ir.field(value, "output") {
    None -> Ok([])
    Some(output) -> ir.as_array(output)
  })
  use _ <- result.try(validate_items(output))
  use usage <- result.try(usage_from_value(value))
  Ok(CompactResponse(value, id, output, usage))
}

pub fn encode_compact_response(response: CompactResponse) -> String {
  ir.stringify(response.document)
}

/// Validate pairing against caller-supplied, trusted prior calls. Native request
/// parsing alone cannot know what previous_response_id refers to. The caller
/// must scope that history by tenant/account/model/session/connection.
pub fn pair_input(
  request: Request,
  prior: List(PendingCall),
) -> Result(List(PendingCall), String) {
  use _ <- result.try(request_from_value(request.document))
  use _ <- result.try(validate_prior(prior, []))
  case ir.field(request.document, "input") {
    Some(ir.Array(items)) ->
      pair_items(items, prior, list.map(prior, fn(c) { c.id }))
    _ -> Ok(prior)
  }
}

pub fn output_calls(response: Response) -> Result(List(PendingCall), String) {
  use _ <- result.try(list.try_each(response.output, validate_output_item))
  pair_items(response.output, [], [])
}

fn validate_prior(
  prior: List(PendingCall),
  seen: List(String),
) -> Result(Nil, String) {
  case prior {
    [] -> Ok(Nil)
    [call, ..rest] ->
      case call.id == "" || list.contains(seen, call.id) {
        True -> Error("invalid or duplicate trusted prior call id")
        False -> validate_prior(rest, [call.id, ..seen])
      }
  }
}

fn pair_items(
  items: List(ir.Value),
  pending: List(PendingCall),
  seen: List(String),
) -> Result(List(PendingCall), String) {
  case items {
    [] -> Ok(pending)
    [item, ..rest] -> {
      case ir.field(item, "type") {
        Some(ir.String("function_call"))
        | Some(ir.String("custom_tool_call")) -> {
          use id <- result.try(nonempty_string(item, "call_id"))
          use _ <- result.try(case list.contains(seen, id) {
            True -> Error("duplicate Responses call_id")
            False -> Ok(Nil)
          })
          let kind = case ir.field(item, "type") {
            Some(ir.String("function_call")) -> Function
            _ -> Custom
          }
          pair_items(rest, list.append(pending, [PendingCall(id, kind)]), [
            id,
            ..seen
          ])
        }
        Some(ir.String("function_call_output"))
        | Some(ir.String("custom_tool_call_output")) -> {
          use id <- result.try(nonempty_string(item, "call_id"))
          let kind = case ir.field(item, "type") {
            Some(ir.String("function_call_output")) -> Function
            _ -> Custom
          }
          use _ <- result.try(
            case list.contains(pending, PendingCall(id, kind)) {
              True -> Ok(Nil)
              False -> Error("orphaned or wrong-kind Responses tool result")
            },
          )
          pair_items(rest, list.filter(pending, fn(c) { c.id != id }), seen)
        }
        _ -> pair_items(rest, pending, seen)
      }
    }
  }
}

pub fn validate_items(items: List(ir.Value)) -> Result(Nil, String) {
  list.try_each(items, validate_item)
}

pub fn validate_item(item: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(ir.as_object(item))
  case ir.field(item, "type") {
    None -> validate_message(item)
    Some(ir.String("message")) -> validate_message(item)
    Some(ir.String("function_call")) -> {
      use _ <- result.try(nonempty_string(item, "call_id"))
      use _ <- result.try(nonempty_string(item, "name"))
      use _ <- result.try(ir.string_field(item, "arguments"))
      Ok(Nil)
    }
    Some(ir.String("custom_tool_call")) -> {
      use _ <- result.try(nonempty_string(item, "call_id"))
      use _ <- result.try(nonempty_string(item, "name"))
      use _ <- result.try(ir.string_field(item, "input"))
      Ok(Nil)
    }
    Some(ir.String("function_call_output"))
    | Some(ir.String("custom_tool_call_output")) -> {
      use _ <- result.try(nonempty_string(item, "call_id"))
      case ir.field(item, "output") {
        Some(ir.String(_)) -> Ok(Nil)
        Some(ir.Array(parts)) -> list.try_each(parts, validate_content)
        _ -> Error("Responses tool output must be a string or content array")
      }
    }
    Some(ir.String("reasoning")) -> {
      use _ <- result.try(ir.optional_string(item, "encrypted_content"))
      case ir.field(item, "summary") {
        None -> Ok(Nil)
        Some(ir.Array(parts)) -> list.try_each(parts, validate_content)
        _ -> Error("reasoning summary must be an array")
      }
    }
    Some(ir.String("compaction")) -> {
      use _ <- result.try(nonempty_string(item, "encrypted_content"))
      Ok(Nil)
    }
    Some(ir.String(kind)) if kind != "" -> Ok(Nil)
    _ -> Error("Responses item type must be a nonempty string")
  }
}

fn validate_message(item: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(nonempty_string(item, "role"))
  case ir.field(item, "content") {
    Some(ir.String(_)) -> Ok(Nil)
    Some(ir.Array(parts)) -> list.try_each(parts, validate_content)
    _ -> Error("Responses message content must be a string or array")
  }
}

/// Output is not an input transcript. In particular results cannot erase the
/// pending calls extracted from a server terminal response.
pub fn validate_output_item(item: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(validate_item(item))
  use kind <- result.try(nonempty_string(item, "type"))
  case kind {
    "function_call_output" | "custom_tool_call_output" | "item_reference" ->
      Error("input-only item in Responses output")
    "message" -> {
      use _ <- result.try(expect_string(item, "role", "assistant"))
      use content <- result.try(ir.required(item, "content"))
      use _ <- result.try(ir.as_array(content))
      Ok(Nil)
    }
    _ -> Ok(Nil)
  }
}

pub fn validate_content(part: ir.Value) -> Result(Nil, String) {
  use kind <- result.try(nonempty_string(part, "type"))
  case kind {
    "input_text" | "output_text" | "summary_text" | "reasoning_text" -> {
      use _ <- result.try(ir.string_field(part, "text"))
      case ir.field(part, "annotations") {
        None | Some(ir.Array(_)) -> Ok(Nil)
        _ -> Error("Responses text annotations must be an array")
      }
    }
    "refusal" -> {
      use _ <- result.try(ir.string_field(part, "refusal"))
      Ok(Nil)
    }
    "input_image" -> one_string_source(part, ["image_url", "file_id"])
    "input_file" ->
      one_string_source(part, ["file_data", "file_url", "file_id"])
    "input_audio" -> {
      use audio <- result.try(ir.required(part, "input_audio"))
      use _ <- result.try(nonempty_string(audio, "data"))
      use _ <- result.try(nonempty_string(audio, "format"))
      Ok(Nil)
    }
    _ -> Ok(Nil)
  }
}

fn one_string_source(
  value: ir.Value,
  keys: List(String),
) -> Result(Nil, String) {
  use sources <- result.try(
    list.try_map(keys, fn(key) { ir.optional_string(value, key) }),
  )
  case list.any(sources, fn(source) { source != None && source != Some("") }) {
    True -> Ok(Nil)
    False -> Error("Responses content lacks a nonempty source")
  }
}

fn validate_tool(tool: ir.Value) -> Result(Nil, String) {
  use kind <- result.try(nonempty_string(tool, "type"))
  case kind {
    "function" -> {
      use _ <- result.try(nonempty_string(tool, "name"))
      use _ <- result.try(optional_object(tool, "parameters"))
      case ir.field(tool, "strict") {
        None | Some(ir.Null) | Some(ir.Boolean(_)) -> Ok(Nil)
        _ -> Error("Responses function strict must be boolean or null")
      }
    }
    "custom" -> {
      use _ <- result.try(nonempty_string(tool, "name"))
      optional_object(tool, "format")
    }
    "namespace" -> {
      use _ <- result.try(nonempty_string(tool, "name"))
      use children <- result.try(ir.required(tool, "tools"))
      use children <- result.try(ir.as_array(children))
      list.try_each(children, validate_tool)
    }
    _ -> Ok(Nil)
  }
}

fn optional_object(value: ir.Value, field: String) -> Result(Nil, String) {
  case ir.field(value, field) {
    None | Some(ir.Null) | Some(ir.Object(_)) -> Ok(Nil)
    _ -> Error("Responses " <> field <> " must be an object or null")
  }
}

fn unique_output_ids(
  items: List(ir.Value),
  seen: List(String),
) -> Result(Nil, String) {
  case items {
    [] -> Ok(Nil)
    [item, ..rest] -> {
      use id <- result.try(nonempty_string(item, "id"))
      case list.contains(seen, id) {
        True -> Error("duplicate Responses output item id")
        False -> unique_output_ids(rest, [id, ..seen])
      }
    }
  }
}

fn usage_from_value(value: ir.Value) -> Result(Option(ir.Usage), String) {
  case ir.field(value, "usage") {
    None | Some(ir.Null) -> Ok(None)
    Some(usage) -> {
      use _ <- result.try(ir.as_object(usage))
      use input <- result.try(nonnegative_int(usage, "input_tokens"))
      use output <- result.try(nonnegative_int(usage, "output_tokens"))
      use _ <- result.try(case ir.field(usage, "total_tokens") {
        None -> Ok(0)
        _ -> nonnegative_int(usage, "total_tokens")
      })
      Ok(
        Some(ir.Usage(
          input,
          output,
          ir.extras(usage, ["input_tokens", "output_tokens"]),
        )),
      )
    }
  }
}

pub fn nonempty_string(value: ir.Value, key: String) -> Result(String, String) {
  use text <- result.try(ir.string_field(value, key))
  case text {
    "" -> Error("empty Responses field: " <> key)
    _ -> Ok(text)
  }
}

pub fn nonnegative_int(value: ir.Value, key: String) -> Result(Int, String) {
  use value <- result.try(ir.required(value, key))
  use number <- result.try(ir.as_int(value))
  case number >= 0 {
    True -> Ok(number)
    False -> Error("negative Responses field: " <> key)
  }
}

pub fn expect_string(
  value: ir.Value,
  key: String,
  expected: String,
) -> Result(Nil, String) {
  use actual <- result.try(ir.string_field(value, key))
  case actual == expected {
    True -> Ok(Nil)
    False -> Error("unexpected Responses " <> key <> ": " <> actual)
  }
}

/// Until an explicit lossless subset is negotiated, refuse conversion rather
/// than mislabel a Chat/Anthropic request as a native Responses request.
pub fn from_ir(_request: ir.Request) -> Result(Request, String) {
  Error("cross-dialect Responses conversion is unsupported")
}

pub fn to_ir(_request: Request) -> Result(ir.Request, String) {
  Error("cross-dialect Responses conversion is unsupported")
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["validate-request", source] ->
      decode_request(source) |> result.map(encode_request)
    ["validate-response", source] ->
      decode_response(source) |> result.map(encode_response)
    _ -> Error("responses validate-request|validate-response <json>")
  }
}
