/// Byte framing around the native Claude observer, not a second SSE codec.
/// A batch retains valid frames preceding a malformed event in the same read.
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/protocol/responses/http as lifecycle
import mimic/providers/claude/stream
import mimic/providers/runtime

pub opaque type State {
  State(
    native: stream.State,
    pending: BitArray,
    skip_lf: Bool,
    frame_bytes: Int,
    first_line: Bool,
  )
}

pub type Batch {
  Batch(frames: List(String), next: Result(State, String))
}

pub fn new() -> State {
  State(stream.new(), <<>>, False, 0, True)
}

pub fn feed_partial(state: State, chunk: BitArray) -> Batch {
  case bit_array.bit_size(chunk) % 8 {
    0 -> scan(state, chunk, [])
    _ -> Batch([], Error("Claude SSE requires bytes"))
  }
}

fn scan(state: State, chunk: BitArray, frames: List(String)) -> Batch {
  case stream.status(state.native), chunk {
    stream.Completed, _ | stream.Failed(_), _ | _, <<>> ->
      Batch(list.reverse(frames), Ok(state))
    _, <<10, rest:bits>> if state.skip_lf ->
      scan(State(..state, skip_lf: False), rest, frames)
    _, _ -> {
      let #(prefix, separator, rest) = split_line(chunk, chunk, 0)
      let size =
        state.frame_bytes
        + bit_array.byte_size(prefix)
        + case separator {
          0 -> 0
          _ -> 1
        }
      case size > 1_048_576 {
        True ->
          Batch(list.reverse(frames), Error("Claude SSE event exceeds limit"))
        False -> {
          let pending = <<state.pending:bits, prefix:bits>>
          case separator {
            0 ->
              Batch(
                list.reverse(frames),
                Ok(
                  State(
                    ..state,
                    pending: pending,
                    skip_lf: False,
                    frame_bytes: size,
                  ),
                ),
              )
            _ ->
              case bit_array.to_string(pending) {
                Error(_) ->
                  Batch(
                    list.reverse(frames),
                    Error("Claude SSE requires UTF-8"),
                  )
                Ok(raw_line) -> {
                  let line = case
                    state.first_line && string.starts_with(raw_line, "\u{FEFF}")
                  {
                    True -> string.drop_start(raw_line, 1)
                    False -> raw_line
                  }
                  case stream.feed(state.native, line <> "\n") {
                    Error(error) -> Batch(list.reverse(frames), Error(error))
                    Ok(#(native, emitted)) ->
                      scan(
                        State(
                          native,
                          <<>>,
                          separator == 13,
                          case line {
                            "" -> 0
                            _ -> size
                          },
                          False,
                        ),
                        rest,
                        list.append(list.reverse(emitted), frames),
                      )
                  }
                }
              }
          }
        }
      }
    }
  }
}

fn split_line(
  original: BitArray,
  rest: BitArray,
  size: Int,
) -> #(BitArray, Int, BitArray) {
  case rest {
    <<separator, remaining:bits>> if separator == 10 || separator == 13 -> {
      let assert Ok(prefix) = bit_array.slice(original, 0, size)
      #(prefix, separator, remaining)
    }
    <<_, remaining:bits>> -> split_line(original, remaining, size + 1)
    _ -> #(original, 0, <<>>)
  }
}

pub fn finish(state: State) -> Result(stream.Status, String) {
  case state.pending {
    <<>> -> stream.finish(state.native)
    _ -> Error("Claude SSE ended within a line")
  }
}

pub fn run(
  opened: runtime.Response,
  emit: fn(String) -> Result(lifecycle.Control, String),
) -> Result(stream.Status, String) {
  // Reuse the common strict HTTP media/encoding gate, not its Responses codec.
  case lifecycle.open_sse(opened.status, opened.headers) {
    Error(_) -> {
      runtime.cancel(opened.stream)
      Error("invalid Claude SSE headers")
    }
    Ok(_) -> consume(new(), opened.stream, emit)
  }
}

fn consume(
  state: State,
  handle: runtime.Stream,
  emit: fn(String) -> Result(lifecycle.Control, String),
) -> Result(stream.Status, String) {
  case stream.status(state.native) {
    stream.Completed | stream.Failed(_) -> {
      runtime.cancel(handle)
      finish(state)
    }
    _ ->
      case runtime.next(handle) {
        Error(_) -> {
          runtime.cancel(handle)
          Error("Claude upstream stream failed")
        }
        Ok(None) -> {
          runtime.cancel(handle)
          finish(state)
        }
        Ok(Some(bytes)) -> {
          let batch = feed_partial(state, bytes)
          case deliver(batch.frames, emit) {
            Error(_) | Ok(lifecycle.Cancel) -> {
              runtime.cancel(handle)
              Error("Claude downstream closed")
            }
            Ok(lifecycle.Continue) ->
              case batch.next {
                Error(error) -> {
                  runtime.cancel(handle)
                  Error(error)
                }
                Ok(next) -> consume(next, handle, emit)
              }
          }
        }
      }
  }
}

fn deliver(
  frames: List(String),
  emit: fn(String) -> Result(lifecycle.Control, String),
) -> Result(lifecycle.Control, String) {
  case frames {
    [] -> Ok(lifecycle.Continue)
    [frame, ..rest] -> {
      use control <- result.try(emit(frame))
      case control {
        lifecycle.Cancel -> Ok(control)
        lifecycle.Continue -> deliver(rest, emit)
      }
    }
  }
}
