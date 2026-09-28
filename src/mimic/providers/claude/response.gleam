/// Sanitized provider classification; it does not authorize failover/replay.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/types.{type Header}

pub type Rejection {
  Authentication
  RequestInvalid
  FastModeEntitlement
  RateLimited(retry_after_ms: Option(Int))
  Overloaded
  ServerFailure
  UnexpectedStatus
}

pub fn classify(
  status: Int,
  headers: List(Header),
  body: String,
) -> Option(Rejection) {
  case status {
    status if status >= 200 && status < 300 -> None
    401 | 403 -> Some(Authentication)
    429 ->
      case fast_mode_credits(body) {
        True -> Some(FastModeEntitlement)
        False -> Some(RateLimited(retry_after(headers)))
      }
    529 -> Some(Overloaded)
    status if status >= 500 && status < 600 -> Some(ServerFailure)
    status if status >= 400 && status < 500 -> Some(RequestInvalid)
    _ -> Some(UnexpectedStatus)
  }
}

fn fast_mode_credits(body: String) -> Bool {
  let message =
    ir.parse(body)
    |> result.try(fn(v) { ir.required(v, "error") })
    |> result.try(fn(v) { ir.string_field(v, "message") })
    |> result.unwrap("")
    |> string.lowercase
  string.contains(message, "fast request rejected")
  || {
    string.contains(message, "fast")
    && {
      string.contains(message, "usage credits")
      || string.contains(message, "credits are required")
    }
  }
}

fn retry_after(headers: List(Header)) -> Option(Int) {
  let seconds =
    list.find(headers, fn(h) { string.lowercase(h.name) == "retry-after" })
    |> result.try(fn(h) { int.parse(string.trim(h.value)) })
  case seconds {
    Ok(n) if n >= 0 -> Some(n * 1000)
    _ -> None
  }
}
