import gleam/erlang/process
import gleam/otp/actor
import mimic/auth.{type Config, type Credential}
import mimic/auth/storage.{type Store}

/// One actor per credential. Serialised refresh means concurrent callers
/// queue behind the in-flight exchange and reuse its result (singleflight).
/// The embedding supervisor owns lifecycle; no global name or dynamic atom.
pub type Worker {
  Worker(subject: process.Subject(Message))
}

type State {
  State(
    config: Config,
    store: Store,
    id: String,
    credential: Credential,
    failures: Int,
    retry_at_ms: Int,
    blocked: Bool,
  )
}

pub type Message {
  Get(now_ms: Int, reply: process.Subject(Result(Credential, String)))
}

pub fn start(
  config: Config,
  store: Store,
  id: String,
  credential: Credential,
) -> Result(Worker, String) {
  let state = State(config, store, id, credential, 0, 0, False)
  case actor.new(state) |> actor.on_message(handle) |> actor.start {
    Ok(started) -> Ok(Worker(started.data))
    Error(_) -> Error("Unable to start credential refresh worker")
  }
}

/// Caller should pass current time in integer milliseconds. Timeout includes
/// the network exchange and waiting behind one in-flight refresh.
pub fn get(worker: Worker, now_ms: Int) -> Result(Credential, String) {
  actor.call(worker.subject, waiting: 60_000, sending: fn(reply) {
    Get(now_ms, reply)
  })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Get(now_ms, reply) -> {
      let #(next, result) = get_next(state, now_ms)
      process.send(reply, result)
      actor.continue(next)
    }
  }
}

fn get_next(state: State, now_ms: Int) -> #(State, Result(Credential, String)) {
  case state.blocked {
    True -> #(state, Error("OAuth refresh requires reauthorization"))
    False if now_ms < state.credential.expires_at_ms - 60_000 -> #(
      state,
      Ok(state.credential),
    )
    False if now_ms < state.retry_at_ms -> #(
      state,
      Error("OAuth refresh is in backoff"),
    )
    False ->
      case
        auth.refresh(
          state.config,
          state.store,
          state.id,
          state.credential,
          now_ms,
        )
      {
        Ok(credential) -> #(
          State(..state, credential:, failures: 0, retry_at_ms: 0),
          Ok(credential),
        )
        Error("OAuth token endpoint rejected the grant") -> #(
          State(..state, blocked: True),
          Error("OAuth refresh requires reauthorization"),
        )
        Error(_) -> {
          let failures = state.failures + 1
          let delay = backoff(failures)
          #(
            State(..state, failures:, retry_at_ms: now_ms + delay),
            Error("OAuth refresh failed; retry later"),
          )
        }
      }
  }
}

/// 5s, 10s, 20s... capped at 5m.
pub fn backoff(failures: Int) -> Int {
  case failures {
    n if n <= 1 -> 5000
    n if n >= 7 -> 300_000
    n -> {
      let previous = backoff(n - 1) * 2
      case previous > 300_000 {
        True -> 300_000
        False -> previous
      }
    }
  }
}
