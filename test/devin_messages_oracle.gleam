/// Independent strict construction oracle, based on pinned SDK accumulation:
/// Python 18f25547 and TS d49bdab4 append starts then address deltas by index;
/// TS callbacks use the LAST content block. This is not the permissive Claude
/// observer and does not call provider construction helpers.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir

pub opaque type State {
  State(
    message: Option(ir.Value),
    content: List(ir.Value),
    open: Option(Int),
    delta: Bool,
    stopped: Bool,
    failed: Bool,
    callbacks: List(ir.Value),
  )
}

pub fn new() -> State {
  State(None, [], None, False, False, False, [])
}

pub fn feed(state: State, frame: String) -> Result(State, String) {
  use _ <- result.try(check(!state.stopped && !state.failed, "after terminal"))
  let lines = string.split(frame, "\n")
  let names =
    list.filter_map(lines, fn(line) {
      case string.starts_with(line, "event: ") {
        True -> Ok(string.drop_start(line, 7))
        False -> Error(Nil)
      }
    })
  let data =
    list.filter_map(lines, fn(line) {
      case string.starts_with(line, "data: ") {
        True -> Ok(string.drop_start(line, 6))
        False -> Error(Nil)
      }
    })
  use value <- result.try(ir.parse(string.join(data, "\n")))
  use kind <- result.try(ir.string_field(value, "type"))
  use _ <- result.try(check(names == [kind], "event/payload disagreement"))
  case kind {
    "error" -> Ok(State(..state, failed: True))
    "message_start" -> {
      use _ <- result.try(check(state.message == None, "duplicate message"))
      use message <- result.try(ir.required(value, "message"))
      use _ <- result.try(identity(message))
      use _ <- result.try(check(
        ir.field(message, "content") == Some(ir.Array([]))
          && ir.field(message, "stop_reason") == Some(ir.Null)
          && ir.field(message, "stop_sequence") == Some(ir.Null),
        "invalid initialized message",
      ))
      use usage <- result.try(ir.required(message, "usage"))
      use _ <- result.try(exact_usage(usage))
      Ok(State(..state, message: Some(message)))
    }
    "content_block_start" -> {
      use _ <- result.try(check(
        state.message != None && state.open == None && !state.delta,
        "overlapping/start after delta",
      ))
      use index <- result.try(int_field(value, "index"))
      use _ <- result.try(check(
        index == list.length(state.content),
        "nonsequential index",
      ))
      use block <- result.try(ir.required(value, "content_block"))
      use kind <- result.try(ir.string_field(block, "type"))
      use _ <- result.try(case kind {
        "text" -> ir.string_field(block, "text") |> result.replace(Nil)
        "thinking" -> {
          use _ <- result.try(ir.string_field(block, "thinking"))
          ir.string_field(block, "signature") |> result.replace(Nil)
        }
        "tool_use" -> {
          use id <- result.try(ir.string_field(block, "id"))
          use name <- result.try(ir.string_field(block, "name"))
          use _ <- result.try(check(
            id != "" && name != "",
            "missing tool identity",
          ))
          use input <- result.try(ir.required(block, "input"))
          ir.as_object(input) |> result.replace(Nil)
        }
        _ -> Error("unknown block")
      })
      Ok(
        State(
          ..state,
          open: Some(index),
          content: list.append(state.content, [block]),
        ),
      )
    }
    "content_block_delta" -> {
      use index <- result.try(int_field(value, "index"))
      use _ <- result.try(check(
        state.open == Some(index) && index == list.length(state.content) - 1,
        "delta not for the last open block (TS callback mismatch)",
      ))
      use block <- result.try(
        list.last(state.content) |> result.replace_error("no block"),
      )
      use kind <- result.try(ir.string_field(block, "type"))
      use delta <- result.try(ir.required(value, "delta"))
      use delta_kind <- result.try(ir.string_field(delta, "type"))
      use updated <- result.try(case kind, delta_kind {
        "text", "text_delta" -> append(block, delta, "text")
        "thinking", "thinking_delta" -> append(block, delta, "thinking")
        "thinking", "signature_delta" -> {
          use signature <- result.try(ir.string_field(delta, "signature"))
          Ok(set(block, "signature", ir.String(signature)))
        }
        "tool_use", "input_json_delta" -> {
          // F24 deliberately emits one complete, validated JSON fragment per
          // tool, so partial SDK JSON parsers must produce this exact object.
          use text <- result.try(ir.string_field(delta, "partial_json"))
          use input <- result.try(ir.parse(text))
          use _ <- result.try(ir.as_object(input))
          Ok(set(block, "input", input))
        }
        _, _ -> Error("unknown/misassociated delta")
      })
      Ok(
        State(
          ..state,
          content: list.index_map(state.content, fn(old, i) {
            case i == index {
              True -> updated
              False -> old
            }
          }),
        ),
      )
    }
    "content_block_stop" -> {
      use index <- result.try(int_field(value, "index"))
      use _ <- result.try(check(
        state.open == Some(index),
        "stop without open block",
      ))
      use last <- result.try(
        list.last(state.content) |> result.replace_error("no block"),
      )
      use _ <- result.try(case ir.field(last, "type") {
        Some(ir.String("thinking")) -> {
          use signature <- result.try(ir.string_field(last, "signature"))
          check(signature != "", "unsigned thinking success")
        }
        _ -> Ok(Nil)
      })
      // Exactly what TS contentBlock emits (.at(-1)), not an indexed repair.
      Ok(
        State(
          ..state,
          open: None,
          callbacks: list.append(state.callbacks, [last]),
        ),
      )
    }
    "message_delta" -> {
      use message <- result.try(option.to_result(
        state.message,
        "no initialized message",
      ))
      use _ <- result.try(check(
        state.open == None && !state.delta,
        "unfinished content",
      ))
      use usage <- result.try(ir.required(value, "usage"))
      use _ <- result.try(exact_usage(usage))
      use delta <- result.try(ir.required(value, "delta"))
      use reason <- result.try(ir.string_field(delta, "stop_reason"))
      use _ <- result.try(check(
        list.contains(["end_turn", "tool_use", "max_tokens"], reason),
        "bad reason",
      ))
      use _ <- result.try(check(
        ir.field(delta, "stop_sequence") == Some(ir.Null),
        "bad stop sequence",
      ))
      use initial <- result.try(ir.required(message, "usage"))
      // SDKs overwrite cumulative counters, not arbitrary usage extensions.
      use input <- result.try(ir.required(usage, "input_tokens"))
      use output <- result.try(ir.required(usage, "output_tokens"))
      let updated_usage =
        set(set(initial, "input_tokens", input), "output_tokens", output)
      Ok(
        State(
          ..state,
          delta: True,
          message: Some(set(
            set(message, "stop_reason", ir.String(reason)),
            "usage",
            updated_usage,
          )),
        ),
      )
    }
    "message_stop" -> {
      use _ <- result.try(check(
        state.message != None && state.open == None && state.delta,
        "premature success",
      ))
      Ok(State(..state, stopped: True))
    }
    _ -> Error("unknown event")
  }
}

