/// Secret-free configured discovery and the existing bounded HTTP/1.1
/// transport. No ambient proxy, redirect, credential or provider endpoint.
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/ir
import mimic/providers/contracts
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/providers/xai/oauth
import mimic/replay
import mimic/types.{Capture, Header, Transport}

pub fn decode_config(raw: ir.Value) -> Result(oauth.Config, String) {
  use fields <- result.try(ir.as_object(raw) |> invalid)
  use url <- result.try(case fields {
    [#("discovery_url", ir.String(url))] -> Ok(url)
    _ -> Error("xAI OAuth requires only an explicit discovery_url")
  })
  use policy <- result.try(policy(url))
  let config = oauth.Config(url, policy)
  use _ <- result.try(validate(config))
  Ok(config)
}

pub fn validate(config: oauth.Config) -> Result(Nil, String) {
  validate_endpoint(config.discovery_url, config.policy)
}

/// Admission, persistence and network use share one transport rule.
/// Never install a token endpoint that the configured sender cannot use.
pub fn validate_endpoint(
  url: String,
  expected: endpoint.EndpointPolicy,
) -> Result(Nil, String) {
  use actual <- result.try(policy(url))
  use _ <- result.try(oauth.validate_endpoint(url, expected))
  use parsed <- result.try(uri.parse(url) |> invalid)
  case
    actual == expected
    && parsed.path != ""
    && parsed.path != "/"
    && parsed.query == None
  {
    True -> Ok(Nil)
    False -> Error("invalid configured xAI discovery endpoint")
  }
}

/// Existing root private-file import hook for explicit administrative recovery.
/// Identity and operation authority remain configuration-owned, not JWT claims.
pub fn import_material(
  config: oauth.Config,
  raw: ir.Value,
) -> Result(contracts.AuthMaterial, String) {
  use _ <- result.try(validate(config))
  use fields <- result.try(ir.as_object(raw) |> invalid)
  use _ <- result.try(
    case
      list.sort(list.map(fields, fn(field) { field.0 }), string.compare)
      == ["access_token", "expires_at_ms", "refresh_token", "token_endpoint"]
    {
      True -> Ok(Nil)
      False -> Error("invalid private xAI credential")
    },
  )
  use access <- result.try(ir.string_field(raw, "access_token") |> invalid)
  use refresh <- result.try(ir.string_field(raw, "refresh_token") |> invalid)
  use token <- result.try(ir.string_field(raw, "token_endpoint") |> invalid)
  use _ <- result.try(validate_endpoint(token, config.policy))
  use expiry <- result.try(
    ir.required(raw, "expires_at_ms") |> result.try(ir.as_int) |> invalid,
  )
  use _ <- result.try(
    case
      expiry > 0
      && list.all([access, refresh], fn(secret) {
        string.trim(secret) != ""
        && string.byte_size(secret) <= 16_384
        && !string.contains(secret, "\r")
        && !string.contains(secret, "\n")
        && !string.contains(secret, "\u{0000}")
      })
    {
      True -> Ok(Nil)
      False -> Error("invalid private xAI credential")
    },
  )
  bridge.oauth_material(
    config,
    oauth.Discovery(config.discovery_url, token),
    auth.Credential(access, refresh, expiry),
  )
  |> result.replace_error("invalid private xAI credential")
}

fn policy(url: String) -> Result(endpoint.EndpointPolicy, String) {
  case uri.parse(url) {
    Ok(uri.Uri(scheme: Some("http"), host: Some("127.0.0.1"), ..)) ->
      Ok(endpoint.LocalMock)
    Ok(uri.Uri(scheme: Some("https"), host: Some(host), ..)) ->
      case string.contains(host, ":") {
        False -> Ok(endpoint.VerifiedTls)
        True -> Error("xAI OAuth IPv6 transport is unsupported")
      }
    _ -> Error("xAI transport requires verified HTTPS or numeric loopback HTTP")
  }
}

/// OAuth is the only caller: GET discovery or form POST, with no auth headers.
/// replay.send is direct, bounded, TLS-verifying and does not follow redirects.
/// Private request/response material is never captured to a file or logged.
pub fn send(
  req: request.Request(String),
) -> Result(response.Response(String), String) {
  let outcome = {
    let url = request.to_uri(req)
    let text = uri.to_string(url)
    use policy <- result.try(policy(text))
    use _ <- result.try(validate_endpoint(text, policy))
    use method <- result.try(case req.method, req.body {
      http.Get, "" -> Ok("GET")
      http.Post, _ ->
        case string.byte_size(req.body) <= 65_536 {
          True -> Ok("POST")
          False -> Error("xAI OAuth request too large")
        }
      _, _ -> Error("unsupported xAI OAuth request")
    })
    use _ <- result.try(
      case
        req.path != ""
        && req.path != "/"
        && list.all(req.headers, fn(header) {
          header == #("accept", "application/json")
          || header == #("content-type", "application/x-www-form-urlencoded")
        })
        && list.length(list.unique(list.map(req.headers, fn(h) { h.0 })))
        == list.length(req.headers)
      {
        True -> Ok(Nil)
        False -> Error("unsupported xAI OAuth headers or path")
      },
    )
    let authority =
      req.host
      <> case req.port {
        None -> ""
        Some(port) -> ":" <> int.to_string(port)
      }
    let origin = http.scheme_to_string(req.scheme) <> "://" <> authority
    let capture =
      Capture(
        "gateway-xai-oauth",
        "unmeasured",
        origin,
        "oauth",
        method,
        req.path,
        "HTTP/1.1",
        [
          Header("Host", authority),
          Header("Content-Length", int.to_string(string.byte_size(req.body))),
          Header("Connection", "close"),
          ..list.map(req.headers, fn(h) { Header(h.0, h.1) })
        ],
        req.body,
        Transport("http/1.1", None),
      )
    use reply <- result.try(replay.send(origin, capture))
    let encodings =
      reply.headers
      |> list.filter(fn(h) { string.lowercase(h.name) == "content-encoding" })
      |> list.map(fn(h) { string.lowercase(string.trim(h.value)) })
    use _ <- result.try(
      case
        string.byte_size(reply.body) <= 65_536
        && { encodings == [] || encodings == ["identity"] }
      {
        True -> Ok(Nil)
        False -> Error("unsupported xAI OAuth response size or encoding")
      },
    )
    Ok(response.Response(
      reply.status,
      list.map(reply.headers, fn(h) { #(string.lowercase(h.name), h.value) }),
      reply.body,
    ))
  }
  outcome |> result.replace_error("xAI OAuth transport unavailable")
}

fn invalid(value: Result(a, e)) -> Result(a, String) {
  value |> result.replace_error("invalid configured xAI discovery endpoint")
}
