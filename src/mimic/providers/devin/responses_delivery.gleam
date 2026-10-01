/// F25 cooperative publication budget. Native ownership/read/cancel still
/// belongs to the existing F23 client; this module owns only frame delivery.
/// No watchdog, socket, credential manager, parser or mutable counter is added.
import gleam/option.{None, Some}
import mimic/protocol/responses/http.{type Control, Cancel, Continue}
import mimic/providers/contracts as c
import mimic/providers/devin/client
import mimic/providers/devin/responses_stream as projection

type Unit {
  Millisecond
}

pub type Outcome {
  Finished
  Cancelled
  Failed(error: c.Failure, next_sequence: Int, terminal_attempted: Bool)
}

type Delivery {
  Delivered(next_sequence: Int)
  Stopped
  Rejected(error: c.Failure, next_sequence: Int, terminal_attempted: Bool)
}

pub fn run(
  opened: client.Client(projection.State),
  deadline: Int,
  emit: fn(String) -> Result(Control, String),
) -> Outcome {
  run_with_clock(opened, deadline, fn() { monotonic_time(Millisecond) }, emit)
}

/// Trusted deterministic test clock, never an inbound request option.
pub fn run_with_clock(
  opened: client.Client(projection.State),
  deadline: Int,
  now: fn() -> Int,
  emit: fn(String) -> Result(Control, String),
) -> Outcome {
  pull(opened, deadline, now, emit, 0)
}

fn pull(
  opened: client.Client(projection.State),
  deadline: Int,
  now: fn() -> Int,
  emit: fn(String) -> Result(Control, String),
  sequence: Int,
) -> Outcome {
  case now() >= deadline {
    True -> {
      client.cancel(opened)
      Failed(expired(), sequence, False)
    }
    False -> {
      let batch = client.next(opened)
      // F25 is delayed: a successful terminal batch contains the entire
      // qualified stream, with the sole terminal frame last. Failures contain
      // no success frames. Sequence counts actual completed callbacks.
      let final_batch = batch.done && batch.error == None
      case deliver(batch.frames, deadline, now, emit, sequence, final_batch) {
        Stopped -> {
          client.cancel(batch.client)
          Cancelled
        }
        Rejected(error, sequence, terminal_attempted) -> {
          client.cancel(batch.client)
          Failed(error, sequence, terminal_attempted)
        }
        Delivered(sequence) ->
          case batch.error {
            Some(error) -> Failed(error, sequence, False)
            None ->
              case batch.done {
                True -> Finished
                False -> pull(batch.client, deadline, now, emit, sequence)
              }
          }
      }
    }
  }
}

fn deliver(
  frames: List(String),
  deadline: Int,
  now: fn() -> Int,
  emit: fn(String) -> Result(Control, String),
  sequence: Int,
  final_batch: Bool,
) -> Delivery {
  case frames {
    [] -> Delivered(sequence)
    [frame, ..rest] ->
      case now() >= deadline {
        True -> Rejected(expired(), sequence, False)
        False -> {
          let terminal = final_batch && rest == []
          case emit(frame) {
            // A failed write has uncertain publication progress. Do not
            // fabricate its next sequence or append a second error frame.
            Error(_) -> Stopped
            Ok(Cancel) -> Stopped
            Ok(Continue) ->
              case terminal {
                // The final callback BEGAN within budget. Its bytes cannot be
                // recalled or the callback hard-preempted. Never append an
                // error after a possibly delivered terminal. Wire flush and
                // callback return time are explicitly not this cooperative SLA.
                True -> Delivered(sequence + 1)
                False ->
                  case now() >= deadline {
                    True -> Rejected(expired(), sequence + 1, False)
                    False ->
                      deliver(
                        rest,
                        deadline,
                        now,
                        emit,
                        sequence + 1,
                        final_batch,
                      )
                  }
              }
          }
        }
      }
  }
}

fn expired() -> c.Failure {
  c.Failure(c.Unavailable, c.Started, None)
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int
