/// Bounded native Anthropic Messages delegation. Uses the shared decoder but
/// forwards the native document: signed thinking and extension fields are not
/// projected through Chat. There is no implicit signed-thinking replay cache.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/dialect/anthropic
import mimic/ir
import mimic/providers/kimi/json_guard
import mimic/providers/kimi/models
import mimic/providers/kimi/transform

pub fn prepare(
  body: String,
  model: String,
  streaming: Bool,
) -> Result(String, String) {
  use value <- result.try(json_guard.parse(body))
  use named <- result.try(ir.string_field(value, "model"))
  use stream <- result.try(ir.optional_bool(value, "stream", False))
  use upstream <- result.try(case models.upstream_id(model) {
    Some(upstream) if named == model && stream == streaming -> Ok(upstream)
    _ -> Error("Invalid Kimi Messages model/mode")
  })
  use _ <- result.try(
    case
      list.any(
        ["previous_response_id", "conversation", "audio", "modalities"],
        fn(key) { ir.field(value, key) != None },
      )
    {
      True -> Error("Unsupported Kimi Messages continuation/media")
      False -> Ok(Nil)
    },
  )
  use value <- result.try(validate(value, model))
  Ok(transform.set(value, "model", ir.String(upstream)) |> ir.stringify)
}

pub fn validate(value: ir.Value, model: String) -> Result(ir.Value, String) {
  use decoded <- result.try(anthropic.decode_request(ir.stringify(value)))
  use _ <- result.try(case decoded.max_tokens {
    Some(limit) if limit > 0 -> Ok(Nil)
    _ -> Error("Kimi Messages requires positive max_tokens")
  })
  use _ <- result.try(case decoded.turns {
    [] -> Error("Kimi Messages requires messages")
    turns ->
      list.try_each(turns, fn(turn) {
        case turn.role {
          "user" | "assistant" -> Ok(Nil)
          _ -> Error("Unsupported Kimi Messages role")
        }
      })
  })
  use _ <- result.try(
    list.try_each(decoded.turns, fn(turn) {
      list.try_each(turn.content, fn(block) { content(block, model) })
    }),
  )
  use _ <- result.try(
    list.try_fold(decoded.turns, #([], []), fn(state, turn) {
      list.try_fold(turn.content, state, fn(state, block) {
        let #(seen, pending) = state
        case block {
          ir.ToolCall(id, name, input, _, _) -> {
            use _ <- result.try(ir.as_object(input))
            case
              turn.role == "assistant"
              && id != ""
              && name != ""
              && !list.contains(seen, id)
            {
              True -> Ok(#([id, ..seen], [id, ..pending]))
              False -> Error("Invalid Kimi Messages tool call identity")
            }
          }
          ir.ToolResult(id, _, _) ->
            case turn.role == "user" && list.contains(pending, id) {
              True -> Ok(#(seen, list.filter(pending, fn(call) { call != id })))
              False -> Error("Unpaired Kimi Messages tool result")
            }
          _ -> Ok(state)
        }
      })
    }),
  )
  use _ <- result.try(case ir.field(value, "tools") {
    None -> Ok(Nil)
    Some(ir.Array(tools)) ->
      list.try_each(tools, fn(tool) {
        use _ <- result.try(ir.string_field(tool, "name"))
        use schema <- result.try(ir.required(tool, "input_schema"))
        use _ <- result.try(ir.as_object(schema))
        Ok(Nil)
      })
    _ -> Error("Invalid Kimi Messages tools")
  })
  // Explicit native Claude controls only. Budget/suffix/effort clamping is not
  // reproduced; callers must choose a representable native control.
  use _ <- result.try(
    case ir.field(value, "reasoning_effort"), ir.field(value, "reasoning") {
      None, None -> Ok(Nil)
      _, _ -> Error("Kimi Messages requires native thinking controls")
    },
  )
  use _ <- result.try(case ir.field(value, "thinking") {
    None -> Ok(Nil)
    Some(thinking) -> {
      use kind <- result.try(ir.string_field(thinking, "type"))
      case kind, ir.field(thinking, "budget_tokens") {
        "disabled", None ->
          case list.contains(models.thinking_levels(model), "none") {
            True -> Ok(Nil)
            False -> Error("This Kimi model cannot disable thinking")
          }
        "enabled", Some(ir.Integer(budget)) if budget > 0 ->
          case decoded.max_tokens {
            Some(limit) if budget < limit && model != "kimi-k2" -> Ok(Nil)
            _ ->
              Error("Kimi thinking budget exceeds the supported output bound")
          }
        _, _ -> Error("Unsupported Kimi Messages thinking")
      }
    }
  })
  Ok(value)
}

fn content(block: ir.Content, model: String) -> Result(Nil, String) {
  case block {
    ir.Text(_, _) | ir.ToolCall(_, _, _, _, _) -> Ok(Nil)
    ir.Thinking(_, Some(signature), _) if signature != "" -> Ok(Nil)
    ir.Thinking(_, _, _) ->
      Error("Kimi thinking history requires its signature")
    ir.ToolResult(_, ir.String(_), _) -> Ok(Nil)
    ir.ToolResult(_, _, _) ->
      Error("Kimi Messages tool results currently require text")
    ir.Unknown(value) -> {
      use kind <- result.try(ir.string_field(value, "type"))
      case kind {
        "redacted_thinking" -> {
          use _ <- result.try(ir.string_field(value, "data"))
          Ok(Nil)
        }
        "image" -> {
          use source <- result.try(ir.required(value, "source"))
          use kind <- result.try(ir.string_field(source, "type"))
          case kind {
            "url" -> {
              use url <- result.try(ir.string_field(source, "url"))
              transform.image_url(url, model)
            }
            "base64" -> {
              use media <- result.try(ir.string_field(source, "media_type"))
              use data <- result.try(ir.string_field(source, "data"))
              transform.image_url("data:" <> media <> ";base64," <> data, model)
            }
            _ -> Error("Unsupported Kimi image source")
          }
        }
        _ -> Error("Unsupported Kimi Messages content")
      }
    }
  }
}
