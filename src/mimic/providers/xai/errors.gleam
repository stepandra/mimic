import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir

/// Sanitized provider status, never the original response body or message.
/// Runtime remains the sole authority for cooldowns, refresh and retry.
pub type Status {
  Status(status: Int, retry_after_ms: Option(Int), reauthorize: Bool)
}

pub fn classify(status: Int, body: ir.Value) -> Status {
  let text = error_text(body)
  let bad_credentials =
    string.contains(text, "bad-credentials")
    || string.contains(text, "access token could not be validated")
  case status {
    403 if bad_credentials -> Status(401, None, True)
    401 -> Status(401, None, True)
    429 -> {
      let exhausted =
        string.contains(text, "free-usage-exhausted")
        || string.contains(text, "included free usage")
      Status(
        429,
        case exhausted {
          True -> Some(86_400_000)
          False -> None
        },
        False,
      )
    }
    _ -> Status(status, None, False)
  }
}

fn error_text(body: ir.Value) -> String {
  let direct =
    list.map(["code", "message", "error"], fn(key) {
      ir.string_field(body, key) |> result.unwrap("")
    })
  let nested = case ir.field(body, "error") {
    Some(ir.Object(_) as error) -> [error_text(error)]
    _ -> []
  }
  let wrapped = case ir.field(body, "body") {
    Some(ir.Object(_) as body) -> [error_text(body)]
    _ -> []
  }
  list.append(direct, list.append(nested, wrapped))
  |> string.join(" ")
  |> string.lowercase
}
