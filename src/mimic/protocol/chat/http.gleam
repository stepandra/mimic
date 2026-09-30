import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir
import mimic/protocol/chat/stream
import mimic/protocol/responses/http as responses_http
import mimic/types.{type Header}

/// Reuse the existing status/media/encoding gate. Headers remain ordered.
pub fn open_sse(
  status: Int,
  headers: List(Header),
) -> Result(stream.Stream, String) {
  use _ <- result.try(responses_http.open_sse(status, headers))
  Ok(stream.new())
}

/// Pull synchronously; adopt the runtime stream before changing sender process.
/// Normal return paths cancel exactly once. Runtime owns crash/death cleanup.
pub fn run(
  state: stream.Stream,
  handle: handle,
  next: fn(handle) -> Result(Option(#(BitArray, handle)), upstream_error),
  cancel: fn(handle) -> Nil,
  restore: fn(ir.Value) -> Result(ir.Value, String),
  emit: fn(stream.Event) -> Result(responses_http.Control, String),
) -> Result(stream.Outcome, responses_http.Failure(upstream_error)) {
  case stream.outcome(state) {
    Some(_) -> {
      cancel(handle)
      stream.finish(state) |> result.map_error(responses_http.Protocol)
    }
    None ->
      case next(handle) {
        Error(error) -> {
          cancel(handle)
          Error(responses_http.Upstream(error))
        }
        Ok(None) -> {
          cancel(handle)
          stream.finish(state) |> result.map_error(responses_http.Protocol)
        }
        Ok(Some(#(bytes, current))) -> {
          let batch = stream.feed_partial(state, bytes, restore)
          case deliver(batch.events, emit) {
            Error(error) -> {
              cancel(current)
              Error(responses_http.Downstream(error))
            }
            Ok(responses_http.Cancel) -> {
              cancel(current)
              Ok(stream.Cancelled)
            }
            Ok(responses_http.Continue) ->
              case batch.next {
                Error(error) -> {
                  cancel(current)
                  Error(responses_http.Protocol(error))
                }
                Ok(state) -> run(state, current, next, cancel, restore, emit)
              }
          }
        }
      }
  }
}

fn deliver(
  events: List(stream.Event),
  emit: fn(stream.Event) -> Result(responses_http.Control, String),
) -> Result(responses_http.Control, String) {
  case events {
    [] -> Ok(responses_http.Continue)
    [event, ..rest] -> {
      use control <- result.try(emit(event))
      case control {
        responses_http.Cancel -> Ok(control)
        responses_http.Continue -> deliver(rest, emit)
      }
    }
  }
}
