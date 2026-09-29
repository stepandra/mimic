/// Configured PKCE login into the shared runtime store. No legacy auth record,
/// refresh scheduler, token output, or durable pending verifier is created.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/auth
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/ir
import mimic/providers/claude/adapter
import mimic/providers/claude/oauth
import mimic/providers/contracts

pub fn run(
  config: auth.Config,
  store: storage.Store,
  key: String,
  identity: ir.Value,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
  send: fn(oauth.TokenRequest) -> Result(oauth.TokenResponse, String),
) -> Result(Nil, String) {
  use device <- result.try(ir.string_field(identity, "device_id"))
  use account <- result.try(ir.string_field(identity, "account_uuid"))
  use org <- result.try(ir.optional_string(identity, "organization_uuid"))
  let metadata = [#("device_id", device), #("account_uuid", account)]
  use _ <- result.try(adapter.account_identity(metadata))
  // Reserve/snapshot before creating PKCE state, announcing or doing any I/O.
  use enrollment <- with_enrollment(store, key)
  use pending <- result.try(oauth.begin(config, key))
  use callback <- result.try(auth.await_callback(
    config,
    pending,
    timeout_ms,
    announce,
  ))
  use tokens <- result.try(
    oauth.exchange(config, pending, callback.0, callback.1, now_ms(), send)
    |> result.replace_error("Claude OAuth exchange failed"),
  )
  // Token-endpoint identity must agree with the operator's private identity.
  use _ <- result.try(case tokens.identity.account_uuid {
    None -> Ok(Nil)
    Some(value) if value == account -> Ok(Nil)
    _ -> Error("Claude OAuth identity mismatch")
  })
  use organization <- result.try(case org, tokens.identity.organization_uuid {
    Some(old), Some(new) if old != new -> Error("Claude OAuth identity mismatch")
    _, Some(new) -> Ok(Some(new))
    _, None -> Ok(org)
  })
  let metadata = case organization {
    None -> metadata
    Some(value) -> list.append(metadata, [#("organization_uuid", value)])
  }
  runtime_store.commit_enrollment(
    enrollment,
    contracts.OAuth(contracts.OAuthData(tokens.credential, metadata)),
  )
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
