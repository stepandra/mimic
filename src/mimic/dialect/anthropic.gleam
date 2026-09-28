import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir

pub fn decode_request(body: String) -> Result(ir.Request, String) {
  use root <- result.try(ir.parse(body))
  use _ <- result.try(ir.as_object(root))
  use model <- result.try(ir.string_field(root, "model"))
  use max_tokens <- result.try(ir.optional_int(root, "max_tokens"))
  use messages <- result.try(ir.required(root, "messages"))
  use messages <- result.try(ir.as_array(messages))
  use turns <- result.try(list.try_map(messages, decode_turn))
  let stream = case ir.field(root, "stream") {
    None -> Ok(None)
    Some(value) -> ir.as_bool(value) |> result.map(Some)
  }
  use stream <- result.try(stream)
  Ok(ir.Request(
    model: model,
    system: ir.field(root, "system"),
    system_role: "system",
    turns: turns,
    max_tokens: max_tokens,
    token_limit_field: "max_tokens",
    stream: stream,
    extensions: ir.extras(root, [
      "model",
      "system",
      "messages",
      "max_tokens",
      "stream",
    ]),
    origin: ir.Anthropic,
  ))
}

pub fn encode_request(request: ir.Request) -> Result(String, String) {
  use _ <- result.try(case request.origin, request.system_role {
    ir.Openai, "developer" ->
      Error(
        "OpenAI developer instructions cannot be represented as Anthropic system instructions",
      )
    _, _ -> Ok(Nil)
  })
  use turns <- result.try(
    list.try_map(request.turns, fn(turn) { encode_turn(turn, request.origin) }),
  )
  let fields = [
    #("model", ir.String(request.model)),
    #("messages", ir.Array(turns)),
  ]
  let fields = ir.with_optional(fields, "system", request.system)
  let fields =
    ir.with_optional(fields, "max_tokens", ir.option_int(request.max_tokens))
  let fields =
    ir.with_optional(fields, "stream", case request.stream {
      Some(value) -> Some(ir.Boolean(value))
      None -> None
    })
  use fields <- result.try(merge_extensions(
    fields,
    request.extensions,
    request.origin,
  ))
  Ok(ir.stringify(ir.Object(fields)))
}

fn decode_turn(value: ir.Value) -> Result(ir.Turn, String) {
  use _ <- result.try(ir.as_object(value))
  use role <- result.try(ir.string_field(value, "role"))
  use content <- result.try(ir.required(value, "content"))
  let content_is_string = case content {
    ir.String(_) -> True
    _ -> False
  }
  use blocks <- result.try(decode_content(content))
  Ok(ir.Turn(
    role,
    blocks,
    content_is_string,
    ir.extras(value, ["role", "content"]),
  ))
}

fn encode_turn(turn: ir.Turn, origin: ir.Origin) -> Result(ir.Value, String) {
  use _ <- result.try(case origin, turn.extensions {
    ir.Openai, [_, ..] ->
      Error("unsupported OpenAI message extensions in Anthropic translation")
    _, _ -> Ok(Nil)
  })
  let role = case turn.role {
    "tool" -> "user"
    other -> other
  }
  use content <- result.try(encode_content(
    turn.content,
    turn.content_is_string,
    origin,
  ))
  Ok(
    ir.Object(list.append(
      [
        #("role", ir.String(role)),
        #("content", content),
      ],
      turn.extensions,
    )),
  )
}

fn decode_content(value: ir.Value) -> Result(List(ir.Content), String) {
  case value {
    ir.String(text) -> Ok([ir.Text(text, [])])
    ir.Array(blocks) -> list.try_map(blocks, decode_block)
    _ -> Error("Anthropic content must be a string or block array")
  }
}

fn encode_content(
  blocks: List(ir.Content),
  as_string: Bool,
  origin: ir.Origin,
) -> Result(ir.Value, String) {
  case as_string, blocks {
    True, [ir.Text(text, [])] -> Ok(ir.String(text))
    True, _ -> Error("string content requires exactly one plain text block")
    False, _ ->
      list.try_map(blocks, fn(block) { encode_block(block, origin) })
      |> result.map(ir.Array)
  }
}

fn decode_block(value: ir.Value) -> Result(ir.Content, String) {
  use _ <- result.try(ir.as_object(value))
  use kind <- result.try(ir.string_field(value, "type"))
  case kind {
    "text" -> {
      use text <- result.try(ir.string_field(value, "text"))
      Ok(ir.Text(text, ir.extras(value, ["type", "text"])))
    }
    "tool_use" -> {
      use id <- result.try(ir.string_field(value, "id"))
      use name <- result.try(ir.string_field(value, "name"))
      use input <- result.try(ir.required(value, "input"))
      Ok(ir.ToolCall(
        id,
        name,
        input,
        None,
        ir.extras(value, ["type", "id", "name", "input"]),
      ))
    }
    "tool_result" -> {
      use id <- result.try(ir.string_field(value, "tool_use_id"))
      use content <- result.try(ir.required(value, "content"))
      Ok(ir.ToolResult(
        id,
        content,
        ir.extras(value, ["type", "tool_use_id", "content"]),
      ))
    }
    "thinking" -> {
      use thinking <- result.try(ir.string_field(value, "thinking"))
      use signature <- result.try(ir.optional_string(value, "signature"))
      let known = case signature {
        Some(_) -> ["type", "thinking", "signature"]
        None -> ["type", "thinking"]
      }
      Ok(ir.Thinking(thinking, signature, ir.extras(value, known)))
    }
    _ -> Ok(ir.Unknown(value))
  }
}

