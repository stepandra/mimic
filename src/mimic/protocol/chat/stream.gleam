/// Native Chat stream validation. Unknown fields remain in each document.
/// This is not a Chat-to-Responses projection or a provider normalizer.
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/protocol/sse

pub type Event {
  Event(document: ir.Value)
  ErrorEvent(document: ir.Value)
  /// Named SSE dispatch differs from the default "message" event.
  NamedErrorEvent(document: ir.Value)
  Done
}

pub type Outcome {
  Completed
  Incomplete
  RemoteError
  Cancelled
}

pub type Batch {
  Batch(events: List(Event), next: Result(Stream, String))
}

type Tool {
  Tool(id: String, name: String)
}

type Choice {
  Choice(finish: Option(String), tools: Dict(Int, Tool))
}

pub opaque type Stream {
  Stream(
    framing: sse.Decoder,
    id: Option(String),
    model: Option(String),
    choices: Dict(Int, Choice),
    outcome: Option(Outcome),
    max_frame_bytes: Int,
    max_choices: Int,
    max_tools: Int,
  )
}

pub fn new() -> Stream {
  new_with_limits(1_048_576, 128, 4096)
}

pub fn new_with_limits(
  max_frame_bytes: Int,
  max_choices: Int,
  max_tools: Int,
) -> Stream {
  Stream(
    sse.new(max_frame_bytes),
    None,
    None,
    dict.new(),
    None,
    max_frame_bytes,
    max_choices,
    max_tools,
  )
}

/// Provider restoration runs before shared semantic validation and emission.
/// The caller must emit events before inspecting next, then discard error state.
pub fn feed_partial(
  state: Stream,
  bytes: BitArray,
  restore: fn(ir.Value) -> Result(ir.Value, String),
) -> Batch {
  frames(state, bytes, restore, [])
}

