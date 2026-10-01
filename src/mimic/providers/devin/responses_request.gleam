/// F25's explicit Responses -> existing native request contract. This is not a
/// Chat JSON rename, and the shared Responses parser is not an entitlement gate.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses as shared
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/models
import mimic/providers/devin/request as wire

pub const max_bytes = 8_388_608

pub const max_input_items = 256

/// Effective client projection controls from admitted input, not upstream
/// defaults guessed from output. False parallelism is checked at finalization.
pub opaque type Settings {
  Settings(
    tools: List(ir.Value),
    tool_choice: String,
    parallel_tool_calls: Bool,
    instructions: Option(String),
    max_output_tokens: Option(Int),
    temperature: ir.Value,
  )
}

pub fn validate(
  request: c.Request,
  configured: List(models.Model),
) -> Result(Nil, String) {
  use model <- result.try(models.resolve(configured, request.model))
  use _ <- result.try(ensure(
    request.provider == "devin"
      && request.auth_mode == "session_token"
      && request.protocol == "openai-responses"
      && request.operation == "generate"
      && request.session != ""
      && request.pinned_account == None
      && list.all(request.required, fn(cap) {
      cap == c.Buffer
      || cap == c.Stream
      || cap == c.Tools
      || { cap == c.Images && model.images }
    }),
    "unsupported Devin Responses request scope",
  ))
  use input <- result.try(decode(request.body))
  use _ <- result.try(ensure(
    input.model == request.model
      && { input.stream == Some(True) } == { request.mode == c.Streaming },
    "Devin Responses model or stream mismatch",
  ))
  use _ <- result.try(case input.max_tokens {
    None -> Ok(Nil)
    Some(n) ->
      ensure(n > 0 && n <= model.max_tokens, "invalid Responses token limit")
  })
  // Pure preflight through the CURRENT native codec, before lease/credentials.
  use _ <- result.try(wire.encode_configured(
    input,
    "synthetic-f25-preflight",
    wire.Identity(
      "linux",
      string.repeat("0", 732),
      "00000000-0000-4000-8000-000000000025",
      "00000000-0000-4000-8000-000000000026",
    ),
    configured,
  ))
  Ok(Nil)
}

pub fn decode(source: String) -> Result(ir.Request, String) {
  decode_with_settings(source) |> result.map(fn(pair) { pair.0 })
}

pub fn decode_with_settings(
  source: String,
) -> Result(#(ir.Request, Settings), String) {
  use document <- result.try(ir.parse_bounded(source, max_bytes, 128, 65_536))
  // Bound client item count BEFORE the shared pairer's repeated call-ID scans.
  // Root body bytes alone still permit thousands of small distinct calls.
  use _ <- result.try(case ir.field(document, "input") {
    Some(ir.Array(items)) ->
      ensure(
        list.length(items) <= max_input_items,
        "Devin Responses input item limit",
      )
    _ -> Ok(Nil)
  })
  use request <- result.try(shared.request_from_value(document))
  use _ <- result.try(
    only(document, [
      "model", "input", "instructions", "stream", "max_output_tokens",
      "temperature", "tools", "store", "previous_response_id", "tool_choice",
      "parallel_tool_calls",
    ]),
  )
  use _ <- result.try(ensure(
    request.previous_response_id == None,
    "Devin Responses continuation is unsupported",
  ))
  use _ <- result.try(case ir.field(document, "store") {
    None | Some(ir.Boolean(False)) -> Ok(Nil)
    _ -> Error("Devin Responses storage is unsupported")
  })
  // Only complete history in this request can pair a tool result. No S6 receipt,
  // previous response lookup or server cursor is inferred from projection.
  use _ <- result.try(shared.pair_input(request, []))
  use turns <- result.try(case ir.field(document, "input") {
    Some(ir.String(text)) -> Ok([turn("user", [ir.Text(text, [])])])
    Some(ir.Array(items)) -> list.try_map(items, input_item)
    _ -> Error("Devin Responses requires explicit input")
  })
  use maximum <- result.try(ir.optional_int(document, "max_output_tokens"))
  use _ <- result.try(case maximum {
    Some(n) -> ensure(n > 0, "invalid Responses max_output_tokens")
    None -> Ok(Nil)
  })
  use tools <- result.try(case ir.field(document, "tools") {
    None -> Ok([])
    Some(ir.Array(tools)) -> {
      use _ <- result.try(ensure(
        list.length(tools) <= 128,
        "Devin Responses tool definition limit",
      ))
      use tools <- result.try(list.try_map(tools, input_tool))
      Ok(tools)
    }
    _ -> Error("invalid Devin Responses tools")
  })
  let names = list.map(tools, fn(tool) { ir.field(tool, "name") })
  use _ <- result.try(ensure(
    list.unique(names) == names,
    "duplicate Devin Responses tool definition",
  ))
  let native_tools = case tools {
    [] -> []
    _ -> [#("tools", ir.Array(list.map(tools, native_tool)))]
  }
  let extensions =
    ir.with_optional(
      native_tools,
      "temperature",
      ir.field(document, "temperature"),
    )
  use instructions <- result.try(ir.optional_string(document, "instructions"))
  use choice <- result.try(case ir.field(document, "tool_choice") {
    None | Some(ir.String("auto")) -> Ok("auto")
    Some(ir.String("none")) if tools == [] -> Ok("none")
    _ -> Error("unsupported Devin Responses tool_choice")
  })
  use parallel <- result.try(ir.optional_bool(
    document,
    "parallel_tool_calls",
    True,
  ))
  let settings =
    Settings(
      tools,
      choice,
      parallel,
      instructions,
      maximum,
      option.unwrap(ir.field(document, "temperature"), ir.Decimal(1.0)),
    )
  Ok(#(
    ir.Request(
      model: request.model,
      system: option_string(instructions),
      system_role: "system",
      turns: turns,
      max_tokens: maximum,
      token_limit_field: "max_output_tokens",
      stream: Some(request.stream),
      extensions: extensions,
      origin: ir.Openai,
    ),
    settings,
  ))
}

