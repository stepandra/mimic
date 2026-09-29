import gleam/bit_array
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb

/// Arguments and signatures stay binary until complete; protobuf chunks need
/// not end on UTF-8 boundaries.
pub type ToolDelta {
  ToolDelta(
    id: String,
    name: String,
    arguments: BitArray,
    invalid_json: BitArray,
    invalid_json_error: String,
    custom: Bool,
  )
}

pub type Event {
  Text(String)
  ThinkingDelta(String)
  SignatureDelta(BitArray)
  SignatureType(String)
  Tool(ToolDelta)
  Usage(ir.Usage)
  Reason(Int)
  Stop
}

pub opaque type Decoder {
  Decoder(
    connect: connect.Decoder,
    pending_text: BitArray,
    pending_thinking: BitArray,
    stopped: Bool,
    usage: Option(ir.Usage),
    failed: Bool,
  )
}

pub fn new() -> Decoder {
  Decoder(connect.new(), <<>>, <<>>, False, None, False)
}

pub fn feed(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, List(Event)), String) {
  let #(next, events, error) = feed_prefix(decoder, bytes)
  case error {
    None -> Ok(#(next, events))
    Some(error) -> Error(error)
  }
}

/// Return the validated event prefix even when a later frame in the same
/// packet fails. On Some(error), emit events once and terminate the stream;
/// the returned decoder is not resumable.
pub fn feed_prefix(
  decoder: Decoder,
  bytes: BitArray,
) -> #(Decoder, List(Event), Option(String)) {
  case decoder.failed {
    True -> #(decoder, [], Some("devin response decoder failed"))
    False -> feed_bytes(decoder, bytes)
  }
}

fn feed_bytes(
  decoder: Decoder,
  bytes: BitArray,
) -> #(Decoder, List(Event), Option(String)) {
  let #(framing, frames, frame_error) =
    connect.feed_prefix(decoder.connect, bytes)
  let #(decoded, events, parse_error) = consume(decoder, frames, [])
  let error = case parse_error {
    Some(_) -> parse_error
    None -> frame_error
  }
  #(Decoder(..decoded, connect: framing, failed: error != None), events, error)
}

pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  use _ <- result.try(case decoder.failed {
    True -> Error("devin response decoder failed")
    False -> Ok(Nil)
  })
  use _ <- result.try(connect.finish(decoder.connect))
  case decoder.pending_text, decoder.pending_thinking {
    <<>>, <<>> -> Ok(Nil)
    _, _ -> Error("truncated devin UTF-8 text")
  }
}

fn consume(
  decoder: Decoder,
  frames: List(connect.Frame),
  events: List(Event),
) -> #(Decoder, List(Event), Option(String)) {
  case frames {
    [] -> #(decoder, list.reverse(events), None)
    [connect.End, ..rest] -> {
      case decoder.pending_text, decoder.pending_thinking {
        <<>>, <<>> -> consume(decoder, rest, [Stop, ..events])
        _, _ -> #(
          decoder,
          list.reverse(events),
          Some("truncated devin UTF-8 text"),
        )
      }
    }
    [connect.Data(bytes), ..rest] -> {
      case pb.decode(bytes) {
        Error(error) -> #(decoder, list.reverse(events), Some(error))
        Ok(fields) -> {
          case fields_to_events(decoder, fields, []) {
            Error(error) -> #(decoder, list.reverse(events), Some(error))
            Ok(#(decoded, next)) -> {
              // Protobuf field order is not event order: a stop marker can
              // precede content in the same message.
              let reason =
                list.fold(fields, 0, fn(last, field) {
                  case field {
                    pb.Varint(5, value) -> value
                    _ -> last
                  }
                })
              let next = case reason {
                0 -> next
                _ -> list.append(next, [Reason(reason)])
              }
              let stopped =
                decoded.stopped
                || list.any(next, fn(event) {
                  case event {
                    Reason(_) -> True
                    _ -> False
                  }
                })
              consume(
                Decoder(..decoded, stopped: stopped),
                rest,
                list.append(list.reverse(next), events),
              )
            }
          }
        }
      }
    }
  }
}

