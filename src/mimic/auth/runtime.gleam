import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import mimic/auth/runtime_store.{
  type CredentialRecord as Record, type Revision, Deferred, NeedsReauthorization,
  Ready,
}
import mimic/auth/storage.{type Store}
import mimic/auth/worker
import mimic/providers/contracts.{
  type AuthMaterial, type Failure, type OAuthData, type Refresh, ApiKey,
  CredentialUnavailable, Failure, InvalidGrant, NotSent, OAuth, OAuthData,
  Persistence, ReauthorizationRequired, Refresh, RefreshRateLimited,
  RefreshRetryable, RefreshUnavailable, RefreshUnsupported, SessionToken,
}

pub type Policy {
  StaticKey
  StaticSession
  Refreshable(Refresh)
}

pub opaque type Worker {
  Worker(subject: process.Subject(Message), pid: process.Pid)
}

type Message {
  Get(process.Subject(Result(AuthMaterial, Failure)))
  GetVersioned(process.Subject(Result(#(AuthMaterial, Revision), Failure)))
}

type State {
  State(
    store: Store,
    key: String,
    policy: Policy,
    clock: fn() -> #(Int, Int),
    failures: Int,
    seen: Option(Revision),
    monotonic_gate: Option(#(Int, Int)),
    quarantined: Bool,
  )
}

/// Collision-free identity used for credentials, refresh workers and quotas.
/// Store identity is bound by the enclosing runtime, not put in public errors.
pub fn key(provider: String, auth_mode: String, account: String) -> String {
  json.array([provider, auth_mode, account], json.string) |> json.to_string
}

pub fn save_api_key(
  store: Store,
  key: String,
  secret: String,
) -> Result(Nil, String) {
  runtime_store.save(store, key, ApiKey(secret))
}

/// Internal runtime worker. Exactly one per scoped key under a store owner.
/// Disk is re-read on every acquisition: deletion/replacement is authoritative.
pub fn start(
  store: Store,
  key: String,
  policy: Policy,
) -> Result(Worker, Failure) {
  start_with_clock(store, key, policy, fn() { #(epoch_ms(), monotonic_ms()) })
}

/// The runtime clock returns #(epoch milliseconds, monotonic milliseconds).
/// Injection is for deterministic tests, never a request-controlled timestamp.
pub fn start_with_clock(
  store: Store,
  key: String,
  policy: Policy,
  clock: fn() -> #(Int, Int),
) -> Result(Worker, Failure) {
  case
    actor.new(State(store, key, policy, clock, 0, None, None, False))
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> Ok(Worker(started.data, started.pid))
    Error(_) -> Error(Failure(CredentialUnavailable, NotSent, None))
  }
}

pub fn stop(worker: Worker) -> Nil {
  let monitor = process.monitor(worker.pid)
  process.unlink(worker.pid)
  process.kill(worker.pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  process.demonitor_process(monitor)
}

/// Compatibility entry point. Request-supplied timestamps cannot override
/// the runtime clock or bypass a durable refresh gate.
pub fn get(worker: Worker, _now: Int) -> Result(AuthMaterial, Failure) {
  acquire(worker)
}

pub fn acquire(worker: Worker) -> Result(AuthMaterial, Failure) {
  // Monitoring avoids actor.call's exception on worker death or timeout.
  let reply = process.new_subject()
  let monitor = process.monitor(worker.pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(Failure(CredentialUnavailable, NotSent, None))
    })
  process.send(worker.subject, Get(reply))
  let answer = process.selector_receive(selector, 15_000)
  process.demonitor_process(monitor)
  answer |> result.unwrap(Error(Failure(CredentialUnavailable, NotSent, None)))
}

/// A trusted generation for scoped sessions/receipts; never derive it from a
/// token or expose it to clients. Admin saves with unchanged tokens still rotate
/// this revision. A concurrent replacement between acquisition and validation
/// fails closed, rather than pairing old material with a new generation.
pub fn acquire_versioned(
  worker: Worker,
) -> Result(#(AuthMaterial, Revision), Failure) {
  let reply = process.new_subject()
  let monitor = process.monitor(worker.pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(Failure(CredentialUnavailable, NotSent, None))
    })
  process.send(worker.subject, GetVersioned(reply))
  let answer = process.selector_receive(selector, 15_000)
  process.demonitor_process(monitor)
  answer |> result.unwrap(Error(Failure(CredentialUnavailable, NotSent, None)))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let #(next, value) = acquire_state(state)
  case message {
    Get(reply) -> process.send(reply, value)
    GetVersioned(reply) -> {
      let versioned = {
        use material <- result.try(value)
        use record <- result.try(
          runtime_store.load_record(next.store, next.key)
          |> result.replace_error(Failure(CredentialUnavailable, NotSent, None)),
        )
        case
          runtime_store.record_material(record) == material
          && next.seen == Some(runtime_store.revision(record))
          && runtime_store.record_status(record) == Ready
        {
          True -> Ok(#(material, runtime_store.revision(record)))
          False -> Error(Failure(CredentialUnavailable, NotSent, None))
        }
      }
      process.send(reply, versioned)
    }
  }
  actor.continue(next)
}

fn acquire_state(state: State) -> #(State, Result(AuthMaterial, Failure)) {
  case state.policy {
    StaticSession | StaticKey ->
      case runtime_store.load_record(state.store, state.key) {
        Ok(record) -> {
          let material = runtime_store.record_material(record)
          case state.policy, material {
            StaticSession, SessionToken(_, _) | StaticKey, ApiKey(_) -> #(
              State(..state, seen: Some(runtime_store.revision(record))),
              Ok(material),
            )
            _, _ -> #(
              state,
              Error(Failure(CredentialUnavailable, NotSent, None)),
            )
          }
        }
        Error(_) -> #(
          state,
          Error(Failure(CredentialUnavailable, NotSent, None)),
        )
      }
    Refreshable(refresh) -> oauth_acquire(state, refresh)
  }
}

fn oauth_acquire(
  state: State,
  refresh: Refresh,
) -> #(State, Result(AuthMaterial, Failure)) {
  case runtime_store.load_record(state.store, state.key) {
    Error(_) -> #(state, Error(Failure(CredentialUnavailable, NotSent, None)))
    Ok(record) ->
      case runtime_store.record_material(record) {
        OAuth(current) -> {
          let state = synchronize(state, record)
          case state.quarantined, runtime_store.record_status(record) {
            True, _ -> #(state, Error(Failure(Persistence, NotSent, None)))
            _, NeedsReauthorization -> #(
              state,
              Error(Failure(ReauthorizationRequired, NotSent, None)),
            )
            _, _ ->
              case read_clock(state) {
                Error(_) -> latch(state, record)
                Ok(sample) -> {
                  let #(state, remaining) = remaining(state, record, sample)
                  case remaining {
                    Error(_) -> latch(state, record)
                    Ok(ms) if ms > 0 -> #(
                      state,
                      Error(Failure(CredentialUnavailable, NotSent, Some(ms))),
                    )
                    Ok(_)
                      if current.credential.expires_at_ms > sample.0 + 60_000
                    -> #(state, Ok(OAuth(current)))
                    Ok(_) -> exchange(state, record, current, refresh, sample)
                  }
                }
              }
          }
        }
        _ -> #(state, Error(Failure(CredentialUnavailable, NotSent, None)))
      }
  }
}