pub fn settings(source: String) -> Result(Settings, String) {
  decode_with_settings(source) |> result.map(fn(pair) { pair.1 })
}

pub fn response_fields(settings: Settings) -> List(#(String, ir.Value)) {
  [
    #("tools", ir.Array(settings.tools)),
    #("tool_choice", ir.String(settings.tool_choice)),
    #("parallel_tool_calls", ir.Boolean(settings.parallel_tool_calls)),
    #(
      "instructions",
      option.unwrap(option_string(settings.instructions), ir.Null),
    ),
    #(
      "max_output_tokens",
      option.unwrap(ir.option_int(settings.max_output_tokens), ir.Null),
    ),
    #("temperature", settings.temperature),
    // Exact CURRENT native encoder default, not measured upstream sampling.
    #("top_p", ir.Decimal(0.949999988079071)),
    #("metadata", ir.Null),
  ]
}

pub fn permits_tool(settings: Settings, name: String) -> Bool {
  settings.tool_choice != "none"
  && list.any(settings.tools, fn(tool) {
    ir.field(tool, "name") == Some(ir.String(name))
  })
}

pub fn permits_call_count(settings: Settings, count: Int) -> Bool {
  settings.parallel_tool_calls || count <= 1
}

fn native_tool(tool: ir.Value) -> ir.Value {
  ir.Object([
    #("type", ir.String("function")),
    #("function", ir.Object(ir.extras(tool, ["type", "strict"]))),
  ])
}

fn option_string(value) {
  case value {
    None -> None
    Some(text) -> Some(ir.String(text))
  }
}

fn turn(role: String, content: List(ir.Content)) -> ir.Turn {
  ir.Turn(role, content, False, [])
}

fn input_item(value: ir.Value) -> Result(ir.Turn, String) {
  use _ <- result.try(ir.as_object(value))
  use _ <- result.try(local_identity(value))
  let kind = case ir.field(value, "type") {
    None -> "message"
    Some(ir.String(kind)) -> kind
    _ -> ""
  }
  case kind {
    "message" -> {
      use _ <- result.try(
        only(value, ["id", "type", "role", "content", "status"]),
      )
      use role <- result.try(ir.string_field(value, "role"))
      use _ <- result.try(ensure(
        role == "user" || role == "assistant",
        "unsupported Devin Responses message role",
      ))
      use content <- result.try(ir.required(value, "content"))
      use content <- result.try(case content {
        ir.String(text) -> Ok([ir.Text(text, [])])
        ir.Array(parts) ->
          list.try_map(parts, fn(part) { input_content(part, role) })
        _ -> Error("invalid Devin Responses message content")
      })
      Ok(turn(role, content))
    }
    "function_call" -> {
      use _ <- result.try(
        only(value, ["id", "type", "call_id", "name", "arguments", "status"]),
      )
      use id <- result.try(shared.nonempty_string(value, "call_id"))
      use name <- result.try(shared.nonempty_string(value, "name"))
      use raw <- result.try(ir.string_field(value, "arguments"))
      use arguments <- result.try(ir.parse_bounded(raw, max_bytes, 128, 65_536))
      use _ <- result.try(ir.as_object(arguments))
      Ok(turn("assistant", [ir.ToolCall(id, name, arguments, Some(raw), [])]))
    }
    "function_call_output" -> {
      use _ <- result.try(
        only(value, ["id", "type", "call_id", "output", "status"]),
      )
      use id <- result.try(shared.nonempty_string(value, "call_id"))
      use output <- result.try(ir.string_field(value, "output"))
      Ok(turn("tool", [ir.ToolResult(id, ir.String(output), [])]))
    }
    // Only an explicit OpenAI envelope may become native signed history.
    // Unknown/Anthropic/sealed signatures are never guessed or discarded.
    "reasoning" -> {
      use _ <- result.try(
        only(value, ["id", "type", "summary", "encrypted_content", "status"]),
      )
      use summary <- result.try(ir.required(value, "summary"))
      use summary <- result.try(ir.as_array(summary))
      use text <- result.try(
        list.try_map(summary, fn(part) {
          use _ <- result.try(only(part, ["type", "text"]))
          use _ <- result.try(shared.expect_string(part, "type", "summary_text"))
          ir.string_field(part, "text")
        }),
      )
      use encrypted <- result.try(ir.optional_string(value, "encrypted_content"))
      use _ <- result.try(case encrypted {
        None -> Ok(Nil)
        Some(text) ->
          qualify_encrypted(bit_array.from_string(text), "openai")
          |> result.replace(Nil)
      })
      use _ <- result.try(ensure(
        list.length(text) <= 1,
        "ambiguous Devin Responses reasoning history",
      ))
      Ok(
        turn("assistant", [
          ir.Thinking(string.join(text, ""), encrypted, []),
        ]),
      )
    }
    _ -> Error("unsupported Devin Responses input item")
  }
}