fn encode_block(
  block: ir.Content,
  origin: ir.Origin,
) -> Result(ir.Value, String) {
  case block {
    ir.Text(_, [_, ..]) if origin == ir.Openai ->
      Error("unsupported OpenAI text extensions in Anthropic translation")
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
    ir.ToolCall(_, _, _, _, [_, ..]) if origin == ir.Openai ->
      Error("unsupported OpenAI tool extensions in Anthropic translation")
    ir.ToolCall(id, name, input, _, extras) ->
      Ok(
        ir.Object(list.append(
          [
            #("type", ir.String("tool_use")),
            #("id", ir.String(id)),
            #("name", ir.String(name)),
            #("input", input),
          ],
          extras,
        )),
      )
    ir.ToolResult(_, _, [_, ..]) if origin == ir.Openai ->
      Error(
        "unsupported OpenAI tool result extensions in Anthropic translation",
      )
    ir.ToolResult(id, content, extras) ->
      Ok(
        ir.Object(list.append(
          [
            #("type", ir.String("tool_result")),
            #("tool_use_id", ir.String(id)),
            #("content", content),
          ],
          extras,
        )),
      )
    ir.Thinking(text, signature, extras) ->
      Ok(
        ir.Object(list.append(
          ir.with_optional(
            [
              #("type", ir.String("thinking")),
              #("thinking", ir.String(text)),
            ],
            "signature",
            ir.option_string(signature),
          ),
          extras,
        )),
      )
    ir.Unknown(_) if origin == ir.Openai ->
      Error("unsupported OpenAI content block in Anthropic translation")
    ir.Unknown(value) -> Ok(value)
  }
}

pub fn decode_response(body: String) -> Result(ir.Response, String) {
  use root <- result.try(ir.parse(body))
  use _ <- result.try(ir.as_object(root))
  use _ <- result.try(case ir.field(root, "type") {
    Some(ir.String("message")) | None -> Ok(Nil)
    _ -> Error("unsupported Anthropic response type")
  })
  use _ <- result.try(case ir.field(root, "role") {
    Some(ir.String("assistant")) | None -> Ok(Nil)
    _ -> Error("unsupported Anthropic response role")
  })
  use id <- result.try(ir.string_field(root, "id"))
  use model <- result.try(ir.string_field(root, "model"))
  use content <- result.try(ir.required(root, "content"))
  use content <- result.try(ir.as_array(content))
  use blocks <- result.try(list.try_map(content, decode_block))
  use stop_reason <- result.try(ir.optional_string(root, "stop_reason"))
  let usage = case ir.field(root, "usage") {
    Some(value) -> decode_usage(value) |> result.map(Some)
    None -> Ok(None)
  }
  use usage <- result.try(usage)
  Ok(ir.Response(
    id,
    model,
    blocks,
    False,
    stop_reason,
    usage,
    [],
    [],
    ir.extras(root, [
      "id",
      "model",
      "content",
      "stop_reason",
      "usage",
      "type",
      "role",
    ]),
    ir.Anthropic,
  ))
}

pub fn encode_response(response: ir.Response) -> Result(String, String) {
  use _ <- result.try(
    case
      response.origin,
      response.message_extensions,
      response.choice_extensions
    {
      ir.Openai, [_, ..], _ ->
        Error("unsupported OpenAI message extensions in Anthropic translation")
      ir.Openai, _, [_, ..] ->
        Error("unsupported OpenAI choice extensions in Anthropic translation")
      _, _, _ -> Ok(Nil)
    },
  )
  use _ <- result.try(case response.origin, response.usage {
    ir.Openai, Some(usage) ->
      case usage.extensions {
        [] -> Ok(Nil)
        [#("total_tokens", ir.Integer(total))]
          if total == usage.input_tokens + usage.output_tokens
        -> Ok(Nil)
        _ ->
          Error("unsupported OpenAI usage extensions in Anthropic translation")
      }
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case response.origin, response.stop_reason {
    ir.Openai, Some("end_turn")
    | ir.Openai, Some("tool_use")
    | ir.Openai, Some("max_tokens")
    | ir.Openai, None
    -> Ok(Nil)
    ir.Openai, Some(_) ->
      Error("unsupported OpenAI finish reason in Anthropic translation")
    _, _ -> Ok(Nil)
  })
  use content <- result.try(
    list.try_map(response.content, fn(block) {
      encode_block(block, response.origin)
    }),
  )
  let fields = [
    #("type", ir.String("message")),
    #("role", ir.String("assistant")),
    #("id", ir.String(response.id)),
    #("model", ir.String(response.model)),
    #("content", ir.Array(content)),
    #("stop_reason", case response.stop_reason {
      Some(reason) -> ir.String(reason)
      None -> ir.Null
    }),
  ]
  let fields =
    ir.with_optional(fields, "usage", case response.usage {
      Some(usage) if response.origin == ir.Openai ->
        Some(encode_usage(ir.Usage(..usage, extensions: [])))
      Some(usage) -> Some(encode_usage(usage))
      None -> None
    })
  use fields <- result.try(case response.origin, response.extensions {
    ir.Openai, [_, ..] ->
      Error("unsupported OpenAI response extensions in Anthropic translation")
    _, _ -> Ok(list.append(fields, response.extensions))
  })
  Ok(ir.stringify(ir.Object(fields)))
}

