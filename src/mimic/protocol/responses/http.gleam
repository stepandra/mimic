import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/protocol/responses/sparse
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
  open_sse_with_policy(status, headers, stream.Strict)
}

pub fn open_sse_with_policy(
  status: Int,
  headers: List(Header),
  policy: stream.Policy,
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
  stream.new_with_policy(policy)
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
  pump(state, handle, next, cancel, False, Nil, fn(_, event) {
    emit(event) |> result.map(fn(control) { #(Nil, control) })
  })
  |> result.map(fn(pair) { pair.0 })
}

/// Caller-owned accumulation without side effects that prematurely grant receipts.
/// Unlike run, this waits for transport EOF after the protocol terminal. The
/// accumulator is returned only after successful framing/terminal validation
/// (or explicit local Cancel, whose outcome is Cancelled). A later malformed
/// frame, I/O failure or downstream failure returns no accumulator.
/// Keep accumulated native history bounded; this function is not a receipt store.
pub fn run_fold(
  state: stream.Stream,
  handle: handle,
  next: fn(handle) -> Result(Option(#(BitArray, handle)), upstream_error),
  cancel: fn(handle) -> Nil,
  initial: accumulator,
  emit: fn(accumulator, stream.Event) -> Result(#(accumulator, Control), String),
) -> Result(#(stream.Outcome, accumulator), Failure(upstream_error)) {
  pump(state, handle, next, cancel, True, initial, emit)
}

/// Wire completion is distinct from reconstruction/receipt eligibility. A
/// terminal report on an emitted event is provisional until this returns at
/// clean EOF. Failure returns no report/accumulator; Cancel returns no authority.
pub fn run_wire_fold(
  state: stream.Stream,
  handle: handle,
  next: fn(handle) -> Result(Option(#(BitArray, handle)), upstream_error),
  cancel: fn(handle) -> Nil,
  initial: accumulator,
  emit: fn(accumulator, stream.WireEvent) ->
    Result(#(accumulator, Control), String),
) -> Result(
  #(stream.Outcome, Option(sparse.Report), accumulator),
  Failure(upstream_error),
) {
  case next(handle) {
    Error(error) -> {
      cancel(handle)
      Error(Upstream(error))
    }
    Ok(None) -> {
      cancel(handle)
      stream.finish(state)
      |> result.map(fn(outcome) {
        #(outcome, stream.terminal_report(state), initial)
      })
      |> result.map_error(Protocol)
    }
    Ok(Some(#(bytes, current))) -> {
      let batch = stream.feed_wire_partial(state, bytes)
      case deliver_wire(batch.events, initial, emit) {
        Error(error) -> {
          cancel(current)
          Error(Downstream(error))
        }
        Ok(#(accumulated, Cancel)) -> {
          cancel(current)
          Ok(#(stream.Cancelled, None, accumulated))
        }
        Ok(#(accumulated, Continue)) ->
          case batch.next {
            Error(error) -> {
              cancel(current)
              Error(Protocol(error))
            }
            Ok(state) ->
              run_wire_fold(state, current, next, cancel, accumulated, emit)
          }
      }
    }
  }
}

fn deliver_wire(
  events: List(stream.WireEvent),
  accumulated: accumulator,
  emit: fn(accumulator, stream.WireEvent) ->
    Result(#(accumulator, Control), String),
) -> Result(#(accumulator, Control), String) {
  case events {
    [] -> Ok(#(accumulated, Continue))
    [event, ..rest] -> {
      use pair <- result.try(emit(accumulated, event))
      case pair.1 {
        Cancel -> Ok(pair)
        Continue -> deliver_wire(rest, pair.0, emit)
      }
    }
  }
}

fn pump(
  state: stream.Stream,
  handle: handle,
  next: fn(handle) -> Result(Option(#(BitArray, handle)), upstream_error),
  cancel: fn(handle) -> Nil,
  wait_for_eof: Bool,
  accumulated: accumulator,
  emit: fn(accumulator, stream.Event) -> Result(#(accumulator, Control), String),
) -> Result(#(stream.Outcome, accumulator), Failure(upstream_error)) {
  case stream.outcome(state), wait_for_eof {
    Some(_), False -> {
      cancel(handle)
      stream.finish(state)
      |> result.map(fn(outcome) { #(outcome, accumulated) })
      |> result.map_error(Protocol)
    }
    _, _ ->
      case next(handle) {
        Error(error) -> {
          cancel(handle)
          Error(Upstream(error))
        }
        Ok(None) -> {
          cancel(handle)
          stream.finish(state)
          |> result.map(fn(outcome) { #(outcome, accumulated) })
          |> result.map_error(Protocol)
        }
        Ok(Some(#(bytes, current))) -> {
          let batch = stream.feed_partial(state, bytes)
          case deliver(batch.events, accumulated, emit) {
            Error(error) -> {
              cancel(current)
              Error(Downstream(error))
            }
            Ok(#(accumulated, Cancel)) -> {
              cancel(current)
              Ok(#(stream.Cancelled, accumulated))
            }
            Ok(#(accumulated, Continue)) -> {
              case batch.next {
                Error(error) -> {
                  cancel(current)
                  Error(Protocol(error))
                }
                Ok(state) ->
                  pump(
                    state,
                    current,
                    next,
                    cancel,
                    wait_for_eof,
                    accumulated,
                    emit,
                  )
              }
            }
          }
        }
      }
  }
}

fn deliver(
  events: List(stream.Event),
  accumulated: accumulator,
  emit: fn(accumulator, stream.Event) -> Result(#(accumulator, Control), String),
) -> Result(#(accumulator, Control), String) {
  case events {
    [] -> Ok(#(accumulated, Continue))
    [event, ..rest] -> {
      use pair <- result.try(emit(accumulated, event))
      let #(accumulated, control) = pair
      case control {
        Cancel -> Ok(pair)
        Continue -> deliver(rest, accumulated, emit)
      }
    }
  }
}
