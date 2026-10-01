/// One F25 construction rule for JSON and delayed buffered-to-SSE. Only the
/// existing native decoder supplies events. Stop at this boundary requires
/// clean HTTP EOF; a Connect trailer alone is not transport completion.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses as shared
import mimic/ir
import mimic/protocol/responses/stream as strict
import mimic/providers/devin/messages
import mimic/providers/devin/response as native
import mimic/providers/devin/responses_request as input

pub const max_bytes = 8_388_608

pub const max_events = 16_384

pub const max_items = 256

pub const max_response_bytes = 524_288

type Part {
  Text(String)
  Thinking(String)
  Tool(String)
}

pub opaque type Builder {
  Builder(
    id: String,
    model: String,
    created_at: Int,
    settings: input.Settings,
    parts: List(Part),
    tools: List(native.ToolDelta),
    signature: BitArray,
    signature_type: String,
    usage: Option(ir.Usage),
    reason: Option(Int),
    bytes: Int,
    events: Int,
    stopped: Bool,
  )
}

/// Both encodings have already passed the shared strict Responses/S6 observer.
/// This is a projection, never a continuation receipt or a WS cursor.
pub opaque type Projection {
  Projection(document: ir.Value, json: String, frames: List(String))
}

pub fn new(
  id: String,
  model: String,
  created_at: Int,
  settings: input.Settings,
) -> Result(Builder, String) {
  use _ <- result.try(input.ensure(
    id != ""
      && model != ""
      && string.byte_size(id) <= 1024
      && string.byte_size(model) <= 1024
      && created_at >= 0,
    "invalid Devin Responses identity",
  ))
  Ok(Builder(
    id,
    model,
    created_at,
    settings,
    [],
    [],
    <<>>,
    "",
    None,
    None,
    0,
    0,
    False,
  ))
}

pub fn push(builder: Builder, event: native.Event) -> Result(Builder, String) {
  use _ <- result.try(input.ensure(
    !builder.stopped && builder.events < max_events,
    "Devin Responses terminal/event limit",
  ))
  use _ <- result.try(input.ensure(
    builder.reason == None
      || case event {
      native.Usage(_) | native.Reason(_) | native.Stop -> True
      _ -> False
    },
    "Devin Responses content after stop reason",
  ))
  let builder = Builder(..builder, events: builder.events + 1)
  use next <- result.try(case event {
    native.Text(text) -> {
      use builder <- result.try(retain(builder, string.byte_size(text)))
      let parts = case builder.parts {
        [Text(previous), ..rest] -> [Text(previous <> text), ..rest]
        _ -> [Text(text), ..builder.parts]
      }
      Ok(Builder(..builder, parts: parts))
    }
    native.ThinkingDelta(text) -> {
      use builder <- result.try(retain(builder, string.byte_size(text)))
      let parts = case builder.parts {
        [Thinking(previous), ..rest] -> [Thinking(previous <> text), ..rest]
        _ -> [Thinking(text), ..builder.parts]
      }
      use _ <- result.try(input.ensure(
        list.count(parts, fn(part) {
          case part {
            Thinking(_) -> True
            _ -> False
          }
        })
          == 1,
        "ambiguous Devin Responses reasoning association",
      ))
      Ok(Builder(..builder, parts: parts))
    }
    native.Tool(delta) -> append_tool(builder, delta)
    native.SignatureDelta(bytes) -> {
      use builder <- result.try(retain(builder, bit_array.byte_size(bytes)))
      Ok(Builder(..builder, signature: <<builder.signature:bits, bytes:bits>>))
    }
    native.SignatureType(kind) -> {
      use _ <- result.try(input.ensure(
        kind == "openai"
          && { builder.signature_type == "" || builder.signature_type == kind },
        "unsupported or conflicting Responses reasoning source",
      ))
      use builder <- result.try(retain(builder, string.byte_size(kind)))
      Ok(Builder(..builder, signature_type: kind))
    }
    native.Usage(usage) -> {
      // Keep the native decoder's last cumulative snapshot. Never manufacture
      // totals from dimensions, absent fields, byte counts or token heuristics.
      use builder <- result.try(retain(
        builder,
        string.byte_size(ir.stringify(ir.Object(usage.extensions))),
      ))
      Ok(Builder(..builder, usage: Some(usage)))
    }
    native.Reason(reason) -> {
      use _ <- result.try(input.ensure(
        list.contains([1, 2, 3, 4, 10, 11], reason)
          && { builder.reason == None || builder.reason == Some(reason) },
        "unsupported or conflicting Devin Responses stop reason",
      ))
      Ok(Builder(..builder, reason: Some(reason)))
    }
    native.Stop -> Ok(Builder(..builder, stopped: True))
  })
  use _ <- result.try(input.ensure(
    list.length(next.parts) <= max_items,
    "Devin Responses item limit",
  ))
  Ok(next)
}

