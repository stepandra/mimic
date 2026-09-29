/// Native Kimi policy, not a second protocol codec. Keep the native document
/// after shared validation so extensions, reasoning and argument strings survive.
/// CPA pin: acdace936fa7df2905500c7f5e0a97d683138dea.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/dialect/openai
import mimic/dialect/responses
import mimic/ir
import mimic/providers/kimi/json_guard
import mimic/providers/kimi/models

pub fn request(
  body: String,
  model: String,
  protocol: String,
  streaming: Bool,
) -> Result(String, String) {
  use value <- result.try(json_guard.parse(body))
  use named <- result.try(ir.string_field(value, "model"))
  use stream <- result.try(ir.optional_bool(value, "stream", False))
  use _ <- result.try(require(named == model && stream == streaming))
  use upstream <- result.try(case models.upstream_id(model) {
    Some(id) -> Ok(id)
    None -> Error("Unsupported Kimi model")
  })
  // These controls require a distinct stateful/protocol contract. Never drop
  // previous IDs or silently turn compact, audio or legacy calls into text.
  use _ <- result.try(
    absent(value, [
      "previous_response_id", "conversation", "functions", "function_call",
      "audio", "modalities", "prediction", "background",
    ]),
  )
  use value <- result.try(case protocol {
    "chat" -> chat(value, model, streaming)
    "responses" -> response_request(value, model)
    _ -> Error("Unsupported Kimi protocol")
  })
  Ok(ir.stringify(set(value, "model", ir.String(upstream))))
}

fn chat(value: ir.Value, model: String, streaming: Bool) {
  use value <- result.try(thinking(value, model))
  use _ <- result.try(openai.decode_request(ir.stringify(value)))
  use messages <- result.try(
    ir.required(value, "messages") |> result.try(ir.as_array),
  )
  use _ <- result.try(require(messages != []))
  use _ <- result.try(chat_links(messages, [], []))
  use _ <- result.try(
    list.try_each(messages, fn(message) {
      use _ <- result.try(
        absent(message, ["function_call", "call_id", "audio"]),
      )
      use _ <- result.try(case ir.field(message, "reasoning_content") {
        None | Some(ir.String(_)) -> Ok(Nil)
        _ -> Error("Kimi reasoning_content must be text")
      })
      use _ <- result.try(
        case ir.field(message, "tool_calls"), ir.field(value, "thinking") {
          Some(ir.Array([_, ..])), Some(control) ->
            case ir.field(control, "type") {
              Some(ir.String("disabled")) -> Ok(Nil)
              _ -> reasoning_history(message)
            }
          Some(ir.Array([_, ..])), None -> reasoning_history(message)
          _, _ -> Ok(Nil)
        },
      )
      content(ir.field(message, "content"), model, "chat")
    }),
  )
  use _ <- result.try(case ir.field(value, "n") {
    None | Some(ir.Integer(1)) -> Ok(Nil)
    _ -> Error("Kimi supports one choice")
  })
  use value <- result.try(tools(value, "chat"))
  use _ <- result.try(temperature(value))
  case streaming {
    False -> {
      use _ <- result.try(absent(value, ["stream_options"]))
      Ok(value)
    }
    True -> {
      let options = case ir.field(value, "stream_options") {
        None -> ir.Object([])
        Some(options) -> options
      }
      use _ <- result.try(ir.as_object(options))
      use _ <- result.try(case ir.field(options, "include_usage") {
        None | Some(ir.Boolean(True)) -> Ok(Nil)
        _ -> Error("Kimi streaming requires usage")
      })
      Ok(set(
        value,
        "stream_options",
        set(options, "include_usage", ir.Boolean(True)),
      ))
    }
  }
}

fn reasoning_history(message: ir.Value) {
  use text <- result.try(ir.string_field(message, "reasoning_content"))
  require(string.trim(text) != "")
}

fn response_request(value: ir.Value, model: String) {
  use decoded <- result.try(responses.request_from_value(value))
  use _ <- result.try(responses.pair_input(decoded, []))
  use _ <- result.try(absent(value, ["thinking", "reasoning_effort"]))
  use _ <- result.try(case ir.field(value, "reasoning") {
    None -> Ok(Nil)
    Some(reasoning) ->
      case ir.field(reasoning, "effort") {
        None -> Ok(Nil)
        Some(ir.String(level)) -> effort(model, level)
        _ -> Error("Unsupported Kimi reasoning effort")
      }
  })
  use _ <- result.try(case ir.field(value, "input") {
    Some(ir.Array(items)) ->
      list.try_each(items, fn(item) {
        case ir.field(item, "type") {
          None | Some(ir.String("message")) ->
            content(ir.field(item, "content"), model, "responses")
          Some(ir.String("function_call")) -> Ok(Nil)
          Some(ir.String("function_call_output")) ->
            content(ir.field(item, "output"), model, "responses")
          Some(ir.String("reasoning")) ->
            content(ir.field(item, "summary"), model, "responses")
          _ -> Error("Unsupported Kimi input item")
        }
      })
    Some(ir.String(_)) -> Ok(Nil)
    _ -> Error("Kimi input is required")
  })
  // CPA does not apply Chat tool-schema/temperature rewriting to Responses.
  use _ <- result.try(case ir.field(value, "tools") {
    None -> Ok(Nil)
    Some(ir.Array(items)) ->
      list.try_each(items, fn(item) {
        use _ <- result.try(require(
          ir.field(item, "type") == Some(ir.String("function")),
        ))
        Ok(Nil)
      })
    _ -> Error("Invalid Kimi tools")
  })
  Ok(value)
}

