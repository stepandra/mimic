import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/providers/codex/oauth
import mimic/providers/contracts
import mimic/replay
import mimic/types.{type WireResponse, Capture, Header, Transport}

/// Operator-supplied token endpoint only. No redirects, credentials in URL,
/// query, fragment, non-loopback plaintext, or implicit published endpoint.
pub fn validate(url: String) -> Result(Nil, String) {
  use parsed <- result.try(
    uri.parse(url) |> result.map_error(fn(_) { "invalid OAuth token endpoint" }),
  )
  let loopback =
    parsed.host == Some("127.0.0.1") || parsed.host == Some("localhost")
  case
    parsed.host != None
    && parsed.userinfo == None
    && parsed.query == None
    && parsed.fragment == None
    && parsed.path != ""
    && parsed.path != "/"
    && !string.contains(parsed.path, "\\")
    && case parsed.port {
      Some(port) -> port > 0 && port < 65_536
      None -> True
    }
    && {
      parsed.scheme == Some("https")
      || { parsed.scheme == Some("http") && loopback }
    }
  {
    True -> Ok(Nil)
    False -> Error("unsupported OAuth token endpoint")
  }
}

/// The provider supplies form encoding and response interpretation. The shared
/// replay transport supplies direct HTTP/1.1, verified TLS, bounded frames and
/// no redirects. Any uncertain transport outcome fences automatic rotation.
pub fn send(
  plan: oauth.TokenRequest,
) -> Result(WireResponse, contracts.RefreshFailure) {
  let outcome = {
    use _ <- result.try(validate(plan.url))
    use parsed <- result.try(
      uri.parse(plan.url)
      |> result.map_error(fn(_) { "invalid token endpoint" }),
    )
    use host <- result.try(case parsed.host {
      Some(value) -> Ok(value)
      None -> Error("invalid token endpoint")
    })
    let authority =
      host
      <> case parsed.port {
        Some(port) -> ":" <> int.to_string(port)
        None -> ""
      }
    let origin =
      case parsed.scheme {
        Some("https") -> "https://"
        _ -> "http://"
      }
      <> authority
    let capture =
      Capture(
        "gateway-refresh",
        "unmeasured",
        origin,
        "oauth-refresh",
        "POST",
        parsed.path,
        "HTTP/1.1",
        [
          Header("Host", authority),
          Header("Content-Length", int.to_string(string.byte_size(plan.body))),
          Header("Connection", "close"),
          ..plan.headers
        ],
        plan.body,
        Transport("http/1.1", None),
      )
    replay.send(origin, capture)
  }
  outcome |> result.map_error(fn(_) { contracts.RefreshUnavailable })
}