fn local_identity(value: ir.Value) -> Result(Nil, String) {
  use id <- result.try(ir.optional_string(value, "id"))
  use _ <- result.try(ensure(id != Some(""), "empty Responses history item id"))
  case ir.field(value, "status") {
    None | Some(ir.String("completed")) -> Ok(Nil)
    _ -> Error("unsupported Responses history status")
  }
}

fn input_content(value: ir.Value, role: String) -> Result(ir.Content, String) {
  use kind <- result.try(ir.string_field(value, "type"))
  case kind, role {
    "input_text", "user" | "output_text", "assistant" -> {
      use _ <- result.try(only(value, ["type", "text", "annotations"]))
      use _ <- result.try(case ir.field(value, "annotations") {
        None | Some(ir.Array([])) -> Ok(Nil)
        _ -> Error("unsupported Responses input annotations")
      })
      use text <- result.try(ir.string_field(value, "text"))
      Ok(ir.Text(text, []))
    }
    "input_image", "user" -> {
      use _ <- result.try(only(value, ["type", "image_url"]))
      use url <- result.try(shared.nonempty_string(value, "image_url"))
      // The existing native codec checks the data URL and never fetches a URL.
      Ok(
        ir.Unknown(
          ir.Object([
            #("type", ir.String("image_url")),
            #("image_url", ir.Object([#("url", ir.String(url))])),
          ]),
        ),
      )
    }
    _, _ -> Error("unsupported Devin Responses content or association")
  }
}

fn input_tool(value: ir.Value) -> Result(ir.Value, String) {
  use _ <- result.try(
    only(value, ["type", "name", "description", "parameters", "strict"]),
  )
  use _ <- result.try(shared.expect_string(value, "type", "function"))
  use _ <- result.try(ensure(
    ir.field(value, "strict") == Some(ir.Boolean(False)),
    "Devin Responses function tools require explicit strict:false",
  ))
  use name <- result.try(shared.nonempty_string(value, "name"))
  use parameters <- result.try(ir.required(value, "parameters"))
  use _ <- result.try(ir.as_object(parameters))
  use description <- result.try(ir.optional_string(value, "description"))
  Ok(
    ir.Object(ir.with_optional(
      [
        #("type", ir.String("function")),
        #("name", ir.String(name)),
        #("parameters", parameters),
        #("strict", ir.Boolean(False)),
      ],
      "description",
      option_string(description),
    )),
  )
}

/// Pinned CPA GPT validator's outer transport shape, NOT signature verification.
/// Preserve the exact string, without trimming, base64 re-encoding or prefixes.
pub fn qualify_encrypted(
  bytes: BitArray,
  kind: String,
) -> Result(String, String) {
  use _ <- result.try(ensure(
    bit_array.byte_size(bytes) <= max_bytes,
    "Responses encrypted_content byte limit",
  ))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("unsupported binary Responses reasoning"),
  )
  use _ <- result.try(ensure(
    kind == "openai" && string.starts_with(text, "gAAAA"),
    "unsupported Devin Responses reasoning signature source",
  ))
  use decoded <- result.try(
    bit_array.base64_url_decode(text)
    |> result.replace_error("invalid Responses encrypted_content encoding"),
  )
  let size = bit_array.byte_size(decoded)
  use _ <- result.try(ensure(
    size >= 73
      && { size - 57 } % 16 == 0
      && {
      bit_array.base64_url_encode(decoded, True) == text
      || bit_array.base64_url_encode(decoded, False) == text
    },
    "unsupported Responses encrypted_content shape",
  ))
  case decoded {
    <<128, _:bits>> -> Ok(text)
    _ -> Error("unsupported Responses encrypted_content version")
  }
}

pub fn only(value: ir.Value, fields: List(String)) -> Result(Nil, String) {
  use _ <- result.try(ir.as_object(value))
  ensure(ir.extras(value, fields) == [], "unsupported Devin Responses fields")
}

pub fn ensure(ok: Bool, error: String) -> Result(Nil, String) {
  case ok {
    True -> Ok(Nil)
    False -> Error(error)
  }
}