// Match tool outputs to explicit calls. CPA can infer IDs or fabricate a
// reasoning placeholder; this adapter rejects ambiguity and never invents text.
fn chat_links(
  messages: List(ir.Value),
  pending: List(String),
  seen: List(String),
) {
  case messages {
    [] -> Ok(Nil)
    [message, ..rest] -> {
      use role <- result.try(ir.string_field(message, "role"))
      case role {
        "tool" -> {
          use id <- result.try(responses.nonempty_string(
            message,
            "tool_call_id",
          ))
          use _ <- result.try(require(list.contains(pending, id)))
          chat_links(rest, list.filter(pending, fn(call) { call != id }), seen)
        }
        _ -> {
          use _ <- result.try(require(pending == []))
          let calls = case ir.field(message, "tool_calls") {
            Some(ir.Array(calls)) -> calls
            _ -> []
          }
          use _ <- result.try(require(calls == [] || role == "assistant"))
          use ids <- result.try(
            list.try_map(calls, fn(call) {
              responses.nonempty_string(call, "id")
            }),
          )
          use _ <- result.try(require(
            list.length(list.unique(ids)) == list.length(ids)
            && !list.any(ids, fn(id) { list.contains(seen, id) }),
          ))
          chat_links(rest, ids, list.append(seen, ids))
        }
      }
    }
  }
}

fn tools(value: ir.Value, protocol: String) {
  case ir.field(value, "tools") {
    None -> Ok(value)
    Some(ir.Array(items)) -> {
      use items <- result.try(
        list.try_map(items, fn(tool) {
          use _ <- result.try(require(
            ir.field(tool, "type") == Some(ir.String("function")),
          ))
          use function <- result.try(case protocol {
            "chat" -> ir.required(tool, "function")
            _ -> Ok(tool)
          })
          use _ <- result.try(responses.nonempty_string(function, "name"))
          use function <- result.try(case ir.field(function, "parameters") {
            None -> Ok(function)
            Some(parameters) -> {
              use _ <- result.try(ir.as_object(parameters))
              // Inline reference resolution is not claimed. Ref-bearing schemas
              // fail explicitly instead of stripping definitions and losing meaning.
              use _ <- result.try(no_refs(parameters))
              use parameters <- result.try(case ir.field(parameters, "type") {
                None -> Ok(set(parameters, "type", ir.String("object")))
                Some(ir.String("object")) -> Ok(parameters)
                _ -> Error("Kimi tool parameters must be an object schema")
              })
              Ok(set(function, "parameters", parameters))
            }
          })
          Ok(set(tool, "function", function))
        }),
      )
      Ok(set(value, "tools", ir.Array(items)))
    }
    _ -> Error("Invalid Kimi tools")
  }
}

fn no_refs(value: ir.Value) -> Result(Nil, String) {
  case value {
    ir.Object(fields) ->
      list.try_each(fields, fn(field) {
        use _ <- result.try(require(
          !list.contains(["$ref", "$defs", "definitions"], field.0),
        ))
        no_refs(field.1)
      })
    ir.Array(items) -> list.try_each(items, no_refs)
    _ -> Ok(Nil)
  }
}

