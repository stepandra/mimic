/// Sanitized provider classification; runtime alone schedules retries/cooldowns.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/types.{type Header}

pub type Category {
  Authentication
  AccountQuota
  RateLimit
  ModelCapacity
  ContextTooLarge
  InvalidReasoning
  MissingContinuation
  InvalidRequest
  Unavailable
}

pub type Classification {
  Classification(
    category: Category,
    retry_after_ms: Option(Int),
    rejected_without_execution: Bool,
  )
}

pub fn classify(
  status: Int,
  headers: List(Header),
  body: String,
  now_ms: Int,
) -> Classification {
  let root = ir.parse(body) |> result.unwrap(ir.Null)
  let error = ir.field(root, "error") |> option.unwrap(root)
  let code = text(error, "code")
  let kind = text(error, "type")
  let message = text(error, "message")
  let category = case Nil {
    _
      if status == 401
      || code == "invalid_api_key"
      || kind == "authentication_error"
    -> Authentication
    _
      if code == "context_length_exceeded"
      || code == "context_too_large"
      || status == 413
    -> ContextTooLarge
    _
      if code == "invalid_encrypted_content"
      || code == "thinking_signature_invalid"
    -> InvalidReasoning
    _ if code == "previous_response_not_found" || code == "response_not_found" ->
      MissingContinuation
    _ if kind == "usage_limit_reached" || code == "usage_limit_reached" ->
      AccountQuota
    _ if code == "model_at_capacity" || code == "model_is_at_capacity" ->
      ModelCapacity
    _ ->
      case string.contains(message, "invalid signature in thinking block") {
        True -> InvalidReasoning
        False ->
          case string.contains(message, "model is at capacity") {
            True -> ModelCapacity
            False ->
              case status {
                429 -> RateLimit
                _ if status >= 500 -> Unavailable
                _ -> InvalidRequest
              }
          }
      }
  }
  let delay = case category {
    AccountQuota -> quota_reset(error, now_ms)
    RateLimit | ModelCapacity -> retry_after(headers, now_ms)
    _ -> None
  }
  // A 5xx or disconnect may have executed: never classify it as a safe rejection.
  let rejected =
    status >= 400
    && status < 500
    && case category {
      Authentication | AccountQuota | RateLimit | ModelCapacity -> True
      _ -> False
    }
  Classification(category, delay, rejected)
}

/// Additional guard for the runtime: even an explicit rejection cannot be
/// replayed once client-visible output started, or after cancellation.
pub fn permits_retry(
  classification: Classification,
  output_started: Bool,
  cancelled: Bool,
) -> Bool {
  classification.rejected_without_execution && !output_started && !cancelled
}

fn text(root: ir.Value, key: String) -> String {
  ir.string_field(root, key)
  |> result.unwrap("")
  |> string.trim
  |> string.lowercase
}

fn quota_reset(error: ir.Value, now_ms: Int) -> Option(Int) {
  let absolute = ir.optional_int(error, "resets_at") |> result.unwrap(None)
  let relative =
    ir.optional_int(error, "resets_in_seconds") |> result.unwrap(None)
  case absolute {
    Some(seconds) if seconds * 1000 > now_ms -> Some(seconds * 1000 - now_ms)
    _ ->
      case relative {
        Some(seconds) if seconds > 0 -> Some(seconds * 1000)
        _ -> None
      }
  }
}

fn retry_after(headers: List(Header), now_ms: Int) -> Option(Int) {
  let values =
    list.filter(headers, fn(header) {
      string.lowercase(header.name) == "retry-after"
    })
  case values {
    [header] ->
      case int.parse(string.trim(header.value)) {
        Ok(seconds) if seconds >= 0 -> Some(seconds * 1000)
        _ ->
          case http_date_ms(header.value) {
            Ok(deadline) -> Some(int.max(0, deadline - now_ms))
            Error(_) -> None
          }
      }
    _ -> None
  }
}

// Reuse the shared quota layer's existing platform primitive.
@external(erlang, "mimic_quota_ffi", "http_date_ms")
fn http_date_ms(value: String) -> Result(Int, Nil)
