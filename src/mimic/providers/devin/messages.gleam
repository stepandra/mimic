/// F24 Messages construction. Buffered and SSE share this exact ordering rule.
/// Native decoding, HTTP EOF and cancellation remain in the existing codecs.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/anthropic
import mimic/ir
import mimic/providers/devin/response

pub const max_bytes = 8_388_608

pub const max_events = 16_384

pub const max_blocks = 256

/// One supported subset for BOTH serializers. This leaves room below the
/// shared Claude codec's 1 MiB event limit even after SSE envelopes/escaping;
/// bounded tool JSON is emitted as one complete fragment, not a guessed prefix.
pub const max_response_bytes = 524_288

type Part {
  TextPart(String)
  ThinkingPart(String)
  ToolPart(String)
}

pub opaque type Builder {
  Builder(
    id: String,
    model: String,
    // Reversed logical blocks. Only a NEW tool creates a slot. Later fragments
    // fill that first-seen slot, never reopen it or split the current text run.
    parts: List(Part),
    tools: List(response.ToolDelta),
    signature: BitArray,
    signature_type: String,
    usage: Option(ir.Usage),
    reason: Option(Int),
    bytes: Int,
    events: Int,
    stopped: Bool,
  )
}

pub fn new(id: String, model: String) -> Result(Builder, String) {
  use _ <- result.try(ensure(
    id != ""
      && model != ""
      && string.byte_size(id) <= 1024
      && string.byte_size(model) <= 1024,
    "invalid Devin Messages identity",
  ))
  Ok(Builder(id, model, [], [], <<>>, "", None, None, 0, 0, False))
}

pub fn push(
  builder: Builder,
  event: response.Event,
) -> Result(Builder, String) {
  use _ <- result.try(ensure(
    !builder.stopped && builder.events < max_events,
    "Devin Messages terminal/event limit",
  ))
  let builder = Builder(..builder, events: builder.events + 1)
  use next <- result.try(case event {
    response.Text(text) -> {
      use builder <- result.try(retain(builder, string.byte_size(text)))
      let parts = case builder.parts {
        [TextPart(previous), ..rest] -> [TextPart(previous <> text), ..rest]
        _ -> [TextPart(text), ..builder.parts]
      }
      Ok(Builder(..builder, parts: parts))
    }
    response.ThinkingDelta(text) -> {
      use builder <- result.try(retain(builder, string.byte_size(text)))
      let parts = case builder.parts {
        [ThinkingPart(previous), ..rest] -> [
          ThinkingPart(previous <> text),
          ..rest
        ]
        _ -> [ThinkingPart(text), ..builder.parts]
      }
      use _ <- result.try(ensure(
        list.count(parts, fn(part) {
          case part {
            ThinkingPart(_) -> True
            _ -> False
          }
        })
          == 1,
        "ambiguous Devin Messages thinking association",
      ))
      Ok(Builder(..builder, parts: parts))
    }
    response.Tool(delta) -> append_tool(builder, delta)
    response.SignatureDelta(bytes) -> {
      use builder <- result.try(retain(builder, bit_array.byte_size(bytes)))
      Ok(Builder(..builder, signature: <<builder.signature:bits, bytes:bits>>))
    }
    response.SignatureType(kind) -> {
      use _ <- result.try(ensure(
        kind == "anthropic"
          && { builder.signature_type == "" || builder.signature_type == kind },
        "unsupported or conflicting Devin Messages signature source",
      ))
      Ok(Builder(..builder, signature_type: kind))
    }
    response.Usage(usage) -> {
      // Native decoder already merges cumulative accounting. Keep its last
      // snapshot; partial/estimated snapshots cannot complete a Message.
      use builder <- result.try(retain(
        builder,
        string.byte_size(ir.stringify(ir.Object(usage.extensions))),
      ))
      Ok(Builder(..builder, usage: Some(usage)))
    }
    response.Reason(reason) -> {
      use _ <- result.try(ensure(
        list.contains([1, 2, 3, 4, 10], reason)
          && { builder.reason == None || builder.reason == Some(reason) },
        "unsupported or conflicting Devin Messages stop reason",
      ))
      Ok(Builder(..builder, reason: Some(reason)))
    }
    response.Stop -> Ok(Builder(..builder, stopped: True))
  })
  use _ <- result.try(ensure(
    list.length(next.parts) <= max_blocks,
    "Devin Messages block limit",
  ))
  Ok(next)
}

fn retain(builder: Builder, bytes: Int) -> Result(Builder, String) {
  use _ <- result.try(ensure(
    builder.bytes + bytes <= max_bytes,
    "Devin Messages aggregate retained byte limit",
  ))
  Ok(Builder(..builder, bytes: builder.bytes + bytes))
}