fn identity(message: ir.Value) {
  use id <- result.try(ir.string_field(message, "id"))
  use model <- result.try(ir.string_field(message, "model"))
  check(
    id != ""
      && model != ""
      && ir.field(message, "type") == Some(ir.String("message"))
      && ir.field(message, "role") == Some(ir.String("assistant")),
    "invalid identity",
  )
}

fn exact_usage(value: ir.Value) {
  use input <- result.try(int_field(value, "input_tokens"))
  use output <- result.try(int_field(value, "output_tokens"))
  check(input >= 0 && output >= 0, "invalid exact usage")
}

fn int_field(value: ir.Value, name: String) {
  ir.required(value, name) |> result.try(ir.as_int)
}

fn append(block: ir.Value, delta: ir.Value, field: String) {
  use old <- result.try(ir.string_field(block, field))
  use text <- result.try(ir.string_field(delta, field))
  Ok(set(block, field, ir.String(old <> text)))
}

fn set(value: ir.Value, name: String, new: ir.Value) -> ir.Value {
  let assert ir.Object(fields) = value
  ir.Object(
    list.map(fields, fn(field) {
      case field.0 == name {
        True -> #(name, new)
        False -> field
      }
    }),
  )
}

fn check(ok: Bool, error: String) {
  case ok {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

pub fn finish(state: State) -> Result(ir.Value, String) {
  use _ <- result.try(check(
    state.stopped && !state.failed,
    "no successful terminal",
  ))
  use _ <- result.try(check(
    state.callbacks == state.content,
    "callback reconstruction differs",
  ))
  use message <- result.try(option.to_result(state.message, "no message"))
  Ok(set(message, "content", ir.Array(state.content)))
}

pub fn reconstruct(frames: List(String)) -> Result(ir.Value, String) {
  list.try_fold(frames, new(), feed) |> result.try(finish)
}
