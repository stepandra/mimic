import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir
import mimic/providers/xai/endpoint
import mimic/providers/xai/http_continuation
import mimic/providers/xai/models
import mimic/providers/xai/tools

pub type Prepared {
  Prepared(body: ir.Value, tool_refs: List(tools.Ref))
}

/// Input must first be validated/converted by the shared Responses protocol.
/// This module is a provider transform, not a protocol codec.
pub fn prepare(
  config: endpoint.Config,
  operation: endpoint.Operation,
  document: ir.Value,
  conversation: String,
) -> Result(Prepared, String) {
  use _ <- result.try(ir.as_object(document))
  use _ <- result.try(case operation {
    endpoint.Chat | endpoint.Responses | endpoint.Compact ->
      http_continuation.validate(document)
    endpoint.WebSocket -> Ok(Nil)
  })
  use model <- result.try(ir.string_field(document, "model"))
  let effort = case ir.field(document, "reasoning") {
    Some(reasoning) -> ir.optional_string(reasoning, "effort")
    None -> Ok(None)
  }
  use effort <- result.try(effort)
  use _ <- result.try(models.validate(model, config, effort, conversation))
  use declarations <- result.try(case ir.field(document, "tools") {
    None -> Ok([])
    Some(value) -> ir.as_array(value)
  })
  use prepared_tools <- result.try(tools.prepare(declarations))
  let #(declarations, refs) = prepared_tools
  use input <- result.try(prepare_input(document, refs, operation))
  let body =
    document
    |> tools.remove([
      "prompt_cache_retention",
      "safety_identifier",
      "stream_options",
      "stop",
    ])
    |> tools.set("input", input)
  let body = case declarations {
    [] -> body
    _ -> tools.set(body, "tools", ir.Array(declarations))
  }
  use body <- result.try(prepare_choice(body, refs))
  let body = case conversation {
    "" -> body
    _ -> tools.set(body, "prompt_cache_key", ir.String(conversation))
  }
  let body = case operation {
    endpoint.Chat | endpoint.Responses ->
      tools.set(body, "stream", ir.Boolean(True))
    endpoint.Compact ->
      body
      |> tools.remove([
        "stream",
        "tools",
        "tool_choice",
        "max_output_tokens",
        "temperature",
        "top_p",
        "top_k",
      ])
    endpoint.WebSocket -> {
      let body =
        body
        |> tools.remove(["stream", "background"])
        |> tools.set("type", ir.String("response.create"))
        |> tools.set("store", ir.Boolean(True))
      case ir.field(body, "previous_response_id") {
        Some(ir.String(id)) if id != "" -> tools.remove(body, ["instructions"])
        _ -> body
      }
    }
  }
  Ok(Prepared(body, refs))
}

fn prepare_input(document, refs, operation) {
  use input <- result.try(ir.required(document, "input"))
  case input {
    ir.String(_) -> Ok(input)
    ir.Array(items) -> {
      use items <- result.try(
        list.try_map(items, fn(item) {
          case ir.string_field(item, "type") {
            Ok("function_call") -> tools.wire_call(item, refs)
            Ok("compaction_trigger") if operation != endpoint.Compact ->
              Error(
                "xAI compaction trigger requires explicit compact operation",
              )
            Ok("custom_tool_call") | Ok("additional_tools") ->
              Error("Unsupported xAI custom or dynamic tools")
            Ok("message") -> validate_message(item)
            Error(_) -> {
              case ir.field(item, "role") {
                Some(_) -> validate_message(item)
                None -> Error("Unsupported xAI input item")
              }
            }
            Ok("reasoning")
            | Ok("function_call_output")
            | Ok("compaction")
            | Ok("compaction_trigger") -> Ok(item)
            _ -> Error("Unsupported xAI input item")
          }
        }),
      )
      Ok(
        ir.Array(
          list.filter(items, fn(item) {
            ir.string_field(item, "type") != Ok("compaction_trigger")
          }),
        ),
      )
    }
    _ -> Error("Invalid xAI Responses input")
  }
}

fn validate_message(item) {
  case ir.field(item, "content") {
    Some(ir.String(_)) -> Ok(item)
    Some(ir.Array(parts)) ->
      case
        list.all(parts, fn(part) {
          let kind = ir.string_field(part, "type")
          kind == Ok("input_text") || kind == Ok("output_text")
        })
      {
        True -> Ok(item)
        False -> Error("xAI media input is not enabled in this adapter")
      }
    _ -> Error("Invalid xAI message content")
  }
}

fn prepare_choice(body, refs) {
  case ir.field(body, "tool_choice") {
    Some(ir.Object(_) as choice) -> {
      case ir.string_field(choice, "type") {
        Ok("function") -> {
          use choice <- result.try(tools.wire_call(choice, refs))
          Ok(tools.set(body, "tool_choice", choice))
        }
        Ok("web_search") | Ok("x_search") -> {
          let declared = case ir.field(body, "tools") {
            Some(ir.Array(declarations)) ->
              list.any(declarations, fn(tool) {
                ir.field(tool, "type") == ir.field(choice, "type")
              })
            _ -> False
          }
          case declared {
            True -> Ok(body)
            False -> Error("xAI choice references an undeclared server tool")
          }
        }
        _ -> Error("Unsupported xAI structured tool choice")
      }
    }
    _ -> Ok(body)
  }
}

/// Shared stream decoder owns framing, lifecycle, usage and cancellation.
/// Only provider-specific names are changed; usage and unknown fields survive.
pub fn restore_event(event: ir.Value, refs: List(tools.Ref)) -> ir.Value {
  // These events may carry the function name at top level rather than inside
  // an item. Restore only the exact identity-bearing event kinds, after shared
  // raw validation; never traverse argument strings or arbitrary name fields.
  let event = case ir.string_field(event, "type") {
    Ok("response.function_call_arguments.delta")
    | Ok("response.function_call_arguments.done") ->
      tools.restore_call(event, refs)
    _ -> event
  }
  let event = case ir.field(event, "item") {
    Some(item) -> tools.set(event, "item", restore_item(item, refs))
    None -> event
  }
  case ir.field(event, "response") {
    Some(response) ->
      tools.set(event, "response", restore_response(response, refs))
    None -> restore_response(event, refs)
  }
}

fn restore_response(response, refs) {
  case ir.field(response, "output") {
    Some(ir.Array(items)) ->
      tools.set(
        response,
        "output",
        ir.Array(list.map(items, restore_item(_, refs))),
      )
    _ -> response
  }
}

fn restore_item(item, refs) {
  case ir.string_field(item, "type") {
    Ok("function_call") -> tools.restore_call(item, refs)
    _ -> item
  }
}