fn append_tool(
  builder: Builder,
  delta: response.ToolDelta,
) -> Result(Builder, String) {
  use _ <- result.try(ensure(
    delta.id != ""
      && !delta.custom
      && delta.invalid_json == <<>>
      && delta.invalid_json_error == "",
    "unsupported Devin Messages custom or invalid-JSON tool",
  ))
  use builder <- result.try(retain(
    builder,
    string.byte_size(delta.id)
      + string.byte_size(delta.name)
      + bit_array.byte_size(delta.arguments),
  ))
  case list.any(builder.tools, fn(tool) { tool.id == delta.id }) {
    False -> {
      use _ <- result.try(ensure(
        list.length(builder.tools) < 128,
        "Devin Messages tool limit",
      ))
      Ok(
        Builder(..builder, tools: [delta, ..builder.tools], parts: [
          ToolPart(delta.id),
          ..builder.parts
        ]),
      )
    }
    True -> {
      use tools <- result.try(
        list.try_map(builder.tools, fn(tool) {
          case tool.id == delta.id {
            False -> Ok(tool)
            True -> {
              use _ <- result.try(ensure(
                delta.name == "" || tool.name == "" || tool.name == delta.name,
                "conflicting Devin Messages tool name",
              ))
              Ok(
                response.ToolDelta(
                  ..tool,
                  name: case delta.name {
                    "" -> tool.name
                    name -> name
                  },
                  arguments: <<tool.arguments:bits, delta.arguments:bits>>,
                ),
              )
            }
          }
        }),
      )
      Ok(Builder(..builder, tools: tools))
    }
  }
}