fn synchronize(state: State, record: Record) -> State {
  let revision = runtime_store.revision(record)
  case state.seen == Some(revision) {
    True -> state
    False -> {
      let monotonic_gate = case
        state.monotonic_gate,
        runtime_store.record_status(record)
      {
        Some(#(old, due)), Deferred(until) if old == until -> Some(#(old, due))
        _, _ -> None
      }
      State(
        ..state,
        seen: Some(revision),
        failures: 0,
        quarantined: False,
        monotonic_gate: monotonic_gate,
      )
    }
  }
}

fn read_clock(state: State) -> Result(#(Int, Int), Nil) {
  use sample <- result.try(protect(state.clock))
  case
    runtime_store.valid_timestamp(sample.0)
    && sample.1 >= -runtime_store.max_timestamp_ms
    && sample.1 <= runtime_store.max_timestamp_ms
  {
    True -> Ok(sample)
    False -> Error(Nil)
  }
}

fn remaining(
  state: State,
  record: Record,
  sample: #(Int, Int),
) -> #(State, Result(Int, Nil)) {
  case runtime_store.record_status(record) {
    Deferred(until) -> {
      let wall_remaining = int.max(0, until - sample.0)
      let due = case state.monotonic_gate {
        Some(#(_, due)) -> due
        None -> sample.1 + wall_remaining
      }
      let remaining = int.max(wall_remaining, int.max(0, due - sample.1))
      case
        due <= runtime_store.max_timestamp_ms
        && remaining <= runtime_store.max_timestamp_ms
      {
        True -> #(
          State(..state, monotonic_gate: Some(#(until, due))),
          Ok(remaining),
        )
        False -> #(state, Error(Nil))
      }
    }
    _ -> #(state, Ok(0))
  }
}

fn exchange(
  state: State,
  record: Record,
  current: OAuthData,
  refresh: Refresh,
  before: #(Int, Int),
) -> #(State, Result(AuthMaterial, Failure)) {
  // Persist a recovery fence BEFORE the external, potentially rotating grant
  // exchange. A crash or failed completion write cannot make restart retry it.
  case
    runtime_store.transition(
      state.store,
      state.key,
      record,
      OAuth(current),
      NeedsReauthorization,
    )
  {
    Error(_) -> persistence_failed(state)
    Ok(armed) ->
      perform_exchange(
        State(..state, seen: Some(runtime_store.revision(armed))),
        armed,
        current,
        refresh,
        before,
      )
  }
}

fn perform_exchange(
  state: State,
  record: Record,
  current: OAuthData,
  refresh: Refresh,
  before: #(Int, Int),
) -> #(State, Result(AuthMaterial, Failure)) {
  let Refresh(callback) = refresh
  let outcome =
    protect(fn() { callback(current, before.0) })
    |> result.unwrap(Error(RefreshUnavailable))
  // Always sample AFTER the callback; caller timestamps never set deadlines.
  case read_clock(state) {
    Error(_) -> latch(state, record)
    Ok(after) if after.1 < before.1 -> latch(state, record)
    Ok(after)
      if before.0 + after.1 - before.1 > runtime_store.max_timestamp_ms
    -> latch(state, record)
    Ok(after) -> {
      let completion = completion_epoch(before, after)
      case outcome {
        Error(InvalidGrant)
        | Error(RefreshUnsupported)
        | Error(RefreshUnavailable) -> latch(state, record)
        Error(RefreshRateLimited(delay)) ->
          defer(state, record, before, after, delay)
        Error(RefreshRetryable) -> defer(state, record, before, after, 0)
        Ok(updated) -> {
          let same_identity =
            list.all(updated.private_metadata, fn(pair) {
              case list.key_find(current.private_metadata, pair.0) {
                Ok(old) -> old == pair.1
                Error(_) -> True
              }
            })
          case same_identity {
            False -> latch(state, record)
            True
              if updated.credential.access_token == ""
              || updated.credential.expires_at_ms <= completion + 60_000
            -> latch(state, record)
            True -> {
              let metadata =
                list.fold(
                  updated.private_metadata,
                  current.private_metadata,
                  fn(acc, pair) {
                    [pair, ..list.filter(acc, fn(old) { old.0 != pair.0 })]
                  },
                )
              let updated =
                OAuth(OAuthData(..updated, private_metadata: metadata))
              case
                runtime_store.transition(
                  state.store,
                  state.key,
                  record,
                  updated,
                  Ready,
                )
              {
                Ok(next) -> #(
                  State(
                    ..state,
                    seen: Some(runtime_store.revision(next)),
                    failures: 0,
                    monotonic_gate: None,
                  ),
                  Ok(updated),
                )
                Error(_) -> persistence_failed(state)
              }
            }
          }
        }
      }
    }
  }
}

