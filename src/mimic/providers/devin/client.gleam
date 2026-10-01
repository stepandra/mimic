/// Shared Devin client lifecycle. Only validated native events reach the
/// projector; Connect bytes never masquerade as client SSE.
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/protocol/responses/http.{type Control, Cancel, Continue}
import mimic/providers/contracts as c
import mimic/providers/devin/response
import mimic/providers/devin/stream as native

pub opaque type Client(state) {
  Client(
    native: native.Stream,
    state: state,
    encode: fn(state, response.Event) -> Result(#(state, List(String)), String),
    terminal: Bool,
  )
}

pub type Batch(state) {
  Batch(
    client: Client(state),
    frames: List(String),
    done: Bool,
    error: Option(c.Failure),
  )
}

/// Finished describes transport/projector completion, not model completeness.
/// A length/content-filter projection may finish with an incomplete answer.
pub type Outcome {
  Finished
  Cancelled
}

pub fn new(
  stream: native.Stream,
  state: state,
  encode: fn(state, response.Event) -> Result(#(state, List(String)), String),
) -> Client(state) {
  Client(stream, state, encode, False)
}

/// Call synchronously inside Mist init, before the opening owner can exit.
pub fn adopt(client: Client(state)) -> Result(Nil, c.Failure) {
  case native.adopt(client.native) {
    Ok(_) -> Ok(Nil)
    Error(error) -> {
      cancel(client)
      Error(c.Failure(..error, delivery: c.Started))
    }
  }
}

pub fn cancel(client: Client(state)) -> Nil {
  native.cancel(client.native)
}

/// Deliver frames once before error. Repeated terminal pulls are empty.
pub fn next(client: Client(state)) -> Batch(state) {
  case client.terminal {
    True -> Batch(client, [], True, None)
    False -> {
      let batch = native.next(client.native)
      let #(state, frames, error) =
        native.project(batch, client.state, client.encode)
      let done = batch.done || error != None
      Batch(
        Client(..client, native: batch.stream, state: state, terminal: done),
        frames,
        done,
        error,
      )
    }
  }
}

/// Shared Continue/Cancel convention. Downstream failure is Started/Cancelled,
/// and never asks the runtime to open another account or replay output.
pub fn run(
  client: Client(state),
  emit: fn(String) -> Result(Control, String),
) -> Result(Outcome, c.Failure) {
  let batch = next(client)
  case deliver(batch.frames, emit) {
    Error(_) -> {
      cancel(batch.client)
      Error(c.Failure(c.Cancelled, c.Started, None))
    }
    Ok(Cancel) -> {
      cancel(batch.client)
      Ok(Cancelled)
    }
    Ok(Continue) ->
      case batch.error {
        Some(error) -> Error(c.Failure(..error, delivery: c.Started))
        None ->
          case batch.done {
            True -> Ok(Finished)
            False -> run(batch.client, emit)
          }
      }
  }
}

fn deliver(
  frames: List(String),
  emit: fn(String) -> Result(Control, String),
) -> Result(Control, String) {
  case frames {
    [] -> Ok(Continue)
    [frame, ..rest] -> {
      use control <- result.try(emit(frame))
      case control {
        Cancel -> Ok(Cancel)
        Continue -> deliver(rest, emit)
      }
    }
  }
}