fn retain(builder: Builder, bytes: Int) -> Result(Builder, String) {
  use _ <- result.try(input.ensure(
    builder.bytes + bytes <= max_bytes,
    "Devin Responses retained byte limit",
  ))
  Ok(Builder(..builder, bytes: builder.bytes + bytes))
}

fn append_tool(
  builder: Builder,
  delta: native.ToolDelta,
) -> Result(Builder, String) {
  use _ <- result.try(input.ensure(
    delta.id != ""
      && !delta.custom
      && delta.invalid_json == <<>>
      && delta.invalid_json_error == "",
    "unsupported Devin Responses custom or invalid-JSON tool",
  ))
  use builder <- result.try(retain(
    builder,
    string.byte_size(delta.id)
      + string.byte_size(delta.name)
      + bit_array.byte_size(delta.arguments),
  ))
  case list.any(builder.tools, fn(tool) { tool.id == delta.id }) {
    False -> {
      use _ <- result.try(input.ensure(
        list.length(builder.tools) < 128,
        "Devin Responses tool limit",
      ))
      Ok(
        Builder(..builder, tools: [delta, ..builder.tools], parts: [
          Tool(delta.id),
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
              use _ <- result.try(input.ensure(
                delta.name == "" || tool.name == "" || tool.name == delta.name,
                "conflicting Devin Responses tool name",
              ))
              Ok(
                native.ToolDelta(
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
      // Same-call fragments fill their FIRST slot; they do not split a text run
      // or reserve/reopen an output index while the name is still unknown.
      Ok(Builder(..builder, tools: tools))
    }
  }
}

pub fn finish(builder: Builder) -> Result(Projection, String) {
  use _ <- result.try(input.ensure(
    builder.stopped,
    "Devin Responses missing native Stop",
  ))
  use usage <- result.try(
    option.to_result(builder.usage, "Devin Responses requires exact usage")
    |> result.try(messages.qualify_usage),
  )
  use reason <- result.try(option.to_result(
    builder.reason,
    "Devin Responses missing semantic stop reason",
  ))
  use _ <- result.try(input.ensure(
    reason != 10 || builder.tools != [],
    "Devin Responses tool stop without a call",
  ))
  use _ <- result.try(input.ensure(
    input.permits_call_count(builder.settings, list.length(builder.tools)),
    "unsupported Devin Responses parallel calls",
  ))
  use encrypted <- result.try(case builder.signature, builder.signature_type {
    <<>>, "" -> Ok(None)
    bytes, kind -> {
      use _ <- result.try(input.ensure(
        list.any(builder.parts, fn(part) {
          case part {
            Thinking(_) -> True
            _ -> False
          }
        }),
        "Devin Responses signature without reasoning",
      ))
      input.qualify_encrypted(bytes, kind) |> result.map(Some)
    }
  })
  let status = case reason {
    1 | 3 | 11 -> "incomplete"
    _ -> "completed"
  }
  let details = case reason {
    1 | 3 -> ir.Object([#("reason", ir.String("max_output_tokens"))])
    11 -> ir.Object([#("reason", ir.String("content_filter"))])
    _ -> ir.Null
  }
  use output <- result.try(
    builder.parts
    |> list.reverse
    |> list.index_map(fn(part, index) { #(part, index) })
    |> list.try_map(fn(pair) {
      output_item(builder, pair.0, pair.1, encrypted, status)
    }),
  )
  let document =
    ir.Object(list.append(
      [
        #("id", ir.String(builder.id)),
        #("object", ir.String("response")),
        // This is the local projection creation time, not a claimed native clock.
        #("created_at", ir.Integer(builder.created_at)),
        #("model", ir.String(builder.model)),
        #("status", ir.String(status)),
        #("store", ir.Boolean(False)),
        #("output", ir.Array(output)),
        #("error", ir.Null),
        #("incomplete_details", details),
        #(
          "usage",
          ir.Object([
            #("input_tokens", ir.Integer(usage.input_tokens)),
            #("output_tokens", ir.Integer(usage.output_tokens)),
            #(
              "total_tokens",
              ir.Integer(usage.input_tokens + usage.output_tokens),
            ),
          ]),
        ),
        #(
          "devin",
          ir.Object([
            #("stop_reason", ir.Integer(reason)),
            // Cache counts stay named native accounting, not guessed Responses cache
            // or reasoning-token semantics. Exact core counters above are qualified.
            #("usage", ir.Object(usage.extensions)),
          ]),
        ),
      ],
      input.response_fields(builder.settings),
    ))
  // Enforce the SAME depth/size/strict observer limits for both encodings.
  // Cache final JSON here: the gateway's post-construction deadline check must
  // not be followed by a second unbudgeted serialization after HTTP EOF.
  let json = ir.stringify(document)
  use _ <- result.try(ir.parse_bounded(json, max_response_bytes, 128, 65_536))
  use _ <- result.try(shared.response_from_value(document))
  use frames <- result.try(serialize(document, output, status))
  Ok(Projection(document, json, frames))
}

fn output_item(
  builder: Builder,
  part: Part,
  index: Int,
  encrypted: Option(String),
  status: String,
) -> Result(ir.Value, String) {
  let id = builder.id <> "_item_" <> int.to_string(index)
  let prefix = [#("id", ir.String(id))]
  case part {
    Text(text) ->
      Ok(
        ir.Object(
          list.append(prefix, [
            #("type", ir.String("message")),
            #("role", ir.String("assistant")),
            #("status", ir.String(status)),
            #("content", ir.Array([output_text(text)])),
          ]),
        ),
      )
    Thinking(text) ->
      Ok(
        ir.Object(ir.with_optional(
          list.append(prefix, [
            #("type", ir.String("reasoning")),
            #("summary", ir.Array([summary_text(text)])),
          ]),
          "encrypted_content",
          ir.option_string(encrypted),
        )),
      )
    Tool(id) -> {
      use tool <- result.try(
        list.find(builder.tools, fn(tool) { tool.id == id })
        |> result.replace_error("missing Devin Responses tool"),
      )
      use _ <- result.try(input.ensure(
        tool.name != "" && input.permits_tool(builder.settings, tool.name),
        "incomplete or unadmitted Devin Responses tool name",
      ))
      use arguments <- result.try(
        bit_array.to_string(tool.arguments)
        |> result.replace_error("invalid Devin Responses tool UTF-8"),
      )
      use value <- result.try(ir.parse_bounded(
        arguments,
        max_bytes,
        128,
        65_536,
      ))
      use _ <- result.try(ir.as_object(value))
      Ok(
        ir.Object(
          list.append(prefix, [
            #("type", ir.String("function_call")),
            #("call_id", ir.String(tool.id)),
            #("name", ir.String(tool.name)),
            #("arguments", ir.String(arguments)),
            #("status", ir.String("completed")),
          ]),
        ),
      )
    }
  }
}

fn output_text(text: String) -> ir.Value {
  ir.Object([
    #("type", ir.String("output_text")),
    #("text", ir.String(text)),
    #("annotations", ir.Array([])),
  ])
}

fn summary_text(text: String) -> ir.Value {
  ir.Object([#("type", ir.String("summary_text")), #("text", ir.String(text))])
}

fn serialize(
  document: ir.Value,
  output: List(ir.Value),
  status: String,
) -> Result(List(String), String) {
  let assert ir.Object(fields) = document
  let start =
    ir.Object(
      list.map(fields, fn(field) {
        case field.0 {
          "output" -> #("output", ir.Array([]))
          "status" -> #("status", ir.String("in_progress"))
          "incomplete_details" -> #("incomplete_details", ir.Null)
          _ -> field
        }
      }),
    )
  let events =
    list.flatten([
      [event("response.created", [#("response", start)])],
      output
        |> list.index_map(fn(item, index) { item_events(item, index) })
        |> list.flatten,
      [event("response." <> status, [#("response", document)])],
    ])
  let events =
    list.index_map(events, fn(document, index) {
      let assert ir.Object(fields) = document
      ir.Object([#("sequence_number", ir.Integer(index)), ..fields])
    })
  use #(observer, frames, _) <- result.try(
    list.try_fold(events, #(strict.new(), [], 0), fn(acc, document) {
      // Qualify serialized event JSON too: the SSE response envelope adds
      // depth that a constructed-tree push alone does not parse or bound.
      use #(observer, validated) <- result.try(strict.push_json(
        acc.0,
        ir.stringify(document),
      ))
      let frame = strict.encode_wire_event(validated)
      let bytes = acc.2 + string.byte_size(frame)
      use _ <- result.try(input.ensure(
        bytes <= max_bytes,
        "Devin Responses aggregate SSE byte limit",
      ))
      Ok(#(observer, [frame, ..acc.1], bytes))
    }),
  )
  use _ <- result.try(strict.finish(observer))
  Ok(list.reverse(frames))
}

fn event(name: String, fields: List(#(String, ir.Value))) -> ir.Value {
  ir.Object([#("type", ir.String(name)), ..fields])
}

fn replace_field(item: ir.Value, key: String, value: ir.Value) -> ir.Value {
  let assert ir.Object(fields) = item
  ir.Object(
    list.map(fields, fn(field) {
      case field.0 == key {
        True -> #(key, value)
        False -> field
      }
    }),
  )
}

fn item_events(item: ir.Value, index: Int) -> List(ir.Value) {
  let assert Some(ir.String(id)) = ir.field(item, "id")
  let assert Some(ir.String(kind)) = ir.field(item, "type")
  let identity = [
    #("output_index", ir.Integer(index)),
    #("item_id", ir.String(id)),
  ]
  let #(empty, body) = case kind {
    "function_call" -> {
      let assert Some(ir.String(arguments)) = ir.field(item, "arguments")
      let names = [
        #("call_id", option.unwrap(ir.field(item, "call_id"), ir.Null)),
        #("name", option.unwrap(ir.field(item, "name"), ir.Null)),
      ]
      #(
        replace_field(
          replace_field(item, "arguments", ir.String("")),
          "status",
          ir.String("in_progress"),
        ),
        [
          event(
            "response.function_call_arguments.delta",
            list.flatten([
              identity,
              names,
              [#("delta", ir.String(arguments))],
            ]),
          ),
          event(
            "response.function_call_arguments.done",
            list.flatten([
              identity,
              names,
              [#("arguments", ir.String(arguments))],
            ]),
          ),
        ],
      )
    }
    _ -> {
      let #(group, field, text_name, part_name) = case kind {
        "reasoning" -> #(
          "summary",
          "summary_index",
          "response.reasoning_summary_text",
          "response.reasoning_summary_part",
        )
        _ -> #(
          "content",
          "content_index",
          "response.output_text",
          "response.content_part",
        )
      }
      let assert Some(ir.Array([part])) = ir.field(item, group)
      let assert Some(ir.String(text)) = ir.field(part, "text")
      let identity = list.append(identity, [#(field, ir.Integer(0))])
      let empty = replace_field(item, group, ir.Array([]))
      let empty = case kind {
        "message" -> replace_field(empty, "status", ir.String("in_progress"))
        _ -> empty
      }
      #(empty, [
        event(
          part_name <> ".added",
          list.append(identity, [
            #("part", replace_field(part, "text", ir.String(""))),
          ]),
        ),
        event(
          text_name <> ".delta",
          list.append(identity, [
            #("delta", ir.String(text)),
          ]),
        ),
        event(
          text_name <> ".done",
          list.append(identity, [
            #("text", ir.String(text)),
          ]),
        ),
        event(part_name <> ".done", list.append(identity, [#("part", part)])),
      ])
    }
  }
  list.flatten([
    [
      event("response.output_item.added", [
        #("output_index", ir.Integer(index)),
        #("item", empty),
      ]),
    ],
    body,
    [
      event("response.output_item.done", [
        #("output_index", ir.Integer(index)),
        #("item", item),
      ]),
    ],
  ])
}

pub fn document(projection: Projection) -> ir.Value {
  projection.document
}

pub fn json(projection: Projection) -> String {
  projection.json
}

pub fn frames(projection: Projection) -> List(String) {
  projection.frames
}

/// Caller has already observed clean HTTP EOF (runtime native Stream does so).
pub fn buffered(
  bytes: BitArray,
  id: String,
  model: String,
  created_at: Int,
  settings: input.Settings,
) -> Result(Projection, String) {
  use _ <- result.try(input.ensure(
    bit_array.byte_size(bytes) <= max_bytes,
    "Devin Responses native byte limit",
  ))
  use #(decoder, events) <- result.try(native.feed(native.new(), bytes))
  use _ <- result.try(native.finish(decoder))
  use builder <- result.try(new(id, model, created_at, settings))
  use builder <- result.try(list.try_fold(events, builder, push))
  finish(builder)
}
