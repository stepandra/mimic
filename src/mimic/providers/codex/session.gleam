import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/auth/crypto
import mimic/dialect/responses.{type PendingCall}
import mimic/ir

/// IDs supplied by the authenticated runtime, never raw credentials.
pub type Scope {
  Scope(
    tenant: String,
    credential_id: String,
    account_id: String,
    model: String,
    client_session: String,
  )
}

pub type Identity {
  Identity(session_id: String, cache_id: String)
}

/// Runtime retains this only in its scoped session. Immutable metadata, no cache
/// or process registry here. Cancellation invalidates continuation.
pub opaque type Continuation {
  Continuation(
    identity: Identity,
    response_id: String,
    pending_calls: List(PendingCall),
    history: Option(List(ir.Value)),
    connection_generation: Option(String),
    cancelled: Bool,
  )
}

pub fn identity(scope: Scope) -> Result(Identity, String) {
  let fields = [
    scope.tenant,
    scope.credential_id,
    scope.account_id,
    scope.model,
    scope.client_session,
  ]
  case list.any(fields, fn(value) { value == "" }) {
    True ->
      Error(
        "Codex identity requires tenant, credential, account, model and session",
      )
    False -> {
      // JSON array is unambiguous even when IDs contain delimiters.
      let key = ir.stringify(ir.Array(list.map(fields, ir.String)))
      Ok(Identity(
        crypto.pkce_challenge("mimic:codex:session:v1:" <> key),
        crypto.pkce_challenge("mimic:codex:cache:v1:" <> key),
      ))
    }
  }
}

pub fn completed(
  identity: Identity,
  response_id: String,
  pending_calls: List(PendingCall),
) -> Result(Continuation, String) {
  case
    response_id == ""
    || list.any(pending_calls, fn(call) { call.id == "" })
    || list.length(list.unique(list.map(pending_calls, fn(call) { call.id })))
    != list.length(pending_calls)
  {
    True -> Error("invalid Codex continuation metadata")
    False ->
      Ok(Continuation(identity, response_id, pending_calls, None, None, False))
  }
}

/// The connection owner provides a fresh, non-client-controlled generation ID
/// whenever the upstream WS connection is replaced.
pub fn completed_ws(
  identity: Identity,
  response_id: String,
  pending_calls: List(PendingCall),
  generation: String,
) -> Result(Continuation, String) {
  use continuation <- result.try(completed(identity, response_id, pending_calls))
  case generation {
    "" -> Error("missing Codex WS connection generation")
    _ ->
      Ok(Continuation(..continuation, connection_generation: Some(generation)))
  }
}

pub fn validate_connection(
  continuation: Option(Continuation),
  generation: Option(String),
) -> Result(Nil, String) {
  case continuation, generation {
    Some(Continuation(connection_generation: Some(bound), cancelled: False, ..)),
      Some(current)
      if current != "" && bound == current
    -> Ok(Nil)
    _, _ ->
      Error("Codex WS continuation belongs to another connection or transport")
  }
}

/// Trusted runtime hook after shared-codec terminal validation. History is the
/// complete previous input plus provider output, not a client JSON assertion.
pub fn retain_history(
  continuation: Continuation,
  history: List(ir.Value),
) -> Continuation {
  Continuation(..continuation, history: Some(history))
}

pub fn replay(continuation: Continuation) -> Result(List(ir.Value), String) {
  case continuation.history, continuation.cancelled {
    Some(history), False -> Ok(history)
    _, _ -> Error("Codex HTTP continuation requires trusted complete history")
  }
}

pub fn cancel(continuation: Continuation) -> Continuation {
  Continuation(..continuation, cancelled: True)
}

pub fn validate(
  continuation: Option(Continuation),
  identity: Identity,
  previous_id: String,
) -> Result(List(PendingCall), String) {
  case continuation {
    Some(Continuation(bound, id, pending, _, _, False))
      if bound == identity && id == previous_id
    -> Ok(pending)
    _ ->
      Error(
        "Codex continuation is missing, cancelled or belongs to another scope",
      )
  }
}

pub fn no_continuation() -> Option(Continuation) {
  None
}