pub fn decode_usage(value: ir.Value) -> Result(ir.Usage, String) {
  use input <- result.try(ir.required(value, "input_tokens"))
  use input <- result.try(ir.as_int(input))
  use output <- result.try(ir.required(value, "output_tokens"))
  use output <- result.try(ir.as_int(output))
  Ok(ir.Usage(
    input,
    output,
    ir.extras(value, ["input_tokens", "output_tokens"]),
  ))
}

pub fn encode_usage(usage: ir.Usage) -> ir.Value {
  ir.Object(list.append(
    [
      #("input_tokens", ir.Integer(usage.input_tokens)),
      #("output_tokens", ir.Integer(usage.output_tokens)),
    ],
    usage.extensions,
  ))
}

/// Fields that have no representation in the target dialect must not disappear.
fn merge_extensions(
  fields: List(#(String, ir.Value)),
  extras: List(#(String, ir.Value)),
  origin: ir.Origin,
) -> Result(List(#(String, ir.Value)), String) {
  case origin {
    ir.Openai -> {
      use converted <- result.try(list.try_map(extras, openai_option))
      Ok(list.append(fields, converted))
    }
    _ -> Ok(list.append(fields, extras))
  }
}

fn openai_option(
  entry: #(String, ir.Value),
) -> Result(#(String, ir.Value), String) {
  case entry {
    #("temperature", _) | #("top_p", _) -> Ok(entry)
    #("stop", ir.String(stop)) ->
      Ok(#("stop_sequences", ir.Array([ir.String(stop)])))
    #("stop", ir.Array(stops)) -> Ok(#("stop_sequences", ir.Array(stops)))
    #("tools", ir.Array(tools)) ->
      list.try_map(tools, fn(tool) {
        use _ <- result.try(case ir.extras(tool, ["type", "function"]) {
          [] -> Ok(Nil)
          _ -> Error("unsupported OpenAI tool definition extensions")
        })
        use kind <- result.try(ir.string_field(tool, "type"))
        use _ <- result.try(case kind {
          "function" -> Ok(Nil)
          _ -> Error("unsupported OpenAI tool type")
        })
        use function <- result.try(ir.required(tool, "function"))
        use _ <- result.try(
          case ir.extras(function, ["name", "description", "parameters"]) {
            [] -> Ok(Nil)
            _ -> Error("unsupported OpenAI function definition extensions")
          },
        )
        use name <- result.try(ir.string_field(function, "name"))
        use schema <- result.try(ir.required(function, "parameters"))
        let fields =
          ir.with_optional(
            [
              #("name", ir.String(name)),
              #("input_schema", schema),
            ],
            "description",
            ir.field(function, "description"),
          )
        Ok(ir.Object(fields))
      })
      |> result.map(fn(tools) { #("tools", ir.Array(tools)) })
    #("tool_choice", ir.String("auto")) ->
      Ok(#("tool_choice", ir.Object([#("type", ir.String("auto"))])))
    #("tool_choice", ir.String("required")) ->
      Ok(#("tool_choice", ir.Object([#("type", ir.String("any"))])))
    #("tool_choice", ir.Object(fields)) -> {
      let value = ir.Object(fields)
      use kind <- result.try(ir.string_field(value, "type"))
      use _ <- result.try(case kind {
        "function" -> Ok(Nil)
        _ -> Error("unsupported OpenAI tool choice")
      })
      use function <- result.try(ir.required(value, "function"))
      use name <- result.try(ir.string_field(function, "name"))
      use _ <- result.try(case ir.extras(value, ["type", "function"]) {
        [] -> Ok(Nil)
        _ -> Error("unsupported OpenAI tool choice extensions")
      })
      use _ <- result.try(case ir.extras(function, ["name"]) {
        [] -> Ok(Nil)
        _ -> Error("unsupported OpenAI named tool choice extensions")
      })
      Ok(#(
        "tool_choice",
        ir.Object([
          #("type", ir.String("tool")),
          #("name", ir.String(name)),
        ]),
      ))
    }
    #(key, _) ->
      Error(
        "unsupported OpenAI request extension in Anthropic translation: " <> key,
      )
  }
}
