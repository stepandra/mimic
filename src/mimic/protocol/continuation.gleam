/// Private, nonpersistent scoped receipt cache. No provider policy or transcript
/// normalization lives here. The integration owner creates one bounded instance
/// and authenticates tenant/client identity; providers store only validated
/// completed receipts. Restart, credential generation change and scope mismatch
/// fail closed. Never log this cache, scopes or stored values.
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mimic/auth/runtime_store.{type Revision}
import mimic/providers/contracts.{type Context, type Request}

const max_clock = 9_223_372_036_854_775_807

pub type Limits {
  Limits(entries: Int, total_bytes: Int, entry_bytes: Int, ttl_ms: Int)
}

pub opaque type Scope {
  Scope(
    tenant: String,
    provider: String,
    auth_mode: String,
    account: String,
    generation: Revision,
    model: String,
    origin: String,
    client_session: String,
    protocol: String,
    operation: String,
  )
}

/// Call only inside runtime.open_scoped with server-authenticated tenant/client
/// scope. Request.session must already be tenant-scoped by the integration.
/// Neither request body nor Context credential is retained.
pub fn scope(
  tenant: String,
  context: Context,
  generation: Revision,
  request: Request,
) -> Result(Scope, String) {
  let fields = [
    tenant, context.provider, context.auth_mode, context.account, request.model,
    context.origin, request.session, request.protocol, request.operation,
  ]
  case
    list.all(fields, valid_id)
    && request.provider == context.provider
    && request.auth_mode == context.auth_mode
    && case request.pinned_account {
      None -> True
      Some(account) -> account == context.account
    }
  {
    True ->
      Ok(Scope(
        tenant,
        context.provider,
        context.auth_mode,
        context.account,
        generation,
        request.model,
        context.origin,
        request.session,
        request.protocol,
        request.operation,
      ))
    False -> Error("invalid trusted continuation scope")
  }
}

type Entry(value) {
  Entry(value: value, expires: Int, bytes: Int)
}

type Route {
  Route(
    tenant: String,
    provider: String,
    auth_mode: String,
    model: String,
    client_session: String,
    protocol: String,
    operation: String,
  )
}

pub opaque type Cache(value) {
  Cache(
    subject: process.Subject(Message(value)),
    pid: process.Pid,
    limits: Limits,
  )
}

type Message(value) {
  Put(Scope, String, value, Int, process.Subject(Result(Nil, String)))
  Get(Scope, String, process.Subject(Result(value, String)))
  Locate(Route, String, process.Subject(Result(String, String)))
  Remove(Scope, String, process.Subject(Result(Nil, String)))
  Clear(Scope, process.Subject(Result(Nil, String)))
  Stop(process.Subject(Result(Nil, String)))
}

type State(value) {
  State(
    entries: Dict(#(Scope, String), Entry(value)),
    bytes: Int,
    limits: Limits,
    clock: fn() -> Int,
    last_clock: Option(Int),
    clock_failed: Bool,
  )
}

/// Serialized admission/removal prevents count/byte races. Reads use the same
/// bounded actor so expiry and invalidation cannot race a bypass read.
pub fn start(limits: Limits) -> Result(Cache(value), String) {
  start_with_clock(limits, monotonic_ms)
}

/// Clock injection is for tests/operator integration, never client input.
/// Rollback, overflow or a failed clock invalidates the cache until restart.
pub fn start_with_clock(
  limits: Limits,
  clock: fn() -> Int,
) -> Result(Cache(value), String) {
  use _ <- result.try(
    case
      limits.entries > 0
      && limits.entries <= 4096
      && limits.entry_bytes > 0
      && limits.entry_bytes <= limits.total_bytes
      && limits.total_bytes <= 67_108_864
      && limits.ttl_ms > 0
      && limits.ttl_ms <= 86_400_000
    {
      True -> Ok(Nil)
      False -> Error("invalid continuation cache limits")
    },
  )
  case
    actor.new(State(dict.new(), 0, limits, clock, None, False))
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> Ok(Cache(started.data, started.pid, limits))
    Error(_) -> Error("continuation cache unavailable")
  }
}

