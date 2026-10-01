/// Read-only selected-record lifetime fence. The credential worker remains the
/// sole credential owner; this module never acquires, refreshes or writes.
/// Store/key/revision are private capabilities, not client diagnostics.
import gleam/option.{None}
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
  )
}

/// Called after runtime selection but before opening a physical socket. Exact
/// material equality catches a selection/read race; the retained revision
/// catches later replacement even with identical token values.
pub fn bind(
  store: storage.Store,
  context: contracts.Context,
  authorized: fn() -> Bool,
) -> Result(Fence, contracts.Failure) {
  use _ <- result.try(client(authorized, contracts.NotSent))
  use _ <- result.try(
    case context.provider, context.auth_mode, context.account {
      "codex", "oauth", account if account != "" -> Ok(Nil)
      _, _, _ -> Error(unavailable(contracts.NotSent))
    },
  )
  let key =
    credentials.key(context.provider, context.auth_mode, context.account)
  use record <- result.try(
    runtime_store.load_record(store, key)
    |> result.replace_error(unavailable(contracts.NotSent)),
  )
  use _ <- result.try(
    case runtime_store.record_material(record) == context.credential {
      True -> ready(record, contracts.NotSent)
      False -> Error(unavailable(contracts.NotSent))
    },
  )
  use _ <- result.try(client(authorized, contracts.NotSent))
  Ok(Fence(store, key, runtime_store.revision(record), authorized))
}

/// Re-read on every send/poll and after a blocking poll, including idle polls.
/// Never cache a successful read or rebind this fence to a refreshed revision.
pub fn check(fence: Fence) -> Result(Nil, contracts.Failure) {
  use _ <- result.try(client(fence.authorized, contracts.Started))
  use record <- result.try(
    runtime_store.load_record(fence.store, fence.key)
    |> result.replace_error(unavailable(contracts.Started)),
  )
  use _ <- result.try(case runtime_store.revision(record) == fence.revision {
    True -> ready(record, contracts.Started)
    False -> Error(unavailable(contracts.Started))
  })
  client(fence.authorized, contracts.Started)
}

fn ready(
  record: runtime_store.CredentialRecord,
  delivery: contracts.Delivery,
) -> Result(Nil, contracts.Failure) {
  let now = now_ms()
  case
    runtime_store.record_status(record),
    runtime_store.record_material(record)
  {
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
