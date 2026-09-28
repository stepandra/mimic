import gleam/erlang/process
import gleam/otp/actor
import mimic/auth/storage.{type Store}
import mimic/quota.{type Ledger}
import mimic/types.{type WireResponse}

type State {
  State(store: Store, ledger: Ledger)
}

pub type Message {
  Observe(
    id: String,
    response: WireResponse,
    now_ms: Int,
    reply: process.Subject(Result(Ledger, String)),
  )
  Snapshot(reply: process.Subject(Ledger))
}

pub type Worker {
  Worker(subject: process.Subject(Message))
}

/// One ledger writer serializes updates and atomic snapshots. Readers can
/// request snapshots without sharing mutable state or losing concurrent writes.
pub fn start(store: Store, ledger: Ledger) -> Result(Worker, String) {
  case
    actor.new(State(store, ledger)) |> actor.on_message(handle) |> actor.start
  {
    Ok(started) -> Ok(Worker(started.data))
    Error(_) -> Error("Unable to start quota ledger worker")
  }
}

pub fn record(
  worker: Worker,
  id: String,
  response: WireResponse,
  now_ms: Int,
) -> Result(Ledger, String) {
  actor.call(worker.subject, waiting: 5000, sending: fn(reply) {
    Observe(id, response, now_ms, reply)
  })
}

pub fn snapshot(worker: Worker) -> Ledger {
  actor.call(worker.subject, waiting: 5000, sending: Snapshot)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Observe(id, response, now_ms, reply) -> {
      let next = quota.observe(state.ledger, id, response, now_ms)
      case quota.save(state.store, next) {
        Ok(_) -> {
          process.send(reply, Ok(next))
          actor.continue(State(..state, ledger: next))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Snapshot(reply) -> {
      process.send(reply, state.ledger)
      actor.continue(state)
    }
  }
}
