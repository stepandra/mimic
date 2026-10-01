/// Read-only selected xAI credential lifetime. No acquisition, refresh, writes,
/// metadata-derived routing, or Codex-specific account identity is used here.
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/providers/contracts

pub opaque type Fence {
  Fence(
    store: storage.Store,
    key: String,
    revision: runtime_store.Revision,
    authorized: fn() -> Bool,
    now: fn() -> Int,
  )
}

/// Bind AFTER runtime selection. Material equality detects a selection/read
/// race; the retained opaque revision detects even same-value replacement.
pub fn bind(
  store: storage.Store,
  context: contracts.Context,
  authorized: fn() -> Bool,
) -> Result(Fence, contracts.Failure) {
  bind_with_clock(store, context, authorized, now_ms)
}

/// Trusted dependency injection for deterministic expiry tests. Configured
/// production adapters call bind, which always supplies the real OS clock.
/// No request/configuration field or public gateway route selects this clock.
pub fn bind_with_clock(
  store: storage.Store,
  context: contracts.Context,
  authorized: fn() -> Bool,
  now: fn() -> Int,
) -> Result(Fence, contracts.Failure) {
  bind_record(store, context, None, authorized, now)
}

/// Root scoped-open boundary. The supplied revision comes from credential
/// acquisition, never a frame/token hash or a later equal-material record.
/// Require exact revision AND material/status/expiry/client before upgrade,
/// then retain that supplied revision unchanged for every lifetime check.
pub fn bind_acquired(
  store: storage.Store,
  context: contracts.Context,
  acquired: runtime_store.Revision,
  authorized: fn() -> Bool,
) -> Result(Fence, contracts.Failure) {
  bind_record(store, context, Some(acquired), authorized, now_ms)
}

fn bind_record(
  store: storage.Store,
  context: contracts.Context,
  acquired: Option(runtime_store.Revision),
  authorized: fn() -> Bool,
  now: fn() -> Int,
) -> Result(Fence, contracts.Failure) {
  use _ <- result.try(client(authorized, contracts.NotSent))
  use _ <- result.try(
    case context.provider, context.auth_mode, context.account {
      "xai", "api_key", account if account != "" -> Ok(Nil)
      "xai", "oauth", account if account != "" -> Ok(Nil)
      _, _, _ -> Error(unavailable(contracts.NotSent))
    },
  )
  let key =
    credentials.key(context.provider, context.auth_mode, context.account)
  use record <- result.try(
    runtime_store.load_record(store, key)
    |> result.replace_error(unavailable(contracts.NotSent)),
  )
  let current = runtime_store.revision(record)
  use revision <- result.try(case acquired {
    None -> Ok(current)
    Some(acquired) if acquired == current -> Ok(acquired)
    Some(_) -> Error(unavailable(contracts.NotSent))
  })
  use _ <- result.try(
    case runtime_store.record_material(record) == context.credential {
      True -> ready(record, contracts.NotSent, now())
      False -> Error(unavailable(contracts.NotSent))
    },
  )
  use _ <- result.try(client(authorized, contracts.NotSent))
  Ok(Fence(store, key, revision, authorized, now))
}

/// Check before every send/poll, after each bounded blocking transport call and
/// immediately before terminal publication. Never rebind a rotated socket.
pub fn check(fence: Fence) -> Result(Nil, contracts.Failure) {
  use _ <- result.try(client(fence.authorized, contracts.Started))
  use record <- result.try(
    runtime_store.load_record(fence.store, fence.key)
    |> result.replace_error(unavailable(contracts.Started)),
  )
  use _ <- result.try(case runtime_store.revision(record) == fence.revision {
    True -> ready(record, contracts.Started, fence.now())
    False -> Error(unavailable(contracts.Started))
  })
  client(fence.authorized, contracts.Started)
}

fn ready(
  record: runtime_store.CredentialRecord,
  delivery: contracts.Delivery,
  now: Int,
) -> Result(Nil, contracts.Failure) {
  case
    runtime_store.record_status(record),
    runtime_store.record_material(record)
  {
    runtime_store.Ready, contracts.ApiKey(_) -> Ok(Nil)
    runtime_store.Ready, contracts.OAuth(data)
      if data.credential.expires_at_ms > now
    -> Ok(Nil)
    _, _ -> Error(unavailable(delivery))
  }
}

fn client(
  authorized: fn() -> Bool,
  delivery: contracts.Delivery,
) -> Result(Nil, contracts.Failure) {
  case authorized() {
    True -> Ok(Nil)
    False -> Error(contracts.Failure(contracts.Cancelled, delivery, None))
  }
}

fn unavailable(delivery: contracts.Delivery) -> contracts.Failure {
  contracts.Failure(contracts.CredentialUnavailable, delivery, None)
}

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