/// The lifecycle supplies Stop only after Connect EOS AND clean HTTP EOF.
/// No complete response, usage zeros or unsigned thinking are invented here.
pub fn finish(builder: Builder) -> Result(ir.Response, String) {
  use _ <- result.try(ensure(builder.stopped, "Devin Messages missing Stop"))
  use usage <- result.try(
    option.to_result(builder.usage, "Devin Messages requires exact usage")
    |> result.try(qualify_usage),
  )
  let has_thinking =
    list.any(builder.parts, fn(part) {
      case part {
        ThinkingPart(_) -> True
        _ -> False
      }
    })
  use signature <- result.try(case has_thinking {
    True ->
      qualify_signature(builder.signature, builder.signature_type)
      |> result.map(Some)
    False -> {
      use _ <- result.try(ensure(
        builder.signature == <<>> && builder.signature_type == "",
        "Devin signature without thinking association",
      ))
      Ok(None)
    }
  })
  use content <- result.try(
    builder.parts
    |> list.reverse
    |> list.try_map(fn(part) {
      case part {
        TextPart(text) -> Ok(ir.Text(text, []))
        ThinkingPart(text) -> Ok(ir.Thinking(text, signature, []))
        ToolPart(id) -> {
          use tool <- result.try(
            list.find(builder.tools, fn(tool) { tool.id == id })
            |> result.replace_error("missing Devin Messages tool"),
          )
          use _ <- result.try(ensure(
            tool.name != "",
            "incomplete Devin Messages tool name",
          ))
          use input <- result.try(
            bit_array.to_string(tool.arguments)
            |> result.replace_error("invalid Devin Messages tool UTF-8")
            |> result.try(fn(text) {
              ir.parse_bounded(text, max_bytes, 128, 65_536)
            }),
          )
          use _ <- result.try(ir.as_object(input))
          Ok(ir.ToolCall(tool.id, tool.name, input, None, []))
        }
      }
    }),
  )
  let reason = case builder.reason {
    Some(1) | Some(3) -> "max_tokens"
    Some(10) -> "tool_use"
    _ -> "end_turn"
  }
  use _ <- result.try(ensure(
    reason != "tool_use" || builder.tools != [],
    "Devin tool stop without a tool call",
  ))
  Ok(ir.Response(
    id: builder.id,
    model: builder.model,
    content: content,
    content_is_string: False,
    stop_reason: Some(reason),
    usage: Some(usage),
    message_extensions: [],
    choice_extensions: [],
    extensions: ir.with_optional(
      [#("stop_sequence", ir.Null)],
      "devin_stop_reason",
      ir.option_int(builder.reason),
    ),
    origin: ir.Anthropic,
  ))
}

/// Preserve only the explicit Anthropic form recognized by the CURRENT native
/// history codec. This is source typing, not cryptographic verification.
/// Opaque OpenAI/sealed values need a separate extension-aware route: reject.
pub fn qualify_signature(
  bytes: BitArray,
  kind: String,
) -> Result(String, String) {
  case kind, bit_array.to_string(bytes) {
    "anthropic", Ok("CAQS" <> rest) if rest != "" -> Ok("CAQS" <> rest)
    "anthropic", Ok("CAIS" <> rest) if rest != "" -> Ok("CAIS" <> rest)
    _, _ -> Error("unsigned or unsupported Devin Messages thinking signature")
  }
}

pub fn qualify_usage(value: ir.Usage) -> Result(ir.Usage, String) {
  use _ <- result.try(ensure(
    value.input_tokens >= 0 && value.output_tokens >= 0,
    "negative Devin Messages usage",
  ))
  use _ <- result.try(
    list.try_each(value.extensions, fn(field) {
      case field {
        #("devin_input_known", ir.Boolean(True))
        | #("devin_output_known", ir.Boolean(True)) -> Ok(Nil)
        #("cache_write_tokens", ir.Integer(n))
          | #("cached_input_tokens", ir.Integer(n))
          | #("devin_status_code", ir.Integer(n))
          if n >= 0
        -> Ok(Nil)
        #("devin_model", ir.String(_)) | #("devin_request_id", ir.String(_)) ->
          Ok(Nil)
        _ -> Error("partial, estimated or unsupported Devin Messages usage")
      }
    }),
  )
  Ok(
    ir.Usage(value.input_tokens, value.output_tokens, [
      #("devin_usage_source", ir.String("native_accounting")),
      #("devin_usage", ir.Object(value.extensions)),
    ]),
  )
}

/// Clean HTTP EOF is a caller precondition, as in runtime.execute.
pub fn buffered(
  bytes: BitArray,
  id: String,
  model: String,
) -> Result(String, String) {
  use _ <- result.try(ensure(
    bit_array.byte_size(bytes) <= max_bytes,
    "Devin Messages native byte limit",
  ))
  use #(decoder, events) <- result.try(response.feed(response.new(), bytes))
  use _ <- result.try(response.finish(decoder))
  use builder <- result.try(new(id, model))
  use builder <- result.try(list.try_fold(events, builder, push))
  use decoded <- result.try(finish(builder))
  encode_response(decoded)
}

/// Public IR boundary is also strict: no permissive Anthropic observer decides
/// whether unknown/unsigned blocks or absent usage are representable.
pub fn encode_response(decoded: ir.Response) -> Result(String, String) {
  use _ <- result.try(ensure(
    decoded.id != ""
      && decoded.model != ""
      && string.byte_size(decoded.id) <= 1024
      && string.byte_size(decoded.model) <= 1024
      && list.length(decoded.content) <= max_blocks
      && decoded.message_extensions == []
      && decoded.choice_extensions == [],
    "invalid Devin Messages response",
  ))
  use _ <- result.try(
    list.try_each(decoded.content, fn(block) {
      case block {
        ir.Text(_, []) -> Ok(Nil)
        ir.ToolCall(id, name, ir.Object(_), None, [])
          if id != "" && name != ""
        -> Ok(Nil)
        ir.Thinking(_, Some(signature), []) ->
          qualify_signature(bit_array.from_string(signature), "anthropic")
          |> result.replace(Nil)
        _ -> Error("unsupported or unsigned Devin Messages content")
      }
    }),
  )
  use usage <- result.try(option.to_result(
    decoded.usage,
    "Devin Messages requires exact usage",
  ))
  // finish() marks qualified counters; the public boundary also accepts raw
  // native accounting but does not reinterpret arbitrary vendor extensions.
  use usage <- result.try(case usage.extensions {
    [
      #("devin_usage_source", ir.String("native_accounting")),
      #("devin_usage", ir.Object(fields)),
    ] ->
      qualify_usage(ir.Usage(usage.input_tokens, usage.output_tokens, fields))
    _ -> qualify_usage(usage)
  })
  use _ <- result.try(ensure(
    list.contains(
      [Some("end_turn"), Some("max_tokens"), Some("tool_use")],
      decoded.stop_reason,
    )
      && {
      decoded.stop_reason != Some("tool_use")
      || list.any(decoded.content, fn(part) {
        case part {
          ir.ToolCall(..) -> True
          _ -> False
        }
      })
    },
    "unsupported Devin Messages stop reason",
  ))
  use _ <- result.try(
    list.try_each(decoded.extensions, fn(field) {
      case field {
        #("stop_sequence", ir.Null) -> Ok(Nil)
        #("devin_stop_reason", ir.Integer(n)) if n >= 0 -> Ok(Nil)
        _ -> Error("unsupported Devin Messages response extension")
      }
    }),
  )
  use body <- result.try(anthropic.encode_response(
    ir.Response(..decoded, usage: Some(usage), origin: ir.Anthropic),
  ))
  use _ <- result.try(ensure(
    string.byte_size(body) <= max_response_bytes,
    "Devin Messages encoded byte limit",
  ))
  // Standalone tool-input limits do not include the Message/content/tool
  // envelope. Validate the complete document at the shared boundary so JSON
  // and SSE have the same structural acceptance budget, not just equal bytes.
  use _ <- result.try(ir.parse(body))
  Ok(body)
}

pub fn ensure(ok: Bool, error: String) -> Result(Nil, String) {
  case ok {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] | ["help"] ->
      Ok("Devin F24: bounded Messages JSON/delayed SSE; remote gate closed")
    _ -> Error("unsupported Devin Messages CLI operation")
  }
}