fn completion_epoch(before: #(Int, Int), after: #(Int, Int)) -> Int {
  // Persist elapsed time too: after a wall rollback and VM restart the
  // in-memory monotonic fence disappears, but this conservative epoch survives.
  int.max(after.0, before.0 + after.1 - before.1)
}

fn defer(
  state: State,
  record: Record,
  before: #(Int, Int),
  after: #(Int, Int),
  requested: Int,
) -> #(State, Result(AuthMaterial, Failure)) {
  let failures = state.failures + 1
  // A positive upstream minimum is never shortened by an upper clamp.
  let delay = int.max(worker.backoff(failures), requested)
  // A rollback during exchange cannot move the persistent deadline backwards.
  let epoch = completion_epoch(before, after)
  case
    requested < 0
    || delay > runtime_store.max_timestamp_ms - epoch
    || delay > runtime_store.max_timestamp_ms - after.1
  {
    True -> latch(state, record)
    False -> {
      let until = epoch + delay
      case
        runtime_store.transition(
          state.store,
          state.key,
          record,
          runtime_store.record_material(record),
          Deferred(until),
        )
      {
        Ok(next) -> #(
          State(
            ..state,
            seen: Some(runtime_store.revision(next)),
            failures: failures,
            monotonic_gate: Some(#(until, after.1 + delay)),
          ),
          Error(Failure(CredentialUnavailable, NotSent, Some(until - after.0))),
        )
        Error(_) -> persistence_failed(state)
      }
    }
  }
}

fn latch(
  state: State,
  record: Record,
) -> #(State, Result(AuthMaterial, Failure)) {
  case
    runtime_store.transition(
      state.store,
      state.key,
      record,
      runtime_store.record_material(record),
      NeedsReauthorization,
    )
  {
    Ok(next) -> #(
      State(
        ..state,
        seen: Some(runtime_store.revision(next)),
        monotonic_gate: None,
      ),
      Error(Failure(ReauthorizationRequired, NotSent, None)),
    )
    Error(_) -> persistence_failed(state)
  }
}

fn persistence_failed(state: State) -> #(State, Result(AuthMaterial, Failure)) {
  // Do not repeat the callback or serve an old token for this generation.
  // An explicit admin replacement creates a new generation and clears this.
  #(
    State(..state, quarantined: True),
    Error(Failure(Persistence, NotSent, None)),
  )
}

@external(erlang, "mimic_provider_runtime_ffi", "protect")
fn protect(callback: fn() -> value) -> Result(value, Nil)

@external(erlang, "mimic_auth_ffi", "now_ms")
fn epoch_ms() -> Int

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int
