/// Pure credential-generation-bound native thread state. The shared session
/// owner must serialize advances and persist this state atomically if needed.
/// No map, scheduler, disk store, or untrusted client session IDs live here.
import gleam/bit_array
import gleam/option.{Some}
import gleam/result
import mimic/auth/runtime_store
import mimic/providers/contracts as c
import mimic/providers/devin/identity

pub opaque type Scope {
  Scope(
    provider: String,
    account: String,
    origin: String,
    client_session: String,
    model: String,
    generation: runtime_store.Revision,
    credential_hash: BitArray,
    session: String,
    cascade: String,
    ordinal: Int,
  )
}

pub fn new(
  context: c.Context,
  request: c.Request,
  record: runtime_store.CredentialRecord,
) -> Result(Scope, String) {
  use hash <- result.try(binding(context, request, record))
  let session = identity.uuid()
  Ok(Scope(
    context.provider,
    context.account,
    context.origin,
    context.session_key,
    request.model,
    runtime_store.revision(record),
    hash,
    session,
    session,
    0,
  ))
}

/// Invoke under the shared owner's per-session mutation guard. A stale copy
/// cannot be used as a substitute for that guard. Pinning is mandatory here.
pub fn advance(
  scope: Scope,
  context: c.Context,
  request: c.Request,
  record: runtime_store.CredentialRecord,
) -> Result(Scope, String) {
  use hash <- result.try(binding(context, request, record))
  case
    scope.provider == context.provider
    && scope.account == context.account
    && scope.origin == context.origin
    && scope.client_session == context.session_key
    && scope.model == request.model
    && scope.generation == runtime_store.revision(record)
    && scope.credential_hash == hash
    && request.pinned_account == Some(context.account)
    && scope.ordinal < 2_147_483_647
  {
    True -> Ok(Scope(..scope, ordinal: scope.ordinal + 1))
    False -> Error("devin continuation scope changed")
  }
}

fn binding(
  context: c.Context,
  request: c.Request,
  record: runtime_store.CredentialRecord,
) -> Result(BitArray, String) {
  case
    context.provider == "devin"
    && request.provider == "devin"
    && context.auth_mode == "session_token"
    && request.auth_mode == "session_token"
    && context.account != ""
    && context.session_key != ""
    && request.session != ""
    && request.model != ""
    && runtime_store.record_material(record) == context.credential
  {
    False -> Error("invalid devin continuation binding")
    True ->
      case context.credential {
        c.SessionToken(token, _) ->
          Ok(identity.sha256(bit_array.from_string(token)))
        _ -> Error("invalid devin continuation credential")
      }
  }
}

pub fn session(scope: Scope) -> String {
  scope.session
}

pub fn cascade(scope: Scope) -> String {
  scope.cascade
}

pub fn ordinal(scope: Scope) -> Int {
  scope.ordinal
}

/// Defense in depth at the pure serializer boundary.
pub fn permits(scope: Scope, token: String, model: String) -> Bool {
  scope.model == model
  && scope.credential_hash == identity.sha256(bit_array.from_string(token))
}