fn thinking(value: ir.Value, model: String) {
  use _ <- result.try(absent(value, ["reasoning"]))
  use value <- result.try(
    case ir.field(value, "reasoning_effort"), ir.field(value, "thinking") {
      None, _ -> Ok(value)
      Some(ir.String(level)), None -> {
        use _ <- result.try(effort(model, level))
        let fields = case level {
          "none" -> [#("type", ir.String("disabled"))]
          _ -> [#("type", ir.String("enabled")), #("effort", ir.String(level))]
        }
        Ok(set(remove(value, "reasoning_effort"), "thinking", ir.Object(fields)))
      }
      _, _ -> Error("Conflicting or invalid Kimi thinking controls")
    },
  )
  use _ <- result.try(case ir.field(value, "thinking") {
    None -> Ok(Nil)
    Some(thinking) -> {
      use _ <- result.try(ir.as_object(thinking))
      use _ <- result.try(absent(thinking, ["budget_tokens"]))
      use _ <- result.try(case ir.field(thinking, "keep") {
        None | Some(ir.Boolean(_)) -> Ok(Nil)
        _ -> Error("Invalid Kimi thinking.keep")
      })
      case ir.field(thinking, "type"), ir.field(thinking, "effort") {
        Some(ir.String("disabled")), None -> effort(model, "none")
        Some(ir.String("enabled")), None -> effort(model, "high")
        Some(ir.String("enabled")), Some(ir.String(level)) if level != "none" ->
          effort(model, level)
        _, _ -> Error("Unsupported Kimi thinking")
      }
    }
  })
  Ok(value)
}

fn effort(model: String, level: String) {
  require(list.contains(models.thinking_levels(model), level))
}

fn temperature(value: ir.Value) {
  let disabled = case ir.field(value, "thinking") {
    Some(thinking) -> ir.field(thinking, "type") == Some(ir.String("disabled"))
    None -> False
  }
  case ir.field(value, "temperature"), disabled {
    None, _ -> Ok(Nil)
    Some(ir.Decimal(0.6)), True -> Ok(Nil)
    Some(ir.Integer(1)), False | Some(ir.Decimal(1.0)), False -> Ok(Nil)
    _, _ -> Error("Kimi temperature would be discarded upstream")
  }
}

fn content(value: option.Option(ir.Value), model: String, protocol: String) {
  case value {
    None | Some(ir.Null) | Some(ir.String(_)) -> Ok(Nil)
    Some(ir.Array(parts)) ->
      list.try_each(parts, fn(part) {
        case ir.field(part, "type"), protocol {
          Some(ir.String("text")), "chat"
          | Some(ir.String("input_text")), "responses"
          | Some(ir.String("output_text")), "responses"
          | Some(ir.String("summary_text")), "responses"
          | Some(ir.String("reasoning_text")), "responses"
          -> {
            use _ <- result.try(ir.string_field(part, "text"))
            Ok(Nil)
          }
          Some(ir.String("image_url")), "chat" -> {
            use image <- result.try(ir.required(part, "image_url"))
            use url <- result.try(ir.string_field(image, "url"))
            image_url(url, model)
          }
          Some(ir.String("input_image")), "responses" -> {
            use _ <- result.try(absent(part, ["file_id"]))
            use url <- result.try(ir.string_field(part, "image_url"))
            image_url(url, model)
          }
          _, _ -> Error("Unsupported Kimi media/content form")
        }
      })
    _ -> Error("Unsupported Kimi content")
  }
}

pub fn image_url(url: String, model: String) {
  use _ <- result.try(require(models.supports_images(model)))
  // Native forwarding only; never download a URL. Inline data is bounded by
  // the request parser and remains opaque, not decoded into filesystem data.
  case string.starts_with(url, "data:") {
    True ->
      require(
        list.any(["png", "jpeg", "webp", "gif"], fn(kind) {
          let prefix = "data:image/" <> kind <> ";base64,"
          string.starts_with(url, prefix)
          && string.length(url) > string.length(prefix)
        }),
      )
    False -> {
      use parsed <- result.try(
        uri.parse(url) |> result.map_error(fn(_) { "Invalid image URL" }),
      )
      require(
        parsed.scheme == Some("https")
        && parsed.host != None
        && parsed.host != Some("")
        && parsed.userinfo == None
        && parsed.fragment == None,
      )
    }
  }
}

/// Restore only protocol-owned model slots. Never rewrite tool arguments,
/// reasoning text, user extensions or arbitrary nested keys named "model".
pub fn restore_checked(
  value: ir.Value,
  requested_model: String,
) -> Result(ir.Value, String) {
  use _ <- result.try(check_model(value, requested_model))
  Ok(restore(value, requested_model))
}

/// Only the Responses event runner may call this envelope-specific hook.
pub fn restore_response_event(
  value: ir.Value,
  requested_model: String,
) -> Result(ir.Value, String) {
  case ir.field(value, "type"), ir.field(value, "response") {
    Some(ir.String(kind)), Some(response)
      if kind == "response.created"
      || kind == "response.in_progress"
      || kind == "response.completed"
      || kind == "response.incomplete"
      || kind == "response.failed"
    -> {
      use response <- result.try(restore_checked(response, requested_model))
      Ok(set(value, "response", response))
    }
    _, _ -> Ok(value)
  }
}

fn check_model(value: ir.Value, requested_model: String) {
  case ir.field(value, "model") {
    None -> Ok(Nil)
    Some(ir.String(id)) ->
      require(
        id == requested_model || models.upstream_id(requested_model) == Some(id),
      )
    _ -> Error("Invalid Kimi response model")
  }
}

pub fn restore(value: ir.Value, requested_model: String) -> ir.Value {
  case ir.field(value, "model") {
    Some(_) -> set(value, "model", ir.String(requested_model))
    None -> value
  }
}

pub fn set(value: ir.Value, key: String, replacement: ir.Value) -> ir.Value {
  case value {
    ir.Object(fields) ->
      ir.Object(
        list.append(list.filter(fields, fn(field) { field.0 != key }), [
          #(key, replacement),
        ]),
      )
    _ -> value
  }
}

fn remove(value: ir.Value, key: String) -> ir.Value {
  case value {
    ir.Object(fields) ->
      ir.Object(list.filter(fields, fn(field) { field.0 != key }))
    _ -> value
  }
}

fn absent(value: ir.Value, keys: List(String)) {
  require(list.all(keys, fn(key) { ir.field(value, key) == None }))
}

fn require(condition: Bool) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error("Unsupported or ambiguous native Kimi request")
  }
}