fn fields_to_events(
  decoder: Decoder,
  fields: List(pb.Field),
  events: List(Event),
) -> Result(#(Decoder, List(Event)), String) {
  case fields {
    [] -> Ok(#(decoder, list.reverse(events)))
    [field, ..rest] -> {
      case field {
        pb.Bytes(3, text) if !decoder.stopped -> {
          use #(text, pending) <- result.try(
            utf8(<<decoder.pending_text:bits, text:bits>>),
          )
          let events = case text {
            "" -> events
            _ -> [Text(text), ..events]
          }
          fields_to_events(
            Decoder(..decoder, pending_text: pending),
            rest,
            events,
          )
        }
        pb.Bytes(9, text) if !decoder.stopped -> {
          use #(text, pending) <- result.try(
            utf8(<<decoder.pending_thinking:bits, text:bits>>),
          )
          let events = case text {
            "" -> events
            _ -> [ThinkingDelta(text), ..events]
          }
          fields_to_events(
            Decoder(..decoder, pending_thinking: pending),
            rest,
            events,
          )
        }
        pb.Bytes(10, bytes) if !decoder.stopped ->
          fields_to_events(decoder, rest, [SignatureDelta(bytes), ..events])
        pb.Bytes(21, bytes) if !decoder.stopped -> {
          use type_name <- result.try(text_value(bytes))
          fields_to_events(decoder, rest, [SignatureType(type_name), ..events])
        }
        pb.Bytes(6, bytes) if !decoder.stopped -> {
          use tool <- result.try(decode_tool(bytes))
          fields_to_events(decoder, rest, [Tool(tool), ..events])
        }
        pb.Varint(5, reason) if reason == 0 ->
          fields_to_events(decoder, rest, events)
        pb.Varint(5, reason)
          if reason == 1
          || reason == 2
          || reason == 3
          || reason == 4
          || reason == 10
          || reason == 11
        -> fields_to_events(decoder, rest, events)
        pb.Bytes(7, bytes) -> {
          use usage <- result.try(decode_usage(bytes))
          let usage = merge_usage(decoder.usage, usage)
          fields_to_events(Decoder(..decoder, usage: Some(usage)), rest, [
            Usage(usage),
            ..events
          ])
        }
        pb.Bytes(28, bytes) -> {
          use estimate <- result.try(decode_dimension_group(bytes))
          case estimate {
            None -> fields_to_events(decoder, rest, events)
            Some(usage) -> {
              let usage = merge_usage(decoder.usage, usage)
              fields_to_events(Decoder(..decoder, usage: Some(usage)), rest, [
                Usage(usage),
                ..events
              ])
            }
          }
        }
        // Known non-content metadata. Any other tag fails explicitly.
        pb.Bytes(1, _)
        | pb.Bytes(2, _)
        | pb.Varint(2, _)
        | pb.Varint(4, _)
        | pb.Fixed64(12, _)
        | pb.Bytes(17, _) -> fields_to_events(decoder, rest, events)
        _ -> Error("unsupported devin response field or stop reason")
      }
    }
  }
}

/// Validate split UTF-8 without unbounded buffering. At most three bytes wait.
fn utf8(bytes: BitArray) -> Result(#(String, BitArray), String) {
  utf8_prefix(bytes, <<>>)
}