fn frames(
  state: Stream,
  bytes: BitArray,
  restore: fn(ir.Value) -> Result(ir.Value, String),
  events: List(Event),
) -> Batch {
  case sse.feed_one(state.framing, bytes) {
    Error(error) -> Batch(list.reverse(events), Error(error))
    Ok(#(framing, frame, rest)) -> {
      let state = Stream(..state, framing: framing)
      case frame {
        None -> Batch(list.reverse(events), Ok(state))
        Some(frame) ->
          case dispatch(state, frame, restore) {
            Error(error) -> Batch(list.reverse(events), Error(error))
            Ok(#(next, event)) ->
              frames(next, rest, restore, case event {
                None -> events
                Some(event) -> [event, ..events]
              })
          }
      }
    }
  }
}

fn dispatch(
  state: Stream,
  frame: sse.Frame,
  restore: fn(ir.Value) -> Result(ir.Value, String),
) -> Result(#(Stream, Option(Event)), String) {
  case frame.data {
    "" -> Ok(#(state, None))
    _ -> {
      use _ <- result.try(ensure(
        state.outcome == None,
        "Chat event after terminal",
      ))
      case frame.data {
        "[DONE]" -> {
          use _ <- result.try(ensure(
            dict.size(state.choices) > 0
              && list.all(dict.values(state.choices), fn(c) { c.finish != None }),
            "Chat DONE before all choices finished",
          ))
          let incomplete =
            list.any(dict.values(state.choices), fn(c) {
              c.finish == Some("length") || c.finish == Some("content_filter")
            })
          let outcome = case incomplete {
            True -> Incomplete
            False -> Completed
          }
          Ok(#(Stream(..state, outcome: Some(outcome)), Some(Done)))
        }
        _ -> {
          use _ <- result.try(ensure(
            frame.name == "" || frame.name == "message" || frame.name == "error",
            "unsupported Chat SSE event name",
          ))
          use document <- result.try(ir.parse_bounded(
            frame.data,
            state.max_frame_bytes,
            128,
            65_536,
          ))
          use document <- result.try(restore(document))
          // Also reject duplicate keys constructed by a restoration callback.
          use document <- result.try(ir.parse_bounded(
            ir.stringify(document),
            state.max_frame_bytes,
            128,
            65_536,
          ))
          use _ <- result.try(ir.as_object(document))
          case ir.field(document, "error") {
            Some(error) -> {
              use _ <- result.try(ir.as_object(error))
              use message <- result.try(ir.string_field(error, "message"))
              use _ <- result.try(ensure(
                message != "",
                "empty Chat error message",
              ))
              let event = case frame.name {
                "error" -> NamedErrorEvent(document)
                _ -> ErrorEvent(document)
              }
              Ok(#(Stream(..state, outcome: Some(RemoteError)), Some(event)))
            }
            None -> {
              use _ <- result.try(ensure(
                frame.name != "error",
                "Chat error event requires an error object",
              ))
              use next <- result.try(push(state, document))
              Ok(#(next, Some(Event(document))))
            }
          }
        }
      }
    }
  }
}

fn push(state: Stream, document: ir.Value) -> Result(Stream, String) {
  use id <- result.try(nonempty(document, "id"))
  use model <- result.try(nonempty(document, "model"))
  use _ <- result.try(ensure(
    { state.id == None || state.id == Some(id) }
      && { state.model == None || state.model == Some(model) },
    "Chat stream identity changed",
  ))
  use _ <- result.try(ensure(
    ir.field(document, "object") == Some(ir.String("chat.completion.chunk")),
    "invalid Chat stream object",
  ))
  use choices <- result.try(ir.required(document, "choices"))
  use choices <- result.try(ir.as_array(choices))
  use _ <- result.try(validate_usage(document))
  use _ <- result.try(ensure(
    choices != [] || ir.field(document, "usage") != None,
    "Chat chunk has no choices or usage",
  ))
  use next <- result.try(choices_received(state, choices, []))
  use _ <- result.try(ensure(
    list.fold(dict.values(next.choices), 0, fn(count, choice) {
      count + dict.size(choice.tools)
    })
      <= state.max_tools,
    "Chat tool metadata exceeds limit",
  ))
  Ok(Stream(..next, id: Some(id), model: Some(model)))
}

fn choices_received(
  state: Stream,
  choices: List(ir.Value),
  seen: List(Int),
) -> Result(Stream, String) {
  case choices {
    [] -> Ok(state)
    [choice, ..rest] -> {
      use index <- result.try(nonnegative(choice, "index"))
      use _ <- result.try(ensure(
        index < state.max_choices && !list.contains(seen, index),
        "invalid or duplicate Chat choice index",
      ))
      let previous =
        dict.get(state.choices, index)
        |> result.unwrap(Choice(None, dict.new()))
      use _ <- result.try(ensure(
        previous.finish == None,
        "Chat choice delta after finish",
      ))
      use delta <- result.try(ir.required(choice, "delta"))
      use _ <- result.try(ir.as_object(delta))
      use _ <- result.try(optional_text(delta, "content"))
      use _ <- result.try(optional_text(delta, "reasoning_content"))
      use _ <- result.try(optional_text(delta, "refusal"))
      use _ <- result.try(case ir.field(delta, "role") {
        None | Some(ir.String("assistant")) -> Ok(Nil)
        _ -> Error("invalid Chat delta role")
      })
      use tools <- result.try(case ir.field(delta, "tool_calls") {
        None -> Ok(previous.tools)
        Some(value) -> {
          use tools <- result.try(ir.as_array(value))
          tools_received(previous.tools, tools, [], state.max_tools)
        }
      })
      use finish <- result.try(ir.optional_string(choice, "finish_reason"))
      use _ <- result.try(case finish {
        None
        | Some("stop")
        | Some("tool_calls")
        | Some("function_call")
        | Some("length")
        | Some("content_filter") -> Ok(Nil)
        _ -> Error("unsupported Chat finish reason")
      })
      choices_received(
        Stream(
          ..state,
          choices: dict.insert(state.choices, index, Choice(finish, tools)),
        ),
        rest,
        [index, ..seen],
      )
    }
  }
}

fn tools_received(
  known: Dict(Int, Tool),
  tools: List(ir.Value),
  seen: List(Int),
  limit: Int,
) -> Result(Dict(Int, Tool), String) {
  case tools {
    [] -> Ok(known)
    [tool, ..rest] -> {
      use index <- result.try(nonnegative(tool, "index"))
      use _ <- result.try(ensure(
        index < limit && !list.contains(seen, index),
        "invalid or duplicate Chat tool index",
      ))
      use _ <- result.try(case ir.field(tool, "type") {
        None | Some(ir.String("function")) -> Ok(Nil)
        _ -> Error("unsupported Chat tool type")
      })
      use function <- result.try(ir.required(tool, "function"))
      use _ <- result.try(ir.as_object(function))
      use _ <- result.try(optional_text(function, "arguments"))
      use identity <- result.try(case dict.get(known, index) {
        Error(_) -> {
          use id <- result.try(nonempty(tool, "id"))
          use name <- result.try(nonempty(function, "name"))
          use _ <- result.try(ensure(
            !list.any(dict.values(known), fn(t) { t.id == id }),
            "duplicate Chat tool id",
          ))
          Ok(Tool(id, name))
        }
        Ok(previous) -> {
          use id <- result.try(ir.optional_string(tool, "id"))
          use name <- result.try(ir.optional_string(function, "name"))
          use _ <- result.try(ensure(
            { id == None || id == Some(previous.id) }
              && { name == None || name == Some(previous.name) },
            "Chat tool identity changed",
          ))
          Ok(previous)
        }
      })
      tools_received(
        dict.insert(known, index, identity),
        rest,
        [index, ..seen],
        limit,
      )
    }
  }
}

fn validate_usage(document: ir.Value) -> Result(Nil, String) {
  case ir.field(document, "usage") {
    None | Some(ir.Null) -> Ok(Nil)
    Some(usage) -> {
      use _ <- result.try(ir.as_object(usage))
      list.try_each(
        ["prompt_tokens", "completion_tokens", "total_tokens"],
        fn(key) {
          case ir.field(usage, key) {
            None -> Ok(Nil)
            Some(_) -> nonnegative(usage, key) |> result.map(fn(_) { Nil })
          }
        },
      )
    }
  }
}

fn nonnegative(value: ir.Value, key: String) -> Result(Int, String) {
  use value <- result.try(ir.required(value, key))
  use number <- result.try(ir.as_int(value))
  case number >= 0 {
    True -> Ok(number)
    False -> Error("negative Chat integer")
  }
}

fn nonempty(value: ir.Value, key: String) -> Result(String, String) {
  use text <- result.try(ir.string_field(value, key))
  case text != "" && string.byte_size(text) <= 1024 {
    True -> Ok(text)
    False -> Error("invalid Chat identity length")
  }
}

fn optional_text(value: ir.Value, key: String) -> Result(Nil, String) {
  ir.optional_string(value, key) |> result.map(fn(_) { Nil })
}

pub fn finish(state: Stream) -> Result(Outcome, String) {
  use _ <- result.try(sse.finish(state.framing))
  case state.outcome {
    Some(outcome) -> Ok(outcome)
    None -> Error("Chat disconnected before terminal")
  }
}

pub fn outcome(state: Stream) -> Option(Outcome) {
  state.outcome
}

pub fn encode_event(event: Event) -> String {
  case event {
    Event(document) | ErrorEvent(document) ->
      "data: " <> ir.stringify(document) <> "\n\n"
    NamedErrorEvent(document) ->
      "event: error\ndata: " <> ir.stringify(document) <> "\n\n"
    Done -> "data: [DONE]\n\n"
  }
}

fn ensure(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}
