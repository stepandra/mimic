/// Configured PKCE login into the shared runtime store. No legacy auth record,
/// refresh scheduler, token output, or durable pending verifier is created.
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/auth
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/ir
import mimic/providers/claude/companion
import mimic/providers/claude/oauth
import mimic/providers/contracts

/// Provider seam types, not assumptions about an uncompiled UI shell.
pub type Callback {
  Callback(state: String, code: String)
}

pub type Transports {
  Transports(
    token: fn(oauth.TokenRequest) -> Result(oauth.TokenResponse, String),
    companion: fn(companion.Request) -> Result(oauth.TokenResponse, String),
  )
}

/// Store-free exchange/profile/roles/reconciliation only. The caller consumes
/// its pending login once, owns its S5 ticket and commits/cancels it itself.
/// An enrollment-owning UI MUST use this seam, never either run wrapper.
pub fn exchange_grant(
  config: auth.Config,
  pending: auth.Login,
  callback: Callback,
  identity: ir.Value,
  approved: Option(companion.Approved),
  now_ms: Int,
  transports: Transports,
) -> Result(contracts.AuthMaterial, String) {
  use operator <- result.try(companion.operator(identity))
  use tokens <- result.try(
    oauth.exchange(
      config,
      pending,
      callback.state,
      callback.code,
      now_ms,
      transports.token,
    )
    |> result.replace_error("Claude OAuth exchange failed"),
  )
  use profile <- result.try(case approved {
    None -> Ok(None)
    Some(approved) -> {
      use observed <- result.try(companion.inspect(
        approved,
        tokens.credential.access_token,
        transports.companion,
      ))
      Ok(observed.profile)
    }
  })
  companion.reconcile(operator, tokens, profile)
}

/// Existing CLI full-enrollment entrypoint: no implicit companion activity.
pub fn run(
  config: auth.Config,
  store: storage.Store,
  key: String,
  identity: ir.Value,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
  send: fn(oauth.TokenRequest) -> Result(oauth.TokenResponse, String),
) -> Result(Nil, String) {
  run_workflow(
    config,
    store,
    key,
    identity,
    timeout_ms,
    announce,
    None,
    Transports(send, fn(_) { Error("Claude companion activity disabled") }),
  )
}

/// Opt-in CLI/full-enrollment wrapper. Still exactly one S5 ticket, including
/// profile/roles advisory failures and late administrative replacement races.
pub fn run_with_companion(
  config: auth.Config,
  store: storage.Store,
  key: String,
  identity: ir.Value,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
  approved: companion.Approved,
  transports: Transports,
) -> Result(Nil, String) {
  run_workflow(
    config,
    store,
    key,
    identity,
    timeout_ms,
    announce,
    Some(approved),
    transports,
  )
}

fn run_workflow(
  config: auth.Config,
  store: storage.Store,
  key: String,
  identity: ir.Value,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
  approved: Option(companion.Approved),
  transports: Transports,
) -> Result(Nil, String) {
  use _ <- result.try(companion.operator(identity))
  // Reserve/snapshot before creating PKCE state, announcing or doing any I/O.
  use enrollment <- with_enrollment(store, key)
  use pending <- result.try(
    oauth.begin(config, key)
    |> result.replace_error("Invalid Claude OAuth configuration"),
  )
  use callback <- result.try(
    auth.await_callback(config, pending, timeout_ms, announce)
    |> result.replace_error("Claude OAuth callback failed"),
  )
  use material <- result.try(exchange_grant(
    config,
    pending,
    Callback(callback.0, callback.1),
    identity,
    approved,
    now_ms(),
    transports,
  ))
  runtime_store.commit_enrollment(enrollment, material)
  |> result.replace_error("Claude OAuth persistence failed")
}

/// Shared-core owns all mutation/generation semantics. On an ordinary failure,
/// retire only this ticket; a concurrent admin change or committed grant wins.
/// Panics/process death deliberately leave first-enrollment markers fail-closed
/// for explicit operator recovery, rather than inventing background cleanup.
fn with_enrollment(
  store: storage.Store,
  key: String,
  action: fn(runtime_store.Enrollment) -> Result(Nil, String),
) -> Result(Nil, String) {
  use enrollment <- result.try(
    runtime_store.begin_enrollment(store, key)
    |> result.replace_error("Claude OAuth enrollment unavailable"),
  )
  case action(enrollment) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      case runtime_store.cancel_enrollment(enrollment) {
        Ok(Nil) -> Error(error)
        Error(_) ->
          Error("Claude OAuth enrollment failed; cancellation unconfirmed")
      }
  }
}

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
