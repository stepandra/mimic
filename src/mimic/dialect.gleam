import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/openai
import mimic/ir

pub type Dialect {
  Anthropic
  Openai
  /// Reserved for an explicit unsupported-protocol error; no Gemini codec.
  Gemini
}

/// Stateful SSE decoder/translator. Retains only the current line, current
/// event, and open content-block metadata; never accumulates the response.
pub type Stream {
  Stream(
    source: Dialect,
    target: Dialect,
    pending_line: String,
    lines: List(String),
    id: String,
    model: String,
    started: Bool,
    done: Bool,
    open: List(#(Int, String)),
    tools: List(#(Int, Int)),
    next_index: Int,
    stop_reason: Option(String),
    usage: Option(ir.Usage),
  )
}

pub fn new_stream(source: Dialect, target: Dialect) -> Stream {
  Stream(source, target, "", [], "", "", False, False, [], [], 0, None, None)
}

/// Feed a valid UTF-8 chunk. Returns complete SSE frames immediately, in order.
/// The caller owns transport backpressure and must call `finish` on EOF.
pub fn feed(
  stream: Stream,
  chunk: String,
) -> Result(#(Stream, List(String)), String) {
  case stream.source, stream.target {
    Gemini, _ | _, Gemini -> Error("Gemini dialect is not implemented")
    _, _ -> feed_supported(stream, chunk)
  }
}

fn feed_supported(
  stream: Stream,
  chunk: String,
) -> Result(#(Stream, List(String)), String) {
  case stream.done, chunk {
    True, "" -> Ok(#(stream, []))
    True, _ -> Error("SSE data after terminal marker")
    False, _ -> {
      let parts = string.split(stream.pending_line <> chunk, "\n")
      let count = list.length(parts)
      let complete = list.take(parts, count - 1)
      let pending = case list.last(parts) {
        Ok(last) -> last
        Error(_) -> ""
      }
      let stream = Stream(..stream, pending_line: pending)
      process_lines(stream, complete, [])
    }
  }
}

fn process_lines(
  stream: Stream,
  lines: List(String),
  output: List(String),
) -> Result(#(Stream, List(String)), String) {
  case lines {
    [] -> Ok(#(stream, output))
    [_, ..] if stream.done -> Error("SSE data after terminal marker")
    [line, ..rest] -> {
      let line = case string.ends_with(line, "\r") {
        True -> string.drop_end(line, 1)
        False -> line
      }
      case line {
        "" -> {
          use pair <- result.try(complete_event(stream))
          process_lines(pair.0, rest, list.append(output, pair.1))
        }
        _ ->
          process_lines(
            Stream(..stream, lines: [line, ..stream.lines]),
            rest,
            output,
          )
      }
    }
  }
}

fn complete_event(stream: Stream) -> Result(#(Stream, List(String)), String) {
  let lines = list.reverse(stream.lines)
  let stream = Stream(..stream, lines: [])
  case lines {
    [] -> Ok(#(stream, []))
    _ -> {
      let event =
        lines
        |> list.filter(fn(line) { string.starts_with(line, "event:") })
        |> list.map(fn(line) { string.drop_start(line, 6) |> string.trim_start })
      let name = case event {
        [name, ..] -> name
        _ -> ""
      }
      let data =
        lines
        |> list.filter(fn(line) { string.starts_with(line, "data:") })
        |> list.map(fn(line) { string.drop_start(line, 5) |> string.trim_start })
        |> string.join("\n")
      case stream.source == stream.target {
        True ->
          Ok(
            #(
              Stream(
                ..stream,
                done: stream.done || data == "[DONE]" || name == "message_stop",
              ),
              [string.join(lines, "\n") <> "\n\n"],
            ),
          )
        False -> translate(stream, name, data)
      }
    }
  }
}

fn translate(
  stream: Stream,
  name: String,
  data: String,
) -> Result(#(Stream, List(String)), String) {
  case stream.source, stream.target {
    Anthropic, Openai -> from_anthropic(stream, name, data)
    Openai, Anthropic -> from_openai(stream, data)
    _, _ -> Error("unsupported streaming dialect")
  }
}

fn frame(name: String, data: ir.Value) -> String {
  "event: " <> name <> "\ndata: " <> ir.stringify(data) <> "\n\n"
}

fn chat_frame(data: ir.Value) -> String {
  "data: " <> ir.stringify(data) <> "\n\n"
}

fn chunk(stream: Stream, delta: ir.Value, finish_reason: ir.Value) -> ir.Value {
  ir.Object([
    #("id", ir.String(stream.id)),
    #("object", ir.String("chat.completion.chunk")),
    #("model", ir.String(stream.model)),
    #(
      "choices",
      ir.Array([
        ir.Object([
          #("index", ir.Integer(0)),
          #("delta", delta),
          #("finish_reason", finish_reason),
        ]),
      ]),
    ),
  ])
}

fn from_anthropic(
  stream: Stream,
  name: String,
  data: String,
) -> Result(#(Stream, List(String)), String) {
  use value <- result.try(ir.parse(data))
  case name {
    "message_start" -> {
      use _ <- result.try(case stream.started {
        True -> Error("duplicate Anthropic message_start")
        False -> Ok(Nil)
      })
      use message <- result.try(ir.required(value, "message"))
      use id <- result.try(ir.string_field(message, "id"))
      use model <- result.try(ir.string_field(message, "model"))
      use _ <- result.try(
        check_keys(message, [
          "id", "type", "role", "content", "model", "stop_reason",
          "stop_sequence", "usage",
        ]),
      )
      use _ <- result.try(case ir.field(message, "role") {
        Some(ir.String("assistant")) -> Ok(Nil)
        _ -> Error("Anthropic stream message must be assistant")
      })
      use _ <- result.try(case ir.field(message, "type") {
        Some(ir.String("message")) -> Ok(Nil)
        _ -> Error("unsupported Anthropic stream message type")
      })
      use _ <- result.try(case ir.field(message, "stop_sequence") {
        Some(ir.Null) | None -> Ok(Nil)
        _ ->
          Error("Anthropic stop_sequence cannot be represented in OpenAI chat")
      })
      let usage = case ir.field(message, "usage") {
        Some(value) -> {
          use usage <- result.try(ir.as_object(value))
          use input <- result.try(ir.required(ir.Object(usage), "input_tokens"))
          use input <- result.try(ir.as_int(input))
          use output <- result.try(ir.required(
            ir.Object(usage),
            "output_tokens",
          ))
          use output <- result.try(ir.as_int(output))
          use _ <- result.try(
            case
              openai.zero_cache_extensions(
                ir.extras(value, ["input_tokens", "output_tokens"]),
              )
            {
              True -> Ok(Nil)
              False -> Error("unsupported Anthropic stream usage extensions")
            },
          )
          Ok(Some(ir.Usage(input, output, [])))
        }
        None -> Ok(None)
      }
      use usage <- result.try(usage)
      let stream =
        Stream(..stream, id: id, model: model, started: True, usage: usage)
      Ok(
        #(stream, [
          chat_frame(chunk(
            stream,
            ir.Object([#("role", ir.String("assistant"))]),
            ir.Null,
          )),
        ]),
      )
    }
    "content_block_start" -> {
      use _ <- result.try(require_started(stream))
      use index <- result.try(index_field(value))
      use _ <- result.try(
        case list.find(stream.open, fn(item) { item.0 == index }) {
          Ok(_) -> Error("duplicate Anthropic content block index")
          Error(_) -> Ok(Nil)
        },
      )
      use block <- result.try(ir.required(value, "content_block"))
      use kind <- result.try(ir.string_field(block, "type"))
      case kind {
        "text" -> {
          use _ <- result.try(check_keys(block, ["type", "text"]))
          use initial <- result.try(ir.string_field(block, "text"))
          let stream = Stream(..stream, open: [#(index, "text"), ..stream.open])
          let frames = case initial {
            "" -> []
            _ -> [
              chat_frame(chunk(
                stream,
                ir.Object([#("content", ir.String(initial))]),
                ir.Null,
              )),
            ]
          }
          Ok(#(stream, frames))
        }
        "tool_use" -> {
          use _ <- result.try(
            check_keys(block, ["type", "id", "name", "input"]),
          )
          use id <- result.try(ir.string_field(block, "id"))
          use tool_name <- result.try(ir.string_field(block, "name"))
          use _ <- result.try(case ir.field(block, "input") {
            Some(ir.Object([])) | None -> Ok(Nil)
            _ ->
              Error(
                "nonempty initial Anthropic tool input cannot be translated incrementally",
              )
          })
          let stream = Stream(..stream, open: [#(index, "tool"), ..stream.open])
          let call =
            ir.Object([
              #("index", ir.Integer(index)),
              #("id", ir.String(id)),
              #("type", ir.String("function")),
              #(
                "function",
                ir.Object([
                  #("name", ir.String(tool_name)),
                  #("arguments", ir.String("")),
                ]),
              ),
            ])
          Ok(
            #(stream, [
              chat_frame(chunk(
                stream,
                ir.Object([#("tool_calls", ir.Array([call]))]),
                ir.Null,
              )),
            ]),
          )
        }
        _ -> Error("unsupported Anthropic stream content block: " <> kind)
      }
    }
    "content_block_delta" -> {
      use index <- result.try(index_field(value))
      use delta <- result.try(ir.required(value, "delta"))
      use kind <- result.try(ir.string_field(delta, "type"))
      use open <- result.try(
        case list.find(stream.open, fn(item) { item.0 == index }) {
          Ok(item) -> Ok(item.1)
          Error(_) -> Error("Anthropic delta without an open content block")
        },
      )
      case kind {
        "text_delta" -> {
          use _ <- result.try(case open {
            "text" -> Ok(Nil)
            _ -> Error("text delta on non-text block")
          })
          use _ <- result.try(check_keys(delta, ["type", "text"]))
          use text <- result.try(ir.string_field(delta, "text"))
          Ok(
            #(stream, [
              chat_frame(chunk(
                stream,
                ir.Object([#("content", ir.String(text))]),
                ir.Null,
              )),
            ]),
          )
        }
        "input_json_delta" -> {
          use _ <- result.try(case open {
            "tool" -> Ok(Nil)
            _ -> Error("tool delta on non-tool block")
          })
          use _ <- result.try(check_keys(delta, ["type", "partial_json"]))
          use partial <- result.try(ir.string_field(delta, "partial_json"))
          let call =
            ir.Object([
              #("index", ir.Integer(index)),
              #("function", ir.Object([#("arguments", ir.String(partial))])),
            ])
          Ok(
            #(stream, [
              chat_frame(chunk(
                stream,
                ir.Object([#("tool_calls", ir.Array([call]))]),
                ir.Null,
              )),
            ]),
          )
        }
        _ -> Error("unsupported Anthropic stream delta: " <> kind)
      }
    }
    "content_block_stop" -> {
      use index <- result.try(index_field(value))
      use _ <- result.try(
        case list.find(stream.open, fn(item) { item.0 == index }) {
          Ok(_) -> Ok(Nil)
          Error(_) -> Error("Anthropic content block stop without start")
        },
      )
      Ok(
        #(
          Stream(
            ..stream,
            open: list.filter(stream.open, fn(item) { item.0 != index }),
          ),
          [],
        ),
      )
    }
    "message_delta" -> {
      use _ <- result.try(require_started(stream))
      use delta <- result.try(ir.required(value, "delta"))
      use _ <- result.try(check_keys(delta, ["stop_reason", "stop_sequence"]))
      use _ <- result.try(case ir.field(delta, "stop_sequence") {
        Some(ir.Null) | None -> Ok(Nil)
        _ ->
          Error("Anthropic stop_sequence cannot be represented in OpenAI chat")
      })
      use reason <- result.try(ir.optional_string(delta, "stop_reason"))
      use finish <- result.try(case reason {
        Some("end_turn") -> Ok(ir.String("stop"))
        Some("tool_use") -> Ok(ir.String("tool_calls"))
        Some("max_tokens") -> Ok(ir.String("length"))
        Some(other) -> Error("unsupported Anthropic stop reason: " <> other)
        None -> Ok(ir.Null)
      })
      let usage = case ir.field(value, "usage") {
        Some(usage) -> {
          use _ <- result.try(check_keys(usage, ["output_tokens"]))
          use output <- result.try(ir.required(usage, "output_tokens"))
          use output <- result.try(ir.as_int(output))
          let input = case stream.usage {
            Some(previous) -> previous.input_tokens
            None -> 0
          }
          Ok(Some(ir.Usage(input, output, [])))
        }
        None -> Ok(stream.usage)
      }
      use usage <- result.try(usage)
      let stream = Stream(..stream, stop_reason: reason, usage: usage)
      Ok(#(stream, [chat_frame(chunk(stream, ir.Object([]), finish))]))
    }
    "message_stop" -> {
      use _ <- result.try(require_started(stream))
      use _ <- result.try(case stream.open {
        [] -> Ok(Nil)
        _ -> Error("Anthropic message stopped with open content blocks")
      })
      let usage = case stream.usage {
        Some(usage) -> [
          chat_frame(
            ir.Object([
              #("id", ir.String(stream.id)),
              #("object", ir.String("chat.completion.chunk")),
              #("model", ir.String(stream.model)),
              #("choices", ir.Array([])),
              #(
                "usage",
                ir.Object([
                  #("prompt_tokens", ir.Integer(usage.input_tokens)),
                  #("completion_tokens", ir.Integer(usage.output_tokens)),
                  #(
                    "total_tokens",
                    ir.Integer(usage.input_tokens + usage.output_tokens),
                  ),
                ]),
              ),
            ]),
          ),
        ]
        None -> []
      }
      Ok(#(
        Stream(..stream, done: True),
        list.append(usage, ["data: [DONE]\n\n"]),
      ))
    }
    "ping" -> Ok(#(stream, []))
    "error" -> Error("Anthropic upstream stream error")
    _ -> Error("unsupported Anthropic stream event: " <> name)
  }
}

fn from_openai(
  stream: Stream,
  data: String,
) -> Result(#(Stream, List(String)), String) {
  case data {
    "[DONE]" -> {
      use _ <- result.try(case stream.stop_reason {
        Some("stop") | Some("tool_calls") | Some("length") -> Ok(Nil)
        Some(other) -> Error("unsupported OpenAI finish reason: " <> other)
        None -> Error("OpenAI stream ended without finish_reason")
      })
      let stops =
        stream.open
        |> list.reverse
        |> list.map(fn(item) {
          frame(
            "content_block_stop",
            ir.Object([
              #("type", ir.String("content_block_stop")),
              #("index", ir.Integer(item.0)),
            ]),
          )
        })
      let reason = case stream.stop_reason {
        Some("stop") -> Some("end_turn")
        Some("tool_calls") -> Some("tool_use")
        Some("length") -> Some("max_tokens")
        Some(other) -> Some(other)
        None -> None
      }
      let delta =
        ir.Object(ir.with_optional([], "stop_reason", ir.option_string(reason)))
      let usage = case stream.usage {
        Some(usage) -> [
          #(
            "usage",
            ir.Object([#("output_tokens", ir.Integer(usage.output_tokens))]),
          ),
        ]
        None -> []
      }
      let terminal = [
        frame(
          "message_delta",
          ir.Object(list.append(
            [
              #("type", ir.String("message_delta")),
              #("delta", delta),
            ],
            usage,
          )),
        ),
        frame("message_stop", ir.Object([#("type", ir.String("message_stop"))])),
      ]
      case stream.started {
        True ->
          Ok(#(
            Stream(..stream, done: True, open: []),
            list.append(stops, terminal),
          ))
        False -> Error("OpenAI stream ended without a completion chunk")
      }
    }
    _ -> {
      use value <- result.try(ir.parse(data))
      use _ <- result.try(case ir.field(value, "error") {
        Some(_) -> Error("OpenAI upstream stream error")
        None -> Ok(Nil)
      })
      use _ <- result.try(
        check_keys(value, [
          "id",
          "object",
          "created",
          "model",
          "choices",
          "usage",
          "system_fingerprint",
        ]),
      )
      use _ <- result.try(case ir.field(value, "object") {
        Some(ir.String("chat.completion.chunk")) | None -> Ok(Nil)
        _ -> Error("unsupported OpenAI stream object")
      })
      let usage = case ir.field(value, "usage") {
        Some(ir.Null) | None -> Ok(stream.usage)
        Some(usage) -> {
          use input <- result.try(ir.required(usage, "prompt_tokens"))
          use input <- result.try(ir.as_int(input))
          use output <- result.try(ir.required(usage, "completion_tokens"))
          use output <- result.try(ir.as_int(output))
          use _ <- result.try(
            check_keys(usage, [
              "prompt_tokens",
              "completion_tokens",
              "total_tokens",
            ]),
          )
          use _ <- result.try(case stream.started, stream.usage {
            True, Some(previous) if previous.input_tokens == input -> Ok(Nil)
            True, _ if input == 0 -> Ok(Nil)
            True, _ ->
              Error(
                "late OpenAI prompt-token usage cannot be represented in Anthropic stream",
              )
            False, _ -> Ok(Nil)
          })
          Ok(Some(ir.Usage(input, output, [])))
        }
      }
      use usage <- result.try(usage)
      let stream = Stream(..stream, usage: usage)
      use choices <- result.try(ir.required(value, "choices"))
      use choices <- result.try(ir.as_array(choices))
      case choices {
        [] -> Ok(#(stream, []))
        [choice] -> {
          use _ <- result.try(
            check_keys(choice, ["index", "delta", "finish_reason"]),
          )
          use choice_index <- result.try(index_field(choice))
          use _ <- result.try(case choice_index {
            0 -> Ok(Nil)
            _ -> Error("multiple OpenAI stream choices unsupported")
          })
          use id <- result.try(ir.string_field(value, "id"))
          use model <- result.try(ir.string_field(value, "model"))
          use _ <- result.try(
            case stream.started, stream.id == id, stream.model == model {
              True, True, True -> Ok(Nil)
              True, _, _ -> Error("OpenAI stream id/model changed mid-stream")
              False, _, _ -> Ok(Nil)
            },
          )
          let stream = Stream(..stream, id: id, model: model)
          let initial = case stream.started {
            True -> []
            False -> [
              frame(
                "message_start",
                ir.Object([
                  #("type", ir.String("message_start")),
                  #(
                    "message",
                    ir.Object([
                      #("id", ir.String(id)),
                      #("type", ir.String("message")),
                      #("role", ir.String("assistant")),
                      #("model", ir.String(model)),
                      #("content", ir.Array([])),
                      #("stop_reason", ir.Null),
                      #("stop_sequence", ir.Null),
                      #(
                        "usage",
                        ir.Object([
                          #(
                            "input_tokens",
                            ir.Integer(case stream.usage {
                              Some(usage) -> usage.input_tokens
                              None -> 0
                            }),
                          ),
                          #("output_tokens", ir.Integer(0)),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ]
          }
          let stream = Stream(..stream, started: True)
          use delta <- result.try(ir.required(choice, "delta"))
          use _ <- result.try(
            check_keys(delta, ["role", "content", "tool_calls"]),
          )
          use _ <- result.try(case ir.field(delta, "role") {
            Some(ir.String("assistant")) | None -> Ok(Nil)
            _ -> Error("OpenAI stream delta role must be assistant")
          })
          let content = case ir.field(delta, "content") {
            Some(ir.String(text)) -> text
            None | Some(ir.Null) -> ""
            _ -> ""
          }
          use _ <- result.try(case ir.field(delta, "content") {
            None | Some(ir.Null) | Some(ir.String(_)) -> Ok(Nil)
            _ -> Error("unsupported OpenAI stream content")
          })
          let text_index = list.find(stream.open, fn(item) { item.1 == "text" })
          let #(stream, text_frames) = case content, text_index {
            "", _ -> #(stream, [])
            _, Error(_) -> {
              let index = stream.next_index
              let stream =
                Stream(..stream, next_index: index + 1, open: [#(index, "text")])
              #(stream, [
                frame(
                  "content_block_start",
                  ir.Object([
                    #("type", ir.String("content_block_start")),
                    #("index", ir.Integer(index)),
                    #(
                      "content_block",
                      ir.Object([
                        #("type", ir.String("text")),
                        #("text", ir.String("")),
                      ]),
                    ),
                  ]),
                ),
                frame(
                  "content_block_delta",
                  ir.Object([
                    #("type", ir.String("content_block_delta")),
                    #("index", ir.Integer(index)),
                    #(
                      "delta",
                      ir.Object([
                        #("type", ir.String("text_delta")),
                        #("text", ir.String(content)),
                      ]),
                    ),
                  ]),
                ),
              ])
            }
            _, Ok(item) -> {
              let index = item.0
              #(stream, [
                frame(
                  "content_block_delta",
                  ir.Object([
                    #("type", ir.String("content_block_delta")),
                    #("index", ir.Integer(index)),
                    #(
                      "delta",
                      ir.Object([
                        #("type", ir.String("text_delta")),
                        #("text", ir.String(content)),
                      ]),
                    ),
                  ]),
                ),
              ])
            }
          }
          let calls = case ir.field(delta, "tool_calls") {
            Some(ir.Array(calls)) -> Ok(calls)
            None -> Ok([])
            _ -> Error("tool_calls stream delta must be array")
          }
          use calls <- result.try(calls)
          use pair <- result.try(translate_calls(stream, calls, []))
          use reason <- result.try(ir.optional_string(choice, "finish_reason"))
          use _ <- result.try(case reason {
            Some("stop") | Some("tool_calls") | Some("length") | None -> Ok(Nil)
            Some(other) -> Error("unsupported OpenAI finish reason: " <> other)
          })
          let stream =
            Stream(..pair.0, stop_reason: case reason {
              Some(reason) -> Some(reason)
              None -> stream.stop_reason
            })
          Ok(#(stream, list.append(initial, list.append(text_frames, pair.1))))
        }
        _ -> Error("multiple OpenAI stream choices unsupported")
      }
    }
  }
}

fn translate_calls(
  stream: Stream,
  calls: List(ir.Value),
  frames: List(String),
) -> Result(#(Stream, List(String)), String) {
  case calls {
    [] -> Ok(#(stream, frames))
    [call, ..rest] -> {
      use _ <- result.try(check_keys(call, ["index", "id", "type", "function"]))
      use original <- result.try(index_field(call))
      use function <- result.try(ir.required(call, "function"))
      use _ <- result.try(check_keys(function, ["name", "arguments"]))
      use _ <- result.try(case ir.field(call, "type") {
        Some(ir.String("function")) | None -> Ok(Nil)
        _ -> Error("unsupported OpenAI streamed tool type")
      })
      let mapped = list.find(stream.tools, fn(item) { item.0 == original })
      let #(stream, start) = case mapped {
        Ok(_) -> #(stream, [])
        Error(_) -> {
          // A call's first chunk must carry its identity. Do not invent one.
          case ir.field(call, "id"), ir.field(function, "name") {
            Some(ir.String(id)), Some(ir.String(name)) -> {
              let index = stream.next_index
              let stream =
                Stream(
                  ..stream,
                  next_index: index + 1,
                  tools: [#(original, index), ..stream.tools],
                  open: [#(index, "tool"), ..stream.open],
                )
              #(stream, [
                frame(
                  "content_block_start",
                  ir.Object([
                    #("type", ir.String("content_block_start")),
                    #("index", ir.Integer(index)),
                    #(
                      "content_block",
                      ir.Object([
                        #("type", ir.String("tool_use")),
                        #("id", ir.String(id)),
                        #("name", ir.String(name)),
                        #("input", ir.Object([])),
                      ]),
                    ),
                  ]),
                ),
              ])
            }
            _, _ -> #(stream, [])
          }
        }
      }
      use mapped <- result.try(
        case list.find(stream.tools, fn(item) { item.0 == original }) {
          Ok(mapped) -> Ok(mapped.1)
          Error(_) -> Error("OpenAI tool delta before id/name")
        },
      )
      let delta = case ir.field(function, "arguments") {
        Some(ir.String(partial)) -> [
          frame(
            "content_block_delta",
            ir.Object([
              #("type", ir.String("content_block_delta")),
              #("index", ir.Integer(mapped)),
              #(
                "delta",
                ir.Object([
                  #("type", ir.String("input_json_delta")),
                  #("partial_json", ir.String(partial)),
                ]),
              ),
            ]),
          ),
        ]
        _ -> []
      }
      translate_calls(
        stream,
        rest,
        list.append(frames, list.append(start, delta)),
      )
    }
  }
}

fn require_started(stream: Stream) -> Result(Nil, String) {
  case stream.started {
    True -> Ok(Nil)
    False -> Error("stream content before message start")
  }
}

fn index_field(value: ir.Value) -> Result(Int, String) {
  use index <- result.try(ir.required(value, "index"))
  ir.as_int(index)
}

fn check_keys(value: ir.Value, allowed: List(String)) -> Result(Nil, String) {
  case ir.extras(value, allowed) {
    [] -> Ok(Nil)
    [field, ..] -> Error("unsupported stream extension: " <> field.0)
  }
}

/// EOF is valid only after a terminal event and a complete SSE frame.
pub fn finish(stream: Stream) -> Result(List(String), String) {
  case stream.source, stream.target {
    Gemini, _ | _, Gemini -> Error("Gemini dialect is not implemented")
    _, _ ->
      case stream.done, stream.pending_line, stream.lines {
        True, "", [] -> Ok([])
        False, _, _ -> Error("SSE stream ended before terminal marker")
        _, _, _ -> Error("SSE stream ended with an incomplete frame")
      }
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["help"] | [] ->
      Ok(
        "dialect: use mimic/dialect/anthropic, mimic/dialect/openai, or the incremental SSE API",
      )
    _ -> Error("unsupported dialect CLI command")
  }
}