/// Size is the actual Erlang external representation of scope/id/value, not an
/// adapter-declared weight. This bounds retained serialized data, not VM heap.
/// Existing receipts cannot be overwritten. Expired receipts are swept first.
pub fn put(
  cache: Cache(value),
  scope: Scope,
  id: String,
  value: value,
) -> Result(Nil, String) {
  let bytes = external_size(#(scope, id, value))
  case valid_id(id) && bytes <= cache.limits.entry_bytes {
    False -> Error("continuation receipt exceeds limits")
    True -> ask(cache, fn(reply) { Put(scope, id, value, bytes, reply) })
  }
}

pub fn get(
  cache: Cache(value),
  scope: Scope,
  id: String,
) -> Result(value, String) {
  case valid_id(id) {
    False -> Error("continuation receipt unavailable")
    True -> ask(cache, fn(reply) { Get(scope, id, reply) })
  }
}

/// Trusted account preselection only, using the same cache as get. Does not
/// authorize a continuation or return history. Pin the unique returned account,
/// then open_scoped must reconstruct the current full scope and get must succeed
/// before sending. Old revisions/origins never grant authority through locate.
/// A fresh random per-request session cannot be used for cross-request resume.
pub fn locate(
  cache: Cache(value),
  tenant: String,
  request: Request,
  id: String,
) -> Result(String, String) {
  case
    request.pinned_account == None
    && list.all(
      [
        tenant, request.provider, request.auth_mode, request.model,
        request.session, request.protocol, request.operation, id,
      ],
      valid_id,
    )
  {
    False -> Error("invalid trusted continuation lookup")
    True -> {
      let route =
        Route(
          tenant,
          request.provider,
          request.auth_mode,
          request.model,
          request.session,
          request.protocol,
          request.operation,
        )
      ask(cache, fn(reply) { Locate(route, id, reply) })
    }
  }
}

pub fn remove(
  cache: Cache(value),
  scope: Scope,
  id: String,
) -> Result(Nil, String) {
  ask(cache, fn(reply) { Remove(scope, id, reply) })
}

pub fn clear_scope(cache: Cache(value), scope: Scope) -> Result(Nil, String) {
  ask(cache, fn(reply) { Clear(scope, reply) })
}

pub fn stop(cache: Cache(value)) -> Result(Nil, String) {
  ask(cache, Stop)
}

fn ask(
  cache: Cache(value),
  message: fn(process.Subject(Result(answer, String))) -> Message(value),
) -> Result(answer, String) {
  let reply = process.new_subject()
  let monitor = process.monitor(cache.pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error("continuation cache unavailable")
    })
  process.send(cache.subject, message(reply))
  let answer = process.selector_receive(selector, 5000)
  process.demonitor_process(monitor)
  result.unwrap(answer, Error("continuation cache unavailable"))
}

fn handle(
  state: State(value),
  message: Message(value),
) -> actor.Next(State(value), Message(value)) {
  case message {
    Stop(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    _ -> {
      let #(state, now) = advance(state)
      case message {
        Put(scope, id, value, bytes, reply) -> {
          let key = #(scope, id)
          let accepted = {
            use now <- result.try(now)
            case
              !dict.has_key(state.entries, key)
              && dict.size(state.entries) < state.limits.entries
              && state.bytes + bytes <= state.limits.total_bytes
            {
              True -> Ok(now)
              False -> Error("continuation cache capacity or duplicate receipt")
            }
          }
          case accepted {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(now) -> {
              let entries =
                dict.insert(
                  state.entries,
                  key,
                  Entry(value, now + state.limits.ttl_ms, bytes),
                )
              process.send(reply, Ok(Nil))
              actor.continue(
                State(..state, entries: entries, bytes: state.bytes + bytes),
              )
            }
          }
        }
        Get(scope, id, reply) -> {
          let value = {
            use _ <- result.try(now)
            dict.get(state.entries, #(scope, id))
            |> result.map(fn(entry) { entry.value })
            |> result.replace_error("continuation receipt unavailable")
          }
          process.send(reply, value)
          actor.continue(state)
        }
        Locate(route, id, reply) -> {
          let selected = {
            use _ <- result.try(now)
            let accounts =
              dict.keys(state.entries)
              |> list.filter_map(fn(key) {
                let #(scope, stored_id) = key
                case stored_id == id && scope_route(scope) == route {
                  True -> Ok(scope.account)
                  False -> Error(Nil)
                }
              })
              |> list.unique
            case accounts {
              [account] -> Ok(account)
              _ -> Error("continuation account unavailable or ambiguous")
            }
          }
          process.send(reply, selected)
          actor.continue(state)
        }
        Remove(scope, id, reply) -> {
          process.send(reply, now |> result.map(fn(_) { Nil }))
          actor.continue(with_entries(
            state,
            dict.delete(state.entries, #(scope, id)),
          ))
        }
        Clear(scope, reply) -> {
          process.send(reply, now |> result.map(fn(_) { Nil }))
          actor.continue(with_entries(
            state,
            dict.filter(state.entries, fn(key, _) { key.0 != scope }),
          ))
        }
        Stop(_) -> actor.stop()
      }
    }
  }
}

fn advance(state: State(value)) -> #(State(value), Result(Int, String)) {
  let sample = case state.clock_failed {
    True -> Error(Nil)
    False -> protect(state.clock)
  }
  let sample = case sample {
    Ok(now) -> {
      let forward = case state.last_clock {
        None -> True
        Some(previous) -> now >= previous
      }
      case
        forward && now >= -max_clock && now <= max_clock - state.limits.ttl_ms
      {
        True -> Ok(now)
        False -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
  case sample {
    Error(_) -> #(
      State(..state, entries: dict.new(), bytes: 0, clock_failed: True),
      Error("continuation cache clock unavailable"),
    )
    Ok(now) -> {
      let entries =
        dict.filter(state.entries, fn(_, entry) { entry.expires > now })
      #(with_entries(State(..state, last_clock: Some(now)), entries), Ok(now))
    }
  }
}

fn with_entries(
  state: State(value),
  entries: Dict(#(Scope, String), Entry(value)),
) -> State(value) {
  let bytes =
    list.fold(dict.values(entries), 0, fn(total, entry) { total + entry.bytes })
  State(..state, entries: entries, bytes: bytes)
}

fn valid_id(value: String) -> Bool {
  value != "" && string.byte_size(value) <= 1024
}

fn scope_route(scope: Scope) -> Route {
  Route(
    scope.tenant,
    scope.provider,
    scope.auth_mode,
    scope.model,
    scope.client_session,
    scope.protocol,
    scope.operation,
  )
}

@external(erlang, "erlang", "external_size")
fn external_size(value: value) -> Int

@external(erlang, "mimic_provider_runtime_ffi", "protect")
fn protect(callback: fn() -> value) -> Result(value, Nil)

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int
