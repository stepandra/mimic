/// Observe native frames without re-encoding their JSON or dropping extensions.
/// Transport supplies UTF-8 chunks after bounded byte framing/decompression.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect
import mimic/ir
import mimic/providers/claude/json_guard

pub type ErrorKind {
  Authentication
  RateLimit
  Overloaded
  InvalidRequest
  ApiError
  UnknownError
}

pub type Status {
  Awaiting
  Receiving
  Completed
  Failed(ErrorKind)
}

/// Optional fields distinguish absent counters from measured zero.
pub type Usage {
  Usage(
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    cache_creation_input_tokens: Option(Int),
    cache_read_input_tokens: Option(Int),
  )
}

pub opaque type State {
  State(
    parser: dialect.Stream,
    status: Status,
    usage: Usage,
    buffered_bytes: Int,
    model_restoration: Option(#(String, String)),
  )
}

pub fn new() -> State {
  State(
    dialect.new_stream(dialect.Anthropic, dialect.Anthropic),
    Awaiting,
    Usage(None, None, None, None),
    0,
    None,
  )
}

/// Opt-in request-scoped restoration, not a recursive document transform.
/// Ordinary Claude callers keep new()/feed() and their original raw frames.
pub fn new_with_model(upstream_model: String, model: String) -> State {
  State(..new(), model_restoration: Some(#(upstream_model, model)))
}

pub fn status(state: State) -> Status {
  state.status
}

pub fn usage(state: State) -> Usage {
  state.usage
}

/// Returns completed native frames. Unknown event types remain on the wire.
/// Bound each buffered event/chunk to 1 MiB; do not accumulate response content.
pub fn feed(
  state: State,
  chunk: String,
) -> Result(#(State, List(String)), String) {
  case state.status {
    Completed | Failed(_) -> Ok(#(state, []))
    _ -> feed_active(state, chunk)
  }
}

fn feed_active(
  state: State,
  chunk: String,
) -> Result(#(State, List(String)), String) {
  use _ <- result.try(
    case state.buffered_bytes + string.byte_size(chunk) <= 1_048_576 {
      True -> Ok(Nil)
      False -> Error("Claude SSE event/chunk exceeds limit")
    },
  )
  feed_lines(state, string.split(chunk, "\n"), [])
}

/// Stop at the terminal frame, not at EOF or the end of a transport chunk.
/// A trailing ping/comment must not turn success into a retryable failure.
fn feed_lines(
  state: State,
  lines: List(String),
  reversed_frames: List(String),
) -> Result(#(State, List(String)), String) {
  case state.status, lines {
    Completed, _ | Failed(_), _ | _, [] ->
      Ok(#(state, list.reverse(reversed_frames)))
    _, [line] -> feed_line(state, line, [], reversed_frames)
    _, [line, ..rest] -> feed_line(state, line <> "\n", rest, reversed_frames)
  }
}

fn feed_line(
  state: State,
  line: String,
  rest: List(String),
  reversed_frames: List(String),
) -> Result(#(State, List(String)), String) {
  use pair <- result.try(dialect.feed(state.parser, line))
  // Constant-time accounting: a comment-heavy event must not rescan all prior
  // lines on every feed. The parser clears lines only at an event boundary.
  let buffered = case pair.0.pending_line == "" && pair.0.lines == [] {
    True -> 0
    False -> state.buffered_bytes + string.byte_size(line)
  }
  let state = State(..state, parser: pair.0, buffered_bytes: buffered)
  use observed <- result.try(
    list.try_fold(pair.1, #(state, reversed_frames), fn(acc, frame) {
      use next <- result.try(observe(acc.0, frame))
      Ok(#(next.0, [next.1, ..acc.1]))
    }),
  )
  feed_lines(observed.0, rest, observed.1)
}

fn observe(state: State, frame: String) -> Result(#(State, String), String) {
  let lines = string.split(frame, "\n")
  let names =
    lines
    |> list.filter(fn(line) { string.starts_with(line, "event:") })
    |> list.map(fn(line) { string.drop_start(line, 6) |> string.trim })
  let data =
    lines
    |> list.filter(fn(line) { string.starts_with(line, "data:") })
    |> list.map(fn(line) { string.drop_start(line, 5) |> string.trim_start })
    |> string.join("\n")
  case data {
    "" -> Ok(#(state, frame))
    _ -> {
      use value <- result.try(json_guard.parse_native(data, 1_048_576))
      use kind <- result.try(ir.string_field(value, "type"))
      use _ <- result.try(case names {
        [] -> Ok(Nil)
        [name] if name == kind -> Ok(Nil)
        _ -> Error("Claude SSE event and payload type disagree")
      })
      use next <- result.try(observe_document(state, kind, value))
      use frame <- result.try(restore_model(state, kind, value, lines, frame))
      Ok(#(next, frame))
    }
  }
}

fn restore_model(
  state: State,
  kind: String,
  value: ir.Value,
  lines: List(String),
  frame: String,
) -> Result(String, String) {
  case state.model_restoration, kind {
    Some(#(upstream_model, model)), "message_start" -> {
      use message <- result.try(ir.required(value, "message"))
      use named <- result.try(ir.string_field(message, "model"))
      use _ <- result.try(case named == upstream_model {
        True -> Ok(Nil)
        False -> Error("Native Messages model does not match the request")
      })
      use fields <- result.try(ir.as_object(message))
      let message =
        ir.Object(
          list.map(fields, fn(field) {
            case field.0 {
              "model" -> #(field.0, ir.String(model))
              _ -> field
            }
          }),
        )
      use fields <- result.try(ir.as_object(value))
      let value =
        ir.Object(
          list.map(fields, fn(field) {
            case field.0 {
              "message" -> #(field.0, message)
              _ -> field
            }
          }),
        )
      // Keep event/id/retry/comments/extensions in their existing order.
      // Replace only the data lines, using the document already parsed above.
      let #(reversed, _) =
        list.fold(lines, #([], False), fn(acc, line) {
          case string.starts_with(line, "data:"), acc.1 {
            True, False -> #(["data: " <> ir.stringify(value), ..acc.0], True)
            True, True -> acc
            False, _ -> #([line, ..acc.0], acc.1)
          }
        })
      let restored = list.reverse(reversed) |> string.join("\n")
      case string.byte_size(restored) <= 1_048_576 {
        True -> Ok(restored)
        False -> Error("Restored Messages SSE event exceeds limit")
      }
    }
    _, _ -> Ok(frame)
  }
}

fn observe_document(
  state: State,
  kind: String,
  value: ir.Value,
) -> Result(State, String) {
  case state.status, kind {
    Completed, _ | Failed(_), _ ->
      Error("Claude SSE event after terminal event")
    _, "error" -> {
      use error <- result.try(ir.required(value, "error"))
      use kind <- result.try(ir.string_field(error, "type"))
      Ok(State(..state, status: Failed(error_kind(kind))))
    }
    Awaiting, "message_start" -> {
      use message <- result.try(ir.required(value, "message"))
      use usage <- result.try(merge_usage(
        state.usage,
        ir.field(message, "usage"),
      ))
      Ok(State(..state, status: Receiving, usage: usage))
    }
    Receiving, "message_delta" -> {
      use usage <- result.try(merge_usage(state.usage, ir.field(value, "usage")))
      Ok(State(..state, usage: usage))
    }
    Receiving, "message_stop" -> Ok(State(..state, status: Completed))
    _, "ping" -> Ok(state)
    _, "message_start" | Awaiting, "message_stop" | Awaiting, "message_delta" ->
      Error("Invalid Claude SSE message lifecycle")
    Awaiting, _ -> Error("Claude SSE content before message_start")
    Receiving, _ -> Ok(state)
  }
}

fn merge_usage(old: Usage, value: Option(ir.Value)) -> Result(Usage, String) {
  case value {
    None -> Ok(old)
    Some(value) -> {
      use _ <- result.try(ir.as_object(value))
      use input <- result.try(counter(value, "input_tokens", old.input_tokens))
      use output <- result.try(counter(
        value,
        "output_tokens",
        old.output_tokens,
      ))
      use creation <- result.try(counter(
        value,
        "cache_creation_input_tokens",
        old.cache_creation_input_tokens,
      ))
      use read <- result.try(counter(
        value,
        "cache_read_input_tokens",
        old.cache_read_input_tokens,
      ))
      Ok(Usage(input, output, creation, read))
    }
  }
}

fn counter(
  value: ir.Value,
  key: String,
  old: Option(Int),
) -> Result(Option(Int), String) {
  case ir.field(value, key) {
    None -> Ok(old)
    Some(ir.Integer(n)) if n >= 0 -> Ok(Some(n))
    _ -> Error("Invalid Claude usage counter")
  }
}

pub fn error_kind(kind: String) -> ErrorKind {
  case kind {
    "authentication_error" | "permission_error" -> Authentication
    "rate_limit_error" -> RateLimit
    "overloaded_error" -> Overloaded
    "invalid_request_error" | "not_found_error" | "request_too_large" ->
      InvalidRequest
    "api_error" -> ApiError
    _ -> UnknownError
  }
}

/// A stop_reason is not completion. A post-message_stop disconnect is success;
/// error is terminal but not successful. Neither permits replay after delivery.
pub fn finish(state: State) -> Result(Status, String) {
  case state.parser.pending_line, state.parser.lines, state.status {
    "", [], Completed -> Ok(Completed)
    "", [], Failed(kind) -> Ok(Failed(kind))
    _, _, _ -> Error("Claude SSE ended before a complete terminal event")
  }
}
