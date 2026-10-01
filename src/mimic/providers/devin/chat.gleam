/// Devin native-event -> Chat projection, not a Connect or SSE parser.
/// Nonstandard native semantics use explicitly named/encoded Devin extensions.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/protocol/chat/stream as shared
import mimic/providers/contracts as c
import mimic/providers/devin/response

type Tool {
  Tool(
    index: Int,
    id: String,
    name: String,
    raw: BitArray,
    pending: BitArray,
    announced: Bool,
  )
}

pub opaque type State {
  State(
    id: String,
    model: String,
    created_seconds: Int,
    validator: shared.Stream,
    started: Bool,
    stopped: Bool,
    tools: List(Tool),
    tool_bytes: Int,
    reason: Option(Int),
  )
}

pub fn new(
  id: String,
  model: String,
  created_seconds: Int,
) -> Result(State, String) {
  use _ <- result.try(ensure(
    id != ""
      && model != ""
      && created_seconds >= 0
      && string.byte_size(id) <= 1024
      && string.byte_size(model) <= 1024,
    "invalid Devin Chat identity",
  ))
  Ok(State(
    id,
    model,
    created_seconds,
    shared.new_with_limits(16_777_216, 1, 128),
    False,
    False,
    [],
    0,
    None,
  ))
}

/// Inject this into client.new/native.project. A Stop is only supplied by the
/// native lifecycle after validated Connect EOS AND clean HTTP EOF.
pub fn encode(
  state: State,
  event: response.Event,
) -> Result(#(State, List(String)), String) {
  use _ <- result.try(ensure(!state.stopped, "Devin Chat event after terminal"))
  use #(state, prefix) <- result.try(start(state))
  use #(state, frames) <- result.try(project(state, event))
  Ok(#(state, list.append(prefix, frames)))
}

fn start(state: State) -> Result(#(State, List(String)), String) {
  case state.started {
    True -> Ok(#(state, []))
    False ->
      emit(State(..state, started: True), [
        chunk(state, [
          choice(ir.Object([#("role", ir.String("assistant"))]), None),
        ]),
      ])
  }
}

fn project(
  state: State,
  event: response.Event,
) -> Result(#(State, List(String)), String) {
  case event {
    response.Text(text) -> delta(state, [#("content", ir.String(text))])
    response.ThinkingDelta(text) ->
      delta(state, [#("reasoning_content", ir.String(text))])
    response.SignatureDelta(bytes) ->
      // Each delta is independently base64 encoded. Decode, then concatenate
      // bytes; concatenating base64 strings is not an equivalent operation.
      delta(state, [
        #(
          "devin_signature_delta",
          ir.String(bit_array.base64_encode(bytes, False)),
        ),
        #("devin_signature_encoding", ir.String("base64")),
      ])
    response.SignatureType(name) ->
      delta(state, [#("devin_signature_type", ir.String(name))])
    response.Tool(tool) -> tool_delta(state, tool)
    response.Usage(usage) -> {
      use usage <- result.try(project_usage(usage))
      emit(state, [
        shared.Event(
          ir.Object([
            #("id", ir.String(state.id)),
            #("object", ir.String("chat.completion.chunk")),
            #("model", ir.String(state.model)),
            #("created", ir.Integer(state.created_seconds)),
            #("choices", ir.Array([])),
            #("usage", usage),
          ]),
        ),
      ])
    }
    response.Reason(reason) -> {
      use _ <- result.try(ensure(
        list.contains([1, 2, 3, 4, 10, 11], reason)
          && { state.reason == None || state.reason == Some(reason) },
        "unsupported or conflicting Devin Chat stop reason",
      ))
      delta(State(..state, reason: Some(reason)), [
        #("devin_stop_reason", ir.Integer(reason)),
      ])
    }
    response.Stop -> finish(state)
  }
}

fn delta(
  state: State,
  fields: List(#(String, ir.Value)),
) -> Result(#(State, List(String)), String) {
  emit(state, [chunk(state, [choice(ir.Object(fields), None)])])
}

fn choice(delta: ir.Value, finish: Option(String)) -> ir.Value {
  ir.Object([
    #("index", ir.Integer(0)),
    #("delta", delta),
    #("finish_reason", case finish {
      None -> ir.Null
      Some(reason) -> ir.String(reason)
    }),
  ])
}

fn chunk(state: State, choices: List(ir.Value)) -> shared.Event {
  shared.Event(
    ir.Object([
      #("id", ir.String(state.id)),
      #("object", ir.String("chat.completion.chunk")),
      #("model", ir.String(state.model)),
      #("created", ir.Integer(state.created_seconds)),
      #("choices", ir.Array(choices)),
    ]),
  )
}

/// The shared API is a receiving validator, not a Devin encoder. Reuse its
/// document serialization and validation rather than pretending otherwise.
fn emit(
  state: State,
  events: List(shared.Event),
) -> Result(#(State, List(String)), String) {
  list.fold(events, Ok(#(state, [])), fn(acc, event) {
    use #(state, frames) <- result.try(acc)
    let frame = shared.encode_event(event)
    let batch =
      shared.feed_partial(state.validator, bit_array.from_string(frame), Ok)
    use validator <- result.try(batch.next)
    // ir.parse canonicalizes object-key order. Comparing the constructed
    // ordered field list with the parsed list is not semantic validation.
    use _ <- result.try(ensure(
      list.length(batch.events) == 1,
      "invalid Devin Chat projection",
    ))
    Ok(#(State(..state, validator: validator), list.append(frames, [frame])))
  })
}

fn tool_delta(
  state: State,
  delta: response.ToolDelta,
) -> Result(#(State, List(String)), String) {
  use _ <- result.try(ensure(
    delta.id != ""
      && delta.invalid_json == <<>>
      && delta.invalid_json_error == ""
      && !delta.custom,
    "unsupported Devin custom or invalid-JSON tool semantics",
  ))
  let existing = list.find(state.tools, fn(tool) { tool.id == delta.id })
  use tool <- result.try(case existing {
    Ok(tool) -> Ok(tool)
    Error(_) ->
      case list.length(state.tools) < 128 {
        True ->
          Ok(Tool(list.length(state.tools), delta.id, "", <<>>, <<>>, False))
        False -> Error("Devin Chat tool limit")
      }
  })
  use _ <- result.try(ensure(
    delta.name == "" || tool.name == "" || delta.name == tool.name,
    "conflicting Devin Chat tool name",
  ))
  let bytes = state.tool_bytes + bit_array.byte_size(delta.arguments)
  use _ <- result.try(ensure(bytes <= 8_388_608, "Devin Chat argument limit"))
  let tool =
    Tool(
      ..tool,
      name: case delta.name {
        "" -> tool.name
        name -> name
      },
      raw: <<tool.raw:bits, delta.arguments:bits>>,
      pending: <<tool.pending:bits, delta.arguments:bits>>,
    )
  use #(tool, fields) <- result.try(flush_tool(tool))
  let tools = case existing {
    Error(_) -> list.append(state.tools, [tool])
    Ok(_) ->
      list.map(state.tools, fn(previous) {
        case previous.id == tool.id {
          True -> tool
          False -> previous
        }
      })
  }
  let state = State(..state, tools: tools, tool_bytes: bytes)
  case fields {
    [] -> Ok(#(state, []))
    _ ->
      emit(state, [
        chunk(state, [
          choice(
            ir.Object([#("tool_calls", ir.Array([ir.Object(fields)]))]),
            None,
          ),
        ]),
      ])
  }
}

fn flush_tool(
  tool: Tool,
) -> Result(#(Tool, List(#(String, ir.Value))), String) {
  case tool.name {
    "" -> Ok(#(tool, []))
    _ -> {
      // Incomplete UTF-8 arguments wait for another delta. Full raw JSON is
      // validated at Stop; permanently invalid bytes can never yield DONE.
      let text = bit_array.to_string(tool.pending)
      let function = case text {
        Ok(text) -> [#("arguments", ir.String(text))]
        Error(_) -> []
      }
      let function = case tool.announced {
        True -> function
        False -> [#("name", ir.String(tool.name)), ..function]
      }
      let fields = case function {
        [] -> []
        _ -> [
          #("index", ir.Integer(tool.index)),
          #("function", ir.Object(function)),
        ]
      }
      let fields = case tool.announced {
        True -> fields
        False -> [
          #("id", ir.String(tool.id)),
          #("type", ir.String("function")),
          ..fields
        ]
      }
      Ok(#(
        Tool(..tool, announced: True, pending: case text {
          Ok(_) -> <<>>
          Error(_) -> tool.pending
        }),
        fields,
      ))
    }
  }
}

fn finish(state: State) -> Result(#(State, List(String)), String) {
  use _ <- result.try(
    list.try_each(state.tools, fn(tool) {
      use _ <- result.try(ensure(
        tool.announced && tool.pending == <<>>,
        "incomplete Devin Chat tool",
      ))
      use text <- result.try(
        bit_array.to_string(tool.raw)
        |> result.replace_error("invalid Devin tool UTF-8"),
      )
      ir.parse_bounded(text, 8_388_608, 128, 65_536)
      |> result.map(fn(_) { Nil })
    }),
  )
  use reason <- result.try(case state.reason {
    Some(1) | Some(3) -> Ok("length")
    Some(11) -> Ok("content_filter")
    Some(10) ->
      case state.tools {
        [] -> Error("Devin tool stop without tool calls")
        _ -> Ok("tool_calls")
      }
    Some(2) | Some(4) -> Ok("stop")
    None ->
      case state.tools {
        [] -> Ok("stop")
        _ -> Ok("tool_calls")
      }
    _ -> Error("unsupported Devin Chat stop reason")
  })
  use #(state, frames) <- result.try(
    emit(state, [
      chunk(state, [choice(ir.Object([]), Some(reason))]),
      shared.Done,
    ]),
  )
  use _ <- result.try(shared.finish(state.validator))
  Ok(#(State(..state, stopped: True), frames))
}

fn project_usage(usage: ir.Usage) -> Result(ir.Value, String) {
  use _ <- result.try(ensure(
    usage.input_tokens >= 0 && usage.output_tokens >= 0,
    "negative Devin Chat usage",
  ))
  use _ <- result.try(
    list.try_each(usage.extensions, fn(field) {
      case field {
        #("cache_write_tokens", ir.Integer(n))
          | #("cached_input_tokens", ir.Integer(n))
          | #("devin_status_code", ir.Integer(n))
          if n >= 0
        -> Ok(Nil)
        #("devin_request_id", ir.String(_))
        | #("devin_model", ir.String(_))
        | #("devin_input_known", ir.Boolean(_))
        | #("devin_output_known", ir.Boolean(_))
        | #("devin_usage_source", ir.String("dimension_estimate")) -> Ok(Nil)
        _ -> Error("unsupported Devin Chat usage semantics")
      }
    }),
  )
  let native = ir.Object(usage.extensions)
  let input = ir.field(native, "devin_input_known") != Some(ir.Boolean(False))
  let output = ir.field(native, "devin_output_known") != Some(ir.Boolean(False))
  let source = case ir.field(native, "devin_usage_source") {
    Some(ir.String("dimension_estimate")) -> "dimension_estimate"
    _ -> "native_accounting"
  }
  let fields = [
    #("devin_usage_source", ir.String(source)),
    #("devin_usage_partial", ir.Boolean(!input || !output)),
    #("devin_input_known", ir.Boolean(input)),
    #("devin_output_known", ir.Boolean(output)),
    #("devin_usage", native),
  ]
  let fields =
    ir.with_optional(fields, "prompt_tokens", case input {
      True -> Some(ir.Integer(usage.input_tokens))
      False -> None
    })
  let fields =
    ir.with_optional(fields, "completion_tokens", case output {
      True -> Some(ir.Integer(usage.output_tokens))
      False -> None
    })
  Ok(
    ir.Object(
      ir.with_optional(fields, "total_tokens", case input && output {
        True -> Some(ir.Integer(usage.input_tokens + usage.output_tokens))
        False -> None
      }),
    ),
  )
}

/// Fixed diagnostics only. Never echo a protobuf payload/trailer/tool argument.
pub fn failure(error: c.Failure) -> String {
  shared.encode_event(
    shared.NamedErrorEvent(
      ir.Object([
        #(
          "error",
          ir.Object([
            #("message", ir.String("Devin stream failed")),
            #("type", ir.String("provider_error")),
            #(
              "code",
              ir.String(case error.reason {
                c.Unsupported -> "unsupported_projection"
                c.Cancelled -> "cancelled"
                _ -> "invalid_upstream_stream"
              }),
            ),
          ]),
        ),
        #("devin_delivery", ir.String("started")),
      ]),
    ),
  )
}

fn ensure(condition: Bool, error: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(error)
  }
}