fn utf8_prefix(
  remaining: BitArray,
  valid: BitArray,
) -> Result(#(String, BitArray), String) {
  case remaining {
    <<codepoint:utf8_codepoint, rest:bits>> ->
      utf8_prefix(rest, <<valid:bits, codepoint:utf8_codepoint>>)
    <<>> -> {
      use text <- result.try(
        bit_array.to_string(valid)
        |> result.replace_error("invalid devin UTF-8"),
      )
      Ok(#(text, <<>>))
    }
    _ -> {
      use _ <- result.try(case possible_prefix(remaining) {
        True -> Ok(Nil)
        False -> Error("invalid devin UTF-8")
      })
      use text <- result.try(
        bit_array.to_string(valid)
        |> result.replace_error("invalid devin UTF-8"),
      )
      Ok(#(text, remaining))
    }
  }
}

fn possible_prefix(bytes: BitArray) -> Bool {
  case bytes {
    <<a>> -> a >= 194 && a <= 244
    <<a, b>> if b >= 128 && b <= 191 ->
      { a == 224 && b >= 160 }
      || { a >= 225 && a <= 236 }
      || { a == 237 && b <= 159 }
      || { a >= 238 && a <= 239 }
      || { a == 240 && b >= 144 }
      || { a >= 241 && a <= 243 }
      || { a == 244 && b <= 143 }
    <<a, b, c>> if c >= 128 && c <= 191 && b >= 128 && b <= 191 ->
      { a == 240 && b >= 144 }
      || { a >= 241 && a <= 243 }
      || { a == 244 && b <= 143 }
    _ -> False
  }
}

fn text_value(bytes: BitArray) -> Result(String, String) {
  bit_array.to_string(bytes)
  |> result.replace_error("invalid devin UTF-8")
}

fn decode_tool(bytes: BitArray) -> Result(ToolDelta, String) {
  use fields <- result.try(pb.decode(bytes))
  use tool <- result.try(
    list.fold(
      fields,
      Ok(ToolDelta("", "", <<>>, <<>>, "", False)),
      fn(acc, field) {
        use tool <- result.try(acc)
        case field {
          pb.Bytes(1, bytes) -> {
            use id <- result.try(text_value(bytes))
            Ok(ToolDelta(..tool, id: id))
          }
          pb.Bytes(2, bytes) -> {
            use name <- result.try(text_value(bytes))
            Ok(ToolDelta(..tool, name: name))
          }
          pb.Bytes(3, bytes) ->
            Ok(
              ToolDelta(..tool, arguments: <<tool.arguments:bits, bytes:bits>>),
            )
          pb.Bytes(4, bytes) ->
            Ok(
              ToolDelta(..tool, invalid_json: <<
                tool.invalid_json:bits,
                bytes:bits,
              >>),
            )
          pb.Bytes(5, bytes) -> {
            use error <- result.try(text_value(bytes))
            Ok(ToolDelta(..tool, invalid_json_error: error))
          }
          pb.Varint(6, flag) if flag == 0 || flag == 1 ->
            Ok(ToolDelta(..tool, custom: flag == 1))
          _ -> Error("unsupported devin tool delta field")
        }
      },
    ),
  )
  case tool.id {
    "" -> Error("devin tool delta missing call id")
    _ -> Ok(tool)
  }
}

fn decode_usage(bytes: BitArray) -> Result(ir.Usage, String) {
  use fields <- result.try(pb.decode(bytes))
  use usage <- result.try(
    list.fold(fields, Ok(ir.Usage(0, 0, [])), fn(acc, field) {
      use usage <- result.try(acc)
      case field {
        pb.Varint(2, n) ->
          Ok(ir.Usage(..usage, input_tokens: usage.input_tokens + n))
        pb.Varint(3, n) -> Ok(ir.Usage(..usage, output_tokens: n))
        pb.Varint(4, n) ->
          Ok(
            ir.Usage(
              ..usage,
              extensions: add_sum(usage.extensions, "cache_write_tokens", n),
            ),
          )
        pb.Varint(5, n) ->
          Ok(
            ir.Usage(
              ..usage,
              extensions: set_extension(
                usage.extensions,
                "cached_input_tokens",
                ir.Integer(n),
              ),
            ),
          )
        pb.Varint(6, n) ->
          Ok(
            ir.Usage(
              ..usage,
              extensions: set_extension(
                usage.extensions,
                "devin_status_code",
                ir.Integer(n),
              ),
            ),
          )
        pb.Bytes(9, bytes) -> {
          use model <- result.try(text_value(bytes))
          Ok(
            ir.Usage(
              ..usage,
              extensions: set_extension(
                usage.extensions,
                "devin_model",
                ir.String(model),
              ),
            ),
          )
        }
        pb.Bytes(8, bytes) -> {
          use #(key, value) <- result.try(decode_header(bytes))
          case string.lowercase(key) {
            "x-request-id" | "request-id" ->
              Ok(
                ir.Usage(
                  ..usage,
                  extensions: set_extension(
                    usage.extensions,
                    "devin_request_id",
                    ir.String(value),
                  ),
                ),
              )
            "openai-version" | "openai-processing-ms" -> Ok(usage)
            _ -> Error("unsupported devin usage header")
          }
        }
        _ -> Error("unsupported devin usage field")
      }
    }),
  )
  let input_known =
    list.any(fields, fn(field) {
      case field {
        pb.Varint(2, _) -> True
        _ -> False
      }
    })
  let output_known =
    list.any(fields, fn(field) {
      case field {
        pb.Varint(3, _) -> True
        _ -> False
      }
    })
  Ok(
    ir.Usage(
      ..usage,
      extensions: usage_known_fields(
        usage.extensions,
        input_known,
        output_known,
      ),
    ),
  )
}

fn decode_header(bytes: BitArray) -> Result(#(String, String), String) {
  use fields <- result.try(pb.decode(bytes))
  list.fold(fields, Ok(#("", "")), fn(acc, field) {
    use #(key, value) <- result.try(acc)
    case field {
      pb.Bytes(1, bytes) -> {
        use key <- result.try(text_value(bytes))
        Ok(#(key, value))
      }
      pb.Bytes(2, bytes) -> {
        use value <- result.try(text_value(bytes))
        Ok(#(key, value))
      }
      _ -> Error("unsupported devin usage header field")
    }
  })
}

fn add_sum(
  fields: List(#(String, ir.Value)),
  key: String,
  n: Int,
) -> List(#(String, ir.Value)) {
  let previous = case list.find(fields, fn(entry) { entry.0 == key }) {
    Ok(#(_, ir.Integer(n))) -> n
    _ -> 0
  }
  set_extension(fields, key, ir.Integer(previous + n))
}

fn set_extension(
  fields: List(#(String, ir.Value)),
  key: String,
  value: ir.Value,
) -> List(#(String, ir.Value)) {
  list.filter(fields, fn(entry) { entry.0 != key })
  |> list.append([#(key, value)])
}

fn usage_known_fields(
  extensions: List(#(String, ir.Value)),
  input: Bool,
  output: Bool,
) -> List(#(String, ir.Value)) {
  let extensions =
    list.filter(extensions, fn(entry) {
      entry.0 != "devin_input_known" && entry.0 != "devin_output_known"
    })
  let extensions = case input {
    True -> extensions
    False ->
      list.append(extensions, [#("devin_input_known", ir.Boolean(False))])
  }
  case output {
    True -> extensions
    False ->
      list.append(extensions, [#("devin_output_known", ir.Boolean(False))])
  }
}

fn usage_has(usage: ir.Usage, key: String) -> Bool {
  ir.field(ir.Object(usage.extensions), key) != Some(ir.Boolean(False))
}

/// ResponseDimensionGroups carry float32 telemetry, not exact model accounting.
/// Never silently promote this fallback to an exact token count.
fn decode_dimension_group(bytes: BitArray) -> Result(Option(ir.Usage), String) {
  use fields <- result.try(pb.decode(bytes))
  use #(title, metrics) <- result.try(
    list.fold(fields, Ok(#("", [])), fn(acc, field) {
      use #(title, metrics) <- result.try(acc)
      case field {
        pb.Bytes(1, bytes) -> {
          use title <- result.try(text_value(bytes))
          Ok(#(title, metrics))
        }
        pb.Bytes(2, bytes) -> {
          use metric <- result.try(decode_metric(bytes))
          Ok(#(title, [metric, ..metrics]))
        }
        _ -> Error("unsupported devin dimension group field")
      }
    }),
  )
  case title {
    "Token Usage" -> {
      let #(input, output, cache) =
        list.fold(list.reverse(metrics), #(None, None, None), fn(acc, metric) {
          case metric {
            #("input_tokens", n) -> #(Some(n), acc.1, acc.2)
            #("output_tokens", n) -> #(acc.0, Some(n), acc.2)
            #("cached_input_tokens", n) -> #(acc.0, acc.1, Some(n))
            _ -> acc
          }
        })
      case input, output, cache {
        None, None, None -> Ok(None)
        _, _, _ -> {
          let fields = [
            #("devin_usage_source", ir.String("dimension_estimate")),
          ]
          let fields =
            ir.with_optional(
              fields,
              "cached_input_tokens",
              ir.option_int(cache),
            )
          Ok(
            Some(ir.Usage(
              option.unwrap(input, 0),
              option.unwrap(output, 0),
              usage_known_fields(fields, input != None, output != None),
            )),
          )
        }
      }
    }
    _ -> Ok(None)
  }
}

fn decode_metric(bytes: BitArray) -> Result(#(String, Int), String) {
  use fields <- result.try(pb.decode(bytes))
  use #(key, value) <- result.try(
    list.fold(fields, Ok(#("", None)), fn(acc, field) {
      use #(key, value) <- result.try(acc)
      case field {
        pb.Bytes(5, bytes) -> {
          use key <- result.try(text_value(bytes))
          Ok(#(key, value))
        }
        pb.Bytes(4, bytes) -> {
          use fields <- result.try(pb.decode(bytes))
          use value <- result.try(
            list.fold(fields, Ok(value), fn(acc, field) {
              use _ <- result.try(acc)
              case field {
                pb.Fixed32(2, <<n:float-32-little>>)
                  if n >=. 0.0 && n <. 1_000_000_000.0
                -> Ok(Some(float.truncate(n)))
                _ -> Error("unsupported devin token dimension")
              }
            }),
          )
          Ok(#(key, value))
        }
        _ -> Error("unsupported devin metric field")
      }
    }),
  )
  case value {
    Some(value) if key != "" -> Ok(#(key, value))
    _ -> Error("incomplete devin token dimension")
  }
}

fn merge_usage(previous: Option(ir.Usage), next: ir.Usage) -> ir.Usage {
  case previous {
    None -> next
    Some(previous) ->
      case is_estimate(previous), is_estimate(next) {
        True, False -> next
        False, True -> previous
        _, _ -> {
          let input = usage_has(previous, "devin_input_known")
          let output = usage_has(previous, "devin_output_known")
          let next_input = usage_has(next, "devin_input_known")
          let next_output = usage_has(next, "devin_output_known")
          ir.Usage(
            case next_input {
              True -> next.input_tokens
              False -> previous.input_tokens
            },
            case next_output {
              True -> next.output_tokens
              False -> previous.output_tokens
            },
            usage_known_fields(
              list.fold(next.extensions, previous.extensions, fn(acc, entry) {
                set_extension(acc, entry.0, entry.1)
              }),
              input || next_input,
              output || next_output,
            ),
          )
        }
      }
  }
}

fn is_estimate(usage: ir.Usage) -> Bool {
  ir.field(ir.Object(usage.extensions), "devin_usage_source")
  == Some(ir.String("dimension_estimate"))
}

pub fn buffered(
  bytes: BitArray,
  id: String,
  model: String,
) -> Result(ir.Response, String) {
  use _ <- result.try(case bit_array.byte_size(bytes) <= 8_388_608 {
    True -> Ok(Nil)
    False -> Error("devin buffered response limit")
  })
  use #(decoder, events) <- result.try(feed(new(), bytes))
  use _ <- result.try(finish(decoder))
  use accumulated <- result.try(
    list.fold(
      events,
      Ok(Accumulated([], <<>>, "", [], None, None)),
      fn(acc, event) {
        use acc <- result.try(acc)
        case event {
          Text(text) ->
            Ok(Accumulated(..acc, parts: append_text(acc.parts, text)))
          ThinkingDelta(text) ->
            Ok(Accumulated(..acc, parts: append_thinking(acc.parts, text)))
          SignatureDelta(bytes) ->
            Ok(
              Accumulated(..acc, signature: <<acc.signature:bits, bytes:bits>>),
            )
          SignatureType(name) -> Ok(Accumulated(..acc, signature_type: name))
          Tool(delta) -> {
            let fresh = !list.any(acc.tools, fn(tool) { tool.id == delta.id })
            use tools <- result.try(append_tool(acc.tools, delta))
            Ok(
              Accumulated(..acc, tools: tools, parts: case fresh {
                True -> [ToolPart(delta.id), ..acc.parts]
                False -> acc.parts
              }),
            )
          }
          Usage(usage) -> Ok(Accumulated(..acc, usage: Some(usage)))
          Reason(reason) -> Ok(Accumulated(..acc, reason: Some(reason)))
          Stop -> Ok(acc)
        }
      },
    ),
  )
  let parts = case accumulated.parts, accumulated.signature {
    [], <<>> -> [TextPart("")]
    parts, <<>> -> parts
    parts, _ ->
      case
        list.any(parts, fn(part) {
          case part {
            ThinkingPart(_) -> True
            _ -> False
          }
        })
      {
        True -> parts
        False -> [ThinkingPart(""), ..parts]
      }
  }
  use content <- result.try(parts_to_content(parts, accumulated))
  let reason = case accumulated.reason {
    Some(10) -> "tool_use"
    Some(1) | Some(3) -> "max_tokens"
    Some(11) -> "content_filter"
    _ -> "end_turn"
  }
  Ok(ir.Response(
    id,
    model,
    content,
    list.all(content, fn(part) {
      case part {
        ir.Text(_, _) -> True
        _ -> False
      }
    }),
    Some(reason),
    accumulated.usage,
    [],
    [],
    [],
    ir.Constructed,
  ))
}

type Part {
  TextPart(String)
  ThinkingPart(String)
  ToolPart(String)
}

type Accumulated {
  Accumulated(
    /// Reversed to append in constant time; tool refs retain first-seen order.
    parts: List(Part),
    signature: BitArray,
    signature_type: String,
    tools: List(ToolDelta),
    usage: Option(ir.Usage),
    reason: Option(Int),
  )
}

fn append_text(parts: List(Part), text: String) -> List(Part) {
  case parts {
    [TextPart(previous), ..rest] -> [TextPart(previous <> text), ..rest]
    _ -> [TextPart(text), ..parts]
  }
}

fn append_thinking(parts: List(Part), text: String) -> List(Part) {
  case parts {
    [ThinkingPart(previous), ..rest] -> [ThinkingPart(previous <> text), ..rest]
    _ -> [ThinkingPart(text), ..parts]
  }
}

fn parts_to_content(
  parts: List(Part),
  accumulated: Accumulated,
) -> Result(List(ir.Content), String) {
  // The last thinking block gets a signature even when its delta arrives
  // after later text or tool content.
  use #(content, _) <- result.try(
    list.fold(parts, Ok(#([], False)), fn(acc, part) {
      use #(content, signed) <- result.try(acc)
      case part {
        ThinkingPart(text) if !signed -> {
          let signature = case accumulated.signature {
            <<>> -> None
            bytes -> Some(bit_array.base64_encode(bytes, False))
          }
          let extensions = case signature {
            None -> []
            Some(_) -> [
              #("devin_signature_encoding", ir.String("base64")),
              #("devin_signature_type", ir.String(accumulated.signature_type)),
            ]
          }
          Ok(#([ir.Thinking(text, signature, extensions), ..content], True))
        }
        ThinkingPart(text) ->
          Ok(#([ir.Thinking(text, None, []), ..content], signed))
        TextPart(text) -> Ok(#([ir.Text(text, []), ..content], signed))
        ToolPart(id) -> {
          use tool <- result.try(
            list.find(accumulated.tools, fn(tool) { tool.id == id })
            |> result.replace_error("devin tool call missing"),
          )
          use tool <- result.try(tool_content(tool))
          Ok(#([tool, ..content], signed))
        }
      }
    }),
  )
  Ok(content)
}

fn append_tool(
  tools: List(ToolDelta),
  delta: ToolDelta,
) -> Result(List(ToolDelta), String) {
  case delta.id {
    "" -> Error("devin tool delta missing call id")
    id ->
      case list.any(tools, fn(tool) { tool.id == id }) {
        False ->
          case list.length(tools) < 128 {
            True -> Ok(list.append(tools, [delta]))
            False -> Error("devin tool call limit")
          }
        True ->
          list.try_map(tools, fn(tool) {
            case tool.id == id {
              False -> Ok(tool)
              True -> {
                use _ <- result.try(
                  case
                    delta.name == ""
                    || tool.name == ""
                    || delta.name == tool.name
                  {
                    True -> Ok(Nil)
                    False -> Error("conflicting devin tool names")
                  },
                )
                Ok(ToolDelta(
                  id,
                  case delta.name {
                    "" -> tool.name
                    name -> name
                  },
                  <<tool.arguments:bits, delta.arguments:bits>>,
                  <<tool.invalid_json:bits, delta.invalid_json:bits>>,
                  tool.invalid_json_error <> delta.invalid_json_error,
                  tool.custom || delta.custom,
                ))
              }
            }
          })
      }
  }
}

fn tool_content(tool: ToolDelta) -> Result(ir.Content, String) {
  use _ <- result.try(case tool.name {
    "" -> Error("devin tool call missing name")
    _ -> Ok(Nil)
  })
  case
    tool.invalid_json == <<>> && !tool.custom && tool.invalid_json_error == ""
  {
    True -> {
      use raw <- result.try(text_value(tool.arguments))
      use value <- result.try(ir.parse(raw))
      Ok(ir.ToolCall(tool.id, tool.name, value, Some(raw), []))
    }
    False -> {
      use raw_text <- result.try(text_value(tool.invalid_json))
      use json_text <- result.try(text_value(tool.arguments))
      // Custom tools supply raw, non-JSON arguments. Native IR retains these
      // bytes but cross-dialect encoders must reject this unknown block.
      Ok(
        ir.Unknown(
          ir.Object([
            #("devin_tool_call_id", ir.String(tool.id)),
            #("devin_tool_name", ir.String(tool.name)),
            #("devin_custom_arguments", ir.String(raw_text)),
            #("devin_invalid_json_error", ir.String(tool.invalid_json_error)),
            #("devin_custom", ir.Boolean(tool.custom)),
            #("devin_json_arguments", ir.String(json_text)),
          ]),
        ),
      )
    }
  }
}
