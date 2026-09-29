import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/auth/crypto
import mimic/dialect/responses.{type PendingCall}
import mimic/ir

/// Provider replay policy, not a persistence mechanism. The gateway must also
/// bound receipt count, keep state private and discard it on restart/revocation.
pub const http_ttl_ms = 900_000

pub const http_max_history_bytes = 1_048_576

pub const http_max_history_items = 4096

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
    expires_ms: Int,
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
  completed_at(identity, response_id, pending_calls, now_ms())
}

/// Trusted clock injection for deterministic policy tests. Never take this time
/// or the history from an ingress request.
pub fn completed_at(
  identity: Identity,
  response_id: String,
  pending_calls: List(PendingCall),
  now: Int,
) -> Result(Continuation, String) {
  case
    now < 0
    || response_id == ""
    || list.any(pending_calls, fn(call) { call.id == "" })
    || list.length(list.unique(list.map(pending_calls, fn(call) { call.id })))
    != list.length(pending_calls)
  {
    True -> Error("invalid Codex continuation metadata")
    False ->
      Ok(Continuation(
        identity,
        response_id,
        pending_calls,
        None,
        None,
        False,
        now + http_ttl_ms,
      ))
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
  case
    list.length(history) <= http_max_history_items
    && string.byte_size(ir.stringify(ir.Array(history)))
    <= http_max_history_bytes
  {
    True -> Continuation(..continuation, history: Some(history))
    False -> Continuation(..continuation, history: None, cancelled: True)
  }
}

pub fn replay(continuation: Continuation) -> Result(List(ir.Value), String) {
  replay_at(continuation, now_ms())
}

pub fn replay_at(
  continuation: Continuation,
  now: Int,
) -> Result(List(ir.Value), String) {
  case
    continuation.history,
    continuation.cancelled,
    continuation.connection_generation
  {
    Some(history), False, None
      if now >= continuation.expires_ms - http_ttl_ms
      && now < continuation.expires_ms
    -> Ok(history)
    _, _, _ ->
      Error("Codex HTTP continuation requires trusted complete HTTP history")
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
    Some(Continuation(bound, id, pending, _, _, False, _))
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

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
