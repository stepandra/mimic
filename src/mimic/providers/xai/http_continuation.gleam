/// HTTP input enforcement, not an implementation of conversation continuation.
/// FINAL-v1's ordinary xAI HTTP path deletes previous_response_id. Compact's
/// separate raw-id restoration does not establish trusted receipt authority.
/// Reject explicitly rather than discard an id or replay history as a fallback.
import gleam/option.{None, Some}
import gleam/result
import mimic/ir
import mimic/providers/contracts
import mimic/providers/xai/json_guard

/// Presence, not truthiness, is the boundary: null, empty and malformed values
/// also request unavailable state. Inspect only the top-level protocol field;
/// identically named keys in user content are not continuation instructions.
/// WebSocket callers must use their existing connection-scoped admission.
pub fn validate(document: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(ir.as_object(document))
  case ir.field(document, "previous_response_id") {
    None -> Ok(Nil)
    Some(_) -> Error("xAI HTTP previous_response_id is unsupported")
  }
}

/// Run at the actual HTTP route BEFORE runtime.open can acquire/refresh an
/// OAuth credential. The bridge calls validate after its own strict parse.
/// Parsing is shared with the existing xAI boundary; no raw input or id enters
/// a failure. No account, revision, history or endpoint authority is granted.
pub fn guard(body: String) -> Result(Nil, contracts.Failure) {
  let invalid =
    contracts.Failure(contracts.InvalidConfiguration, contracts.NotSent, None)
  use document <- result.try(
    json_guard.parse(body) |> result.replace_error(invalid),
  )
  use _ <- result.try(ir.as_object(document) |> result.replace_error(invalid))
  validate(document)
  |> result.replace_error(contracts.Failure(
    contracts.Unsupported,
    contracts.NotSent,
    None,
  ))
}
