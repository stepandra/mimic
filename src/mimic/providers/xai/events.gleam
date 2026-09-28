import gleam/list
import gleam/option.{None, Some}
import gleam/string
import mimic/ir
import mimic/providers/xai/request
import mimic/providers/xai/tools
import mimic/types.{type Header}

/// The shared SSE writer emits a comment for this decision, and runtime marks
/// those bytes as downstream output. Never count a keepalive as a terminal.
pub fn keepalive_as_comment(headers: List(Header), event: ir.Value) -> Bool {
  ir.string_field(event, "type") == Ok("keepalive")
  && list.any(headers, fn(header) {
    let ua = string.lowercase(header.value)
    string.lowercase(header.name) == "user-agent"
    && {
      string.contains(ua, "grok-shell/") || string.contains(ua, "grok-pager/")
    }
  })
}

/// Provider semantic normalization only. The shared codec owns SSE/WS framing,
/// sequence numbers, partial input buffering, terminal validation and usage.
pub fn normalize(event: ir.Value, refs: List(tools.Ref)) -> List(ir.Value) {
  let event = request.restore_event(event, refs)
  let normalized = normalize_outputs(event)
  case ir.string_field(normalized, "type") {
    Ok("response.reasoning_text.delta") -> [
      normalized
      |> event_type("response.reasoning_summary_text.delta")
      |> summary_index,
    ]
    Ok("response.reasoning_text.done") -> {
      let text = case ir.field(normalized, "text") {
        Some(text) -> text
        None -> ir.String("")
      }
      let part =
        ir.Object([#("type", ir.String("summary_text")), #("text", text)])
      [
        normalized
          |> event_type("response.reasoning_summary_text.done")
          |> summary_index,
        normalized
          |> event_type("response.reasoning_summary_part.done")
          |> tools.remove(["text"])
          |> tools.set("part", part)
          |> summary_index,
      ]
    }
    Ok("response.content_part.added") -> [normalize_part(normalized, "added")]
    Ok("response.content_part.done") -> [normalize_part(normalized, "done")]
    _ -> [normalized]
  }
}

fn event_type(event, name) {
  tools.set(event, "type", ir.String(name))
}

fn summary_index(event) {
  let event = case
    ir.field(event, "summary_index"),
    ir.field(event, "content_index")
  {
    None, Some(index) -> tools.set(event, "summary_index", index)
    _, _ -> event
  }
  tools.remove(event, ["content_index"])
}

fn normalize_part(event, suffix) {
  case ir.field(event, "part") {
    Some(part) ->
      case ir.string_field(part, "type") {
        Ok("reasoning_text") ->
          event
          |> event_type("response.reasoning_summary_part." <> suffix)
          |> tools.set("part", event_type(part, "summary_text"))
          |> summary_index
        _ -> event
      }
    None -> event
  }
}

fn normalize_outputs(event) {
  let event = case ir.field(event, "item") {
    Some(item) -> tools.set(event, "item", normalize_item(item))
    None -> event
  }
  case ir.field(event, "response") {
    Some(response) -> tools.set(event, "response", normalize_response(response))
    None -> normalize_response(event)
  }
}

fn normalize_response(response) {
  case ir.field(response, "output") {
    Some(ir.Array(items)) ->
      tools.set(response, "output", ir.Array(list.map(items, normalize_item)))
    _ -> response
  }
}

fn summary_part(part) {
  case ir.string_field(part, "type") {
    Ok("reasoning_text") -> event_type(part, "summary_text")
    _ -> part
  }
}

fn normalize_item(item) {
  case ir.string_field(item, "type") {
    Ok("reasoning") -> {
      let item = case ir.field(item, "summary") {
        Some(ir.Array(parts)) ->
          tools.set(item, "summary", ir.Array(list.map(parts, summary_part)))
        _ -> item
      }
      case ir.field(item, "content") {
        Some(ir.Array(parts)) -> {
          let reasoning =
            list.filter(parts, fn(part) {
              ir.string_field(part, "type") == Ok("reasoning_text")
            })
          // Retain unknown content rather than discard it as CPA does.
          case reasoning {
            [] -> item
            _ ->
              tools.set(
                item,
                "summary",
                ir.Array(list.map(reasoning, summary_part)),
              )
          }
        }
        _ -> item
      }
    }
    _ -> item
  }
}
