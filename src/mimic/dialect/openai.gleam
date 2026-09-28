import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir

pub fn decode_request(body: String) -> Result(ir.Request, String) {
  use root <- result.try(ir.parse(body))
  use _ <- result.try(ir.as_object(root))
  use model <- result.try(ir.string_field(root, "model"))
  use messages <- result.try(ir.required(root, "messages"))
  use messages <- result.try(ir.as_array(messages))
  use parsed <- result.try(list.try_map(messages, decode_message))
  let system = parsed |> list.map(fn(message) { message.0 }) |> option.values
  let turns = parsed |> list.map(fn(message) { message.1 }) |> option.values
  use system <- result.try(case system {
    [] -> Ok(#(None, "system"))
    [value] -> Ok(#(Some(value.1), value.0))
    _ ->
      Error(
        "multiple system/developer messages cannot be translated losslessly",
      )
  })
  use _ <- result.try(case parsed {
    [#(None, Some(_)), ..] if system.0 != None ->
      Error("system/developer message after conversation start is unsupported")
    _ -> Ok(Nil)
  })
  let stream = case ir.field(root, "stream") {
    None -> Ok(None)
    Some(value) -> ir.as_bool(value) |> result.map(Some)
  }
  use stream <- result.try(stream)
  let token_limit_field = case ir.field(root, "max_completion_tokens") {
    Some(_) -> "max_completion_tokens"
    None -> "max_tokens"
  }
  use _ <- result.try(
    case ir.field(root, "max_tokens"), ir.field(root, "max_completion_tokens") {
      Some(_), Some(_) -> Error("both OpenAI token limit fields present")
      _, _ -> Ok(Nil)
    },
  )
  use max_tokens <- result.try(ir.optional_int(root, token_limit_field))
  Ok(ir.Request(
    model: model,
    system: system.0,
    system_role: system.1,
    turns: turns,
    max_tokens: max_tokens,
    token_limit_field: token_limit_field,
    stream: stream,
    extensions: ir.extras(root, [
      "model",
      "messages",
      "max_tokens",
      "max_completion_tokens",
      "stream",
    ]),
    origin: ir.Openai,
  ))
}

pub fn encode_request(request: ir.Request) -> Result(String, String) {
  use messages <- result.try(
    list.try_map(request.turns, fn(turn) { encode_turn(turn, request.origin) }),
  )
  let messages = case request.system {
    Some(ir.String(system)) -> [
      ir.Object([
        #("role", ir.String(request.system_role)),
        #("content", ir.String(system)),
      ]),
      ..messages
    ]
    Some(ir.Array(blocks)) if request.origin == ir.Openai -> [
      ir.Object([
        #("role", ir.String(request.system_role)),
        #("content", ir.Array(blocks)),
      ]),
      ..messages
    ]
    Some(_) -> messages
    None -> messages
  }
  use _ <- result.try(case request.system, request.origin {
    Some(ir.String(_)), _ | None, _ | Some(ir.Array(_)), ir.Openai -> Ok(Nil)
    _, _ -> Error("unsupported Anthropic system blocks in OpenAI translation")
  })
  let fields = [
    #("model", ir.String(request.model)),
    #("messages", ir.Array(messages)),
  ]
  let token_field = case request.origin, request.token_limit_field {
    ir.Openai, "max_tokens" -> "max_tokens"
    _, _ -> "max_completion_tokens"
  }
  let fields =
    ir.with_optional(fields, token_field, ir.option_int(request.max_tokens))
  let fields =
    ir.with_optional(fields, "stream", case request.stream {
      Some(value) -> Some(ir.Boolean(value))
      None -> None
    })
  use fields <- result.try(extensions(
    fields,
    request.extensions,
    request.origin,
  ))
  Ok(ir.stringify(ir.Object(fields)))
}

fn decode_message(
  message: ir.Value,
) -> Result(#(Option(#(String, ir.Value)), Option(ir.Turn)), String) {
  use _ <- result.try(ir.as_object(message))
  use role <- result.try(ir.string_field(message, "role"))
  case role {
    "system" | "developer" -> {
      use _ <- result.try(case ir.extras(message, ["role", "content"]) {
        [] -> Ok(Nil)
        _ -> Error("unsupported system message extensions")
      })
      use content <- result.try(ir.required(message, "content"))
      Ok(#(Some(#(role, content)), None))
    }
    "tool" -> {
      use id <- result.try(ir.string_field(message, "tool_call_id"))
      use content <- result.try(ir.required(message, "content"))
      Ok(#(
        None,
        Some(ir.Turn(
          role: "tool",
          content: [ir.ToolResult(id, content, [])],
          content_is_string: False,
          extensions: ir.extras(message, ["role", "tool_call_id", "content"]),
        )),
      ))
    }
    "assistant" | "user" -> {
      let raw_content = case ir.field(message, "content") {
        Some(value) -> value
        None -> ir.Null
      }
      use content <- result.try(decode_message_content(raw_content))
      let tools = case ir.field(message, "tool_calls") {
        Some(ir.Array(calls)) -> list.try_map(calls, decode_tool_call)
        Some(_) -> Error("tool_calls must be an array")
        None -> Ok([])
      }
      use tools <- result.try(tools)
      Ok(#(
        None,
        Some(ir.Turn(
          role: role,
          content: list.append(content, tools),
          content_is_string: case raw_content {
            ir.String(_) -> True
            _ -> False
          },
          extensions: ir.extras(message, ["role", "content", "tool_calls"]),
        )),
      ))
    }
    _ -> Error("unsupported OpenAI role: " <> role)
  }
}

fn decode_message_content(value: ir.Value) -> Result(List(ir.Content), String) {
  case value {
    ir.Null -> Ok([])
    ir.String(text) -> Ok([ir.Text(text, [])])
    ir.Array(blocks) ->
      list.try_map(blocks, fn(block) {
        use kind <- result.try(ir.string_field(block, "type"))
        case kind {
          "text" -> {
            use text <- result.try(ir.string_field(block, "text"))
            Ok(ir.Text(text, ir.extras(block, ["type", "text"])))
          }
          _ -> Ok(ir.Unknown(block))
        }
      })
    _ -> Error("unsupported OpenAI message content")
  }
}

fn decode_tool_call(value: ir.Value) -> Result(ir.Content, String) {
  use id <- result.try(ir.string_field(value, "id"))
  use kind <- result.try(ir.string_field(value, "type"))
  use _ <- result.try(case kind {
    "function" -> Ok(Nil)
    _ -> Error("unsupported tool call type")
  })
  use function <- result.try(ir.required(value, "function"))
  use name <- result.try(ir.string_field(function, "name"))
  use arguments <- result.try(ir.string_field(function, "arguments"))
  use input <- result.try(ir.parse(arguments))
  use _ <- result.try(case ir.extras(function, ["name", "arguments"]) {
    [] -> Ok(Nil)
    _ -> Error("unsupported OpenAI function call extensions")
  })
  Ok(ir.ToolCall(
    id,
    name,
    input,
    Some(arguments),
    ir.extras(value, ["id", "type", "function"]),
  ))
}

fn encode_turn(turn: ir.Turn, origin: ir.Origin) -> Result(ir.Value, String) {
  case turn.role, turn.content {
    "user", [ir.ToolResult(id, content, extras)] -> {
      use _ <- result.try(case extras, turn.extensions {
        [], [] -> Ok(Nil)
        _, _ ->
          Error(
            "unsupported Anthropic tool-result extensions in OpenAI translation",
          )
      })
      Ok(
        ir.Object([
          #("role", ir.String("tool")),
          #("tool_call_id", ir.String(id)),
          #("content", content),
        ]),
      )
    }
    _, _ -> encode_regular_turn(turn, origin)
  }
}

fn encode_regular_turn(
  turn: ir.Turn,
  origin: ir.Origin,
) -> Result(ir.Value, String) {
  case turn.role {
    "tool" ->
      case turn.content {
        [ir.ToolResult(id, content, [])] -> {
          use fields <- result.try(nested_extensions(
            [
              #("role", ir.String("tool")),
              #("tool_call_id", ir.String(id)),
              #("content", content),
            ],
            turn.extensions,
            origin,
          ))
          Ok(ir.Object(fields))
        }
        _ -> Error("unsupported tool result shape for OpenAI")
      }
    "assistant" | "user" -> {
      let texts =
        list.filter(turn.content, fn(block) {
          case block {
            ir.ToolCall(_, _, _, _, _) -> False
            _ -> True
          }
        })
      let calls =
        list.filter(turn.content, fn(block) {
          case block {
            ir.ToolCall(_, _, _, _, _) -> True
            _ -> False
          }
        })
      use text <- result.try(encode_content(
        texts,
        turn.content_is_string,
        origin,
      ))
      use calls <- result.try(
        list.try_map(calls, fn(call) { encode_tool_call(call, origin) }),
      )
      let fields = [#("role", ir.String(turn.role)), #("content", text)]
      let fields = case calls {
        [] -> fields
        _ -> list.append(fields, [#("tool_calls", ir.Array(calls))])
      }
      use fields <- result.try(nested_extensions(
        fields,
        turn.extensions,
        origin,
      ))
      Ok(ir.Object(fields))
    }
    _ -> Error("unsupported role for OpenAI: " <> turn.role)
  }
}

fn encode_content(
  content: List(ir.Content),
  as_string: Bool,
  origin: ir.Origin,
) -> Result(ir.Value, String) {
  case content, as_string {
    [], _ -> Ok(ir.Null)
    [ir.Text(text, [])], True -> Ok(ir.String(text))
    _, True -> Error("string content requires exactly one plain text block")
    _, False ->
      list.try_map(content, fn(block) {
        case block {
          ir.Text(_, [_, ..]) if origin == ir.Anthropic ->
            Error("unsupported Anthropic text extensions in OpenAI translation")
          ir.Text(text, extras) ->
            Ok(
              ir.Object(list.append(
                [
                  #("type", ir.String("text")),
                  #("text", ir.String(text)),
                ],
                extras,
              )),
            )
          ir.Thinking(_, _, _) ->
            Error("thinking cannot be represented in OpenAI chat")
          ir.Unknown(value) if origin == ir.Openai -> Ok(value)
          ir.Unknown(_) ->
            Error("unknown content block cannot be represented in OpenAI chat")
          _ -> Error("unsupported content block for OpenAI chat")
        }
      })
      |> result.map(ir.Array)
  }
}

fn encode_tool_call(
  value: ir.Content,
  origin: ir.Origin,
) -> Result(ir.Value, String) {
  case value {
    ir.ToolCall(id, name, input, raw, extras) ->
      case origin, extras {
        ir.Anthropic, [_, ..] ->
          Error("unsupported Anthropic tool call extensions in OpenAI chat")
        _, _ -> {
          let arguments = case raw {
            Some(original) ->
              case ir.parse(original) {
                Ok(parsed) if parsed == input -> original
                _ -> ir.stringify(input)
              }
            None -> ir.stringify(input)
          }
          Ok(
            ir.Object(list.append(
              [
                #("id", ir.String(id)),
                #("type", ir.String("function")),
                #(
                  "function",
                  ir.Object([
                    #("name", ir.String(name)),
                    #("arguments", ir.String(arguments)),
                  ]),
                ),
              ],
              extras,
            )),
          )
        }
      }
    _ -> Error("expected tool call")
  }
}

pub fn decode_response(body: String) -> Result(ir.Response, String) {
  use root <- result.try(ir.parse(body))
  use id <- result.try(ir.string_field(root, "id"))
  use model <- result.try(ir.string_field(root, "model"))
  use choices <- result.try(ir.required(root, "choices"))
  use choices <- result.try(ir.as_array(choices))
  use choice <- result.try(case choices {
    [choice] -> Ok(choice)
    _ -> Error("OpenAI response requires exactly one choice")
  })
  use index <- result.try(index_field(choice))
  use _ <- result.try(case index {
    0 -> Ok(Nil)
    _ -> Error("OpenAI choice index must be zero")
  })
  use message <- result.try(ir.required(choice, "message"))
  use parsed <- result.try(decode_message(message))
  use turn <- result.try(case parsed.1 {
    Some(ir.Turn(role: "assistant", ..) as turn) -> Ok(turn)
    None -> Error("expected assistant message")
    _ -> Error("expected assistant message")
  })
  use reason <- result.try(ir.optional_string(choice, "finish_reason"))
  let reason = case reason {
    Some("stop") -> Some("end_turn")
    Some("tool_calls") -> Some("tool_use")
    Some("length") -> Some("max_tokens")
    other -> other
  }
  let usage = case ir.field(root, "usage") {
    Some(ir.Null) | None -> Ok(None)
    Some(value) -> decode_usage(value) |> result.map(Some)
  }
  use usage <- result.try(usage)
  Ok(ir.Response(
    id,
    model,
    turn.content,
    turn.content_is_string,
    reason,
    usage,
    turn.extensions,
    ir.extras(choice, ["index", "message", "finish_reason"]),
    ir.extras(root, ["id", "model", "choices", "usage"]),
    ir.Openai,
  ))
}

pub fn encode_response(response: ir.Response) -> Result(String, String) {
  use usage <- result.try(case response.origin, response.usage {
    ir.Anthropic, Some(usage) ->
      case zero_cache_extensions(usage.extensions) {
        True -> Ok(Some(ir.Usage(..usage, extensions: [])))
        False ->
          Error("unsupported Anthropic usage extensions in OpenAI translation")
      }
    _, usage -> Ok(usage)
  })
  use _ <- result.try(case response.origin, response.stop_reason {
    ir.Anthropic, Some("end_turn")
    | ir.Anthropic, Some("tool_use")
    | ir.Anthropic, Some("max_tokens")
    | ir.Anthropic, None
    -> Ok(Nil)
    ir.Anthropic, Some(_) ->
      Error("unsupported Anthropic stop reason in OpenAI translation")
    _, _ -> Ok(Nil)
  })
  use content <- result.try(encode_turn(
    ir.Turn(
      "assistant",
      response.content,
      response.content_is_string,
      response.message_extensions,
    ),
    response.origin,
  ))
  use choice_fields <- result.try(nested_extensions(
    [
      #("index", ir.Integer(0)),
      #("message", content),
      #("finish_reason", case response.stop_reason {
        Some("end_turn") -> ir.String("stop")
        Some("tool_use") -> ir.String("tool_calls")
        Some("max_tokens") -> ir.String("length")
        Some(reason) -> ir.String(reason)
        None -> ir.Null
      }),
    ],
    response.choice_extensions,
    response.origin,
  ))
  let choice = ir.Object(choice_fields)
  let fields = [
    #("id", ir.String(response.id)),
    #("model", ir.String(response.model)),
    #("choices", ir.Array([choice])),
  ]
  let fields =
    ir.with_optional(fields, "usage", case usage {
      Some(value) -> Some(encode_usage(value, response.origin))
      None -> None
    })
  let extras = case response.origin {
    ir.Anthropic ->
      list.filter(response.extensions, fn(entry) {
        case entry {
          #("stop_sequence", ir.Null) -> False
          _ -> True
        }
      })
    _ -> response.extensions
  }
  use fields <- result.try(nested_extensions(fields, extras, response.origin))
  Ok(ir.stringify(ir.Object(fields)))
}

/// Zero cache counts add no billing/usage semantics to basic Chat usage.
/// Positive or unknown counters must remain explicit errors across dialects.
pub fn zero_cache_extensions(extras: List(#(String, ir.Value))) -> Bool {
  list.all(extras, fn(entry) {
    case entry {
      #("cache_creation_input_tokens", ir.Integer(0)) -> True
      #("cache_read_input_tokens", ir.Integer(0)) -> True
      _ -> False
    }
  })
}

fn index_field(value: ir.Value) -> Result(Int, String) {
  use index <- result.try(ir.required(value, "index"))
  ir.as_int(index)
}

fn decode_usage(value: ir.Value) -> Result(ir.Usage, String) {
  use input <- result.try(ir.required(value, "prompt_tokens"))
  use input <- result.try(ir.as_int(input))
  use output <- result.try(ir.required(value, "completion_tokens"))
  use output <- result.try(ir.as_int(output))
  Ok(ir.Usage(
    input,
    output,
    ir.extras(value, ["prompt_tokens", "completion_tokens"]),
  ))
}

fn encode_usage(value: ir.Usage, origin: ir.Origin) -> ir.Value {
  let fields = [
    #("prompt_tokens", ir.Integer(value.input_tokens)),
    #("completion_tokens", ir.Integer(value.output_tokens)),
  ]
  let fields = case origin {
    ir.Openai -> fields
    _ ->
      list.append(fields, [
        #("total_tokens", ir.Integer(value.input_tokens + value.output_tokens)),
      ])
  }
  ir.Object(list.append(fields, value.extensions))
}

fn extensions(
  fields: List(#(String, ir.Value)),
  extras: List(#(String, ir.Value)),
  origin: ir.Origin,
) -> Result(List(#(String, ir.Value)), String) {
  case origin {
    ir.Anthropic -> {
      use converted <- result.try(list.try_map(extras, anthropic_option))
      Ok(list.append(fields, converted))
    }
    _ -> Ok(list.append(fields, extras))
  }
}

fn nested_extensions(
  fields: List(#(String, ir.Value)),
  extras: List(#(String, ir.Value)),
  origin: ir.Origin,
) -> Result(List(#(String, ir.Value)), String) {
  case origin, extras {
    ir.Anthropic, [_, ..] ->
      Error("unsupported Anthropic nested extensions in OpenAI translation")
    _, _ -> Ok(list.append(fields, extras))
  }
}

fn anthropic_option(
  entry: #(String, ir.Value),
) -> Result(#(String, ir.Value), String) {
  case entry {
    #("temperature", _) | #("top_p", _) -> Ok(entry)
    #("stop_sequences", ir.Array(stops)) -> Ok(#("stop", ir.Array(stops)))
    #("tools", ir.Array(tools)) ->
      list.try_map(tools, fn(tool) {
        use _ <- result.try(
          case ir.extras(tool, ["name", "description", "input_schema"]) {
            [] -> Ok(Nil)
            _ -> Error("unsupported Anthropic tool definition extensions")
          },
        )
        use name <- result.try(ir.string_field(tool, "name"))
        use schema <- result.try(ir.required(tool, "input_schema"))
        let function =
          ir.Object(ir.with_optional(
            [
              #("name", ir.String(name)),
              #("parameters", schema),
            ],
            "description",
            ir.field(tool, "description"),
          ))
        Ok(
          ir.Object([
            #("type", ir.String("function")),
            #("function", function),
          ]),
        )
      })
      |> result.map(fn(tools) { #("tools", ir.Array(tools)) })
    #("tool_choice", ir.Object(fields)) -> {
      let value = ir.Object(fields)
      use kind <- result.try(ir.string_field(value, "type"))
      case kind {
        "auto" -> Ok(#("tool_choice", ir.String("auto")))
        "any" -> Ok(#("tool_choice", ir.String("required")))
        "tool" -> {
          use name <- result.try(ir.string_field(value, "name"))
          use _ <- result.try(case ir.extras(value, ["type", "name"]) {
            [] -> Ok(Nil)
            _ -> Error("unsupported Anthropic named tool choice extensions")
          })
          Ok(#(
            "tool_choice",
            ir.Object([
              #("type", ir.String("function")),
              #("function", ir.Object([#("name", ir.String(name))])),
            ]),
          ))
        }
        _ -> Error("unsupported Anthropic tool choice")
      }
    }
    #(key, _) ->
      Error("unsupported Anthropic extension in OpenAI translation: " <> key)
  }
}
