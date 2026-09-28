import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/protocol/responses/stream
import mimic/types.{type Header}

pub type Control {
  Continue
  Cancel
}

pub type Failure(upstream_error) {
  Upstream(upstream_error)
  Protocol(String)
  Downstream(String)
}

/// Validate before sending downstream headers. Header lists are not rewritten.
/// Non-2xx errors belong to the runtime/provider's status classifier.
pub fn open_sse(
  status: Int,
  headers: List(Header),
) -> Result(stream.Stream, String) {
  use _ <- result.try(case status >= 200 && status < 300 {
    True -> Ok(Nil)
    False -> Error("Responses upstream HTTP status is not successful")
  })
  let content_types = values(headers, "content-type")
  use _ <- result.try(case content_types {
    [content_type] -> {
      let media =
        content_type
        |> string.split(";")
        |> list.first
        |> result.unwrap("")
        |> string.trim
        |> string.lowercase
      use _ <- result.try(
        content_type
        |> string.split(";")
        |> list.drop(1)
        |> list.try_each(fn(parameter) {
          let parameter = parameter |> string.trim |> string.lowercase
          case string.split_once(parameter, "=") {
            Ok(#("charset", encoding)) ->
              case string.trim(encoding) {
                "utf-8" | "\"utf-8\"" -> Ok(Nil)
                _ -> Error("Responses SSE requires UTF-8 charset")
              }
            _ -> Ok(Nil)
          }
        }),
      )
      case media == "text/event-stream" {
        True -> Ok(Nil)
        False -> Error("Responses upstream is not text/event-stream")
      }
    }
    _ -> Error("Responses upstream requires one Content-Type")
  })
  use _ <- result.try(case values(headers, "content-encoding") {
    [] -> Ok(Nil)
    [encoding] ->
      case string.lowercase(string.trim(encoding)) == "identity" {
        True -> Ok(Nil)
        False -> Error("encoded Responses SSE requires explicit decompression")
      }
    _ -> Error("ambiguous Responses Content-Encoding")
  })
  Ok(stream.new())
}

fn values(headers: List(Header), name: String) -> List(String) {
  headers
  |> list.filter(fn(h) { string.lowercase(h.name) == name })
  |> list.map(fn(h) { h.value })
}

/// Pull-driven lifecycle, usable with the runtime's opaque owned stream.
/// Exactly one next call at a time; emit must complete before another pull.
/// The runtime must provide idempotent cancel and process-death cleanup.
/// Returning Cancel represents local cancellation/disconnect, not completion.
pub fn run(
  state: stream.Stream,
  handle: handle,
  next: fn(handle) -> Result(Option(#(BitArray, handle)), upstream_error),
  cancel: fn(handle) -> Nil,
  emit: fn(stream.Event) -> Result(Control, String),
) -> Result(stream.Outcome, Failure(upstream_error)) {
  case stream.outcome(state) {
    Some(_) -> {
      cancel(handle)
      stream.finish(state) |> result.map_error(Protocol)
    }
    None ->
      case next(handle) {
        Error(error) -> {
          cancel(handle)
          Error(Upstream(error))
        }
        Ok(None) -> {
          cancel(handle)
          stream.finish(state) |> result.map_error(Protocol)
        }
        Ok(Some(#(bytes, current))) -> {
          let batch = stream.feed_partial(state, bytes)
          case deliver(batch.events, emit) {
            Error(error) -> {
              cancel(current)
              Error(Downstream(error))
            }
            Ok(Cancel) -> {
              cancel(current)
              Ok(stream.Cancelled)
            }
            Ok(Continue) -> {
              case batch.next {
                Error(error) -> {
                  cancel(current)
                  Error(Protocol(error))
                }
                Ok(state) -> run(state, current, next, cancel, emit)
              }
            }
          }
        }
      }
  }
}

fn deliver(
  events: List(stream.Event),
  emit: fn(stream.Event) -> Result(Control, String),
) -> Result(Control, String) {
  case events {
    [] -> Ok(Continue)
    [event, ..rest] -> {
      use control <- result.try(emit(event))
      case control {
        Cancel -> Ok(Cancel)
        Continue -> deliver(rest, emit)
      }
    }
  }
}
