/// Codex OAuth policy only. The runtime owns callback consumption, HTTP,
/// credential persistence, refresh singleflight and scheduling.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/auth/crypto
import mimic/ir
import mimic/providers/codex/json_guard
import mimic/types.{type Header, Header}

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann"

pub type Config {
  Config(authorize_url: String, token_url: String, redirect_uri: String)
}

pub opaque type Login {
  Login(
    url: String,
    state: String,
    verifier: String,
    expires_at_ms: Int,
    config: Config,
  )
}

pub type TokenRequest {
  TokenRequest(url: String, headers: List(Header), body: String)
}

/// Secret-bearing, ephemeral result. Never log or put in a capture.
/// Account ID is routing metadata, not a verified identity assertion.
pub type Tokens {
  Tokens(credential: auth.Credential, account_id: String)
}

pub type Failure {
  InvalidGrant
  Unavailable
  InvalidResponse
}

/// Published endpoint data; calling this performs no network operation.
pub fn published_config() -> Config {
  Config(
    "https://auth.openai.com/oauth/authorize",
    "https://auth.openai.com/oauth/token",
    "http://localhost:1455/auth/callback",
  )
}

pub fn begin_login(config: Config, now_ms: Int) -> Result(Login, String) {
  use _ <- result.try(validate(config))
  let state = crypto.random_url_token()
  let verifier = crypto.random_url_token()
  let query =
    uri.query_to_string([
      #("client_id", client_id),
      #("response_type", "code"),
      #("redirect_uri", config.redirect_uri),
      #("scope", "openid email profile offline_access"),
      #("state", state),
      #("code_challenge", crypto.pkce_challenge(verifier)),
      #("code_challenge_method", "S256"),
      #("prompt", "login"),
      #("id_token_add_organizations", "true"),
      #("codex_cli_simplified_flow", "true"),
    ])
  Ok(Login(
    config.authorize_url <> "?" <> query,
    state,
    verifier,
    now_ms + 300_000,
    config,
  ))
}

pub fn authorization_url(login: Login) -> String {
  login.url
}

/// Caller must consume the pending login exactly once, including failed attempts.
pub fn exchange_request(
  config: Config,
  login: Login,
  callback_query: String,
  now_ms: Int,
) -> Result(TokenRequest, String) {
  use _ <- result.try(validate(config))
  use query <- result.try(
    uri.parse_query(callback_query)
    |> result.map_error(fn(_) { "invalid OAuth callback" }),
  )
  use state <- result.try(single(query, "state"))
  use code <- result.try(single(query, "code"))
  case
    state == login.state
    && code != ""
    && now_ms < login.expires_at_ms
    && now_ms >= login.expires_at_ms - 300_000
    && config == login.config
    && !list.any(query, fn(pair) { pair.0 == "error" })
  {
    False -> Error("OAuth callback rejected")
    True ->
      Ok(
        post(config, [
          #("grant_type", "authorization_code"),
          #("client_id", client_id),
          #("code", code),
          #("redirect_uri", config.redirect_uri),
          #("code_verifier", login.verifier),
        ]),
      )
  }
}

pub fn refresh_request(
  config: Config,
  refresh_token: String,
) -> Result(TokenRequest, String) {
  use _ <- result.try(validate(config))
  case string.trim(refresh_token) {
    "" -> Error("Codex refresh token is required")
    _ ->
      Ok(
        post(config, [
          #("client_id", client_id),
          #("grant_type", "refresh_token"),
          #("refresh_token", refresh_token),
          #("scope", "openid profile email"),
        ]),
      )
  }
}

fn post(config: Config, form: List(#(String, String))) -> TokenRequest {
  TokenRequest(
    config.token_url,
    [
      Header("Content-Type", "application/x-www-form-urlencoded"),
      Header("Accept", "application/json"),
    ],
    uri.query_to_string(form),
  )
}

/// Decode a response from the configured, TLS-verified token endpoint only.
/// Rotation replaces the old refresh token; omission preserves it on refresh.
/// A malformed present field fails closed instead of falling back.
pub fn decode_tokens(
  status: Int,
  body: String,
  previous: Option(Tokens),
  now_ms: Int,
) -> Result(Tokens, Failure) {
  case status {
    200 ->
      parse_tokens(body, previous, now_ms)
      |> result.map_error(fn(_) { InvalidResponse })
    _ -> Error(token_failure(status, body))
  }
}

fn parse_tokens(
  body: String,
  previous: Option(Tokens),
  now_ms: Int,
) -> Result(Tokens, String) {
  use root <- result.try(json_guard.parse(body))
  use access <- result.try(ir.string_field(root, "access_token"))
  use expires <- result.try(ir.required(root, "expires_in"))
  use expires <- result.try(ir.as_int(expires))
  use token_type <- result.try(optional_text(root, "token_type"))
  use refresh <- result.try(optional_text(root, "refresh_token"))
  use id_token <- result.try(optional_text(root, "id_token"))
  let refresh = case refresh, previous {
    Some(value), _ -> value
    None, Some(old) -> old.credential.refresh_token
    None, None -> ""
  }
  use account <- result.try(case id_token, previous {
    Some(token), _ -> account_id(token)
    None, Some(old) -> Ok(old.account_id)
    None, None -> Error("missing Codex account metadata")
  })
  use _ <- result.try(case previous {
    Some(old) if old.account_id != account ->
      Error("Codex account changed on refresh")
    _ -> Ok(Nil)
  })
  case
    safe_header(access)
    && safe_header(account)
    && refresh != ""
    && expires > 0
    && expires <= 31_536_000
    && {
      token_type == None
      || token_type == Some("Bearer")
      || token_type == Some("bearer")
    }
  {
    False -> Error("invalid Codex token response")
    True ->
      Ok(Tokens(
        auth.Credential(access, refresh, now_ms + expires * 1000),
        account,
      ))
  }
}

/// JWT payload decoding is NOT signature verification. This routing hint is
/// accepted only from a trusted token exchange; never use it for ingress auth.
pub fn account_id(id_token: String) -> Result(String, String) {
  use payload <- result.try(case string.split(id_token, ".") {
    [_, payload, _] -> Ok(payload)
    _ -> Error("invalid Codex identity metadata")
  })
  use bytes <- result.try(
    bit_array.base64_url_decode(payload)
    |> result.map_error(fn(_) { "invalid Codex identity metadata" }),
  )
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) { "invalid Codex identity metadata" }),
  )
  use root <- result.try(json_guard.parse(text))
  use claims <- result.try(ir.required(root, "https://api.openai.com/auth"))
  use id <- result.try(ir.string_field(claims, "chatgpt_account_id"))
  case safe_header(id) {
    True -> Ok(id)
    False -> Error("invalid Codex account metadata")
  }
}

fn optional_text(
  root: ir.Value,
  field: String,
) -> Result(Option(String), String) {
  case ir.field(root, field) {
    None -> Ok(None)
    Some(value) -> ir.as_string(value) |> result.map(Some)
  }
}

fn token_failure(status: Int, body: String) -> Failure {
  let code = case json_guard.parse(body) {
    Ok(root) ->
      case ir.field(root, "error") {
        Some(ir.String(code)) -> code
        Some(value) -> ir.string_field(value, "code") |> result.unwrap("")
        None -> ""
      }
    Error(_) -> ""
  }
  case code {
    "invalid_grant"
    | "refresh_token_reused"
    | "refresh_token_revoked"
    | "refresh_token_expired" -> InvalidGrant
    _ if status == 401 || status == 403 -> InvalidGrant
    _ if status == 429 || status >= 500 -> Unavailable
    _ -> InvalidResponse
  }
}

fn single(
  query: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  case list.filter(query, fn(pair) { pair.0 == name }) {
    [#(_, value)] -> Ok(value)
    _ -> Error("missing or duplicate OAuth callback field")
  }
}

pub fn safe_header(value: String) -> Bool {
  value != ""
  && !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn validate(config: Config) -> Result(Nil, String) {
  use _ <- result.try(endpoint(config.authorize_url, False))
  use _ <- result.try(endpoint(config.token_url, False))
  endpoint(config.redirect_uri, True)
}

fn endpoint(value: String, callback: Bool) -> Result(Nil, String) {
  use parsed <- result.try(
    uri.parse(value) |> result.map_error(fn(_) { "invalid OAuth URL" }),
  )
  let loopback =
    list.contains(
      ["localhost", "127.0.0.1", "::1"],
      option.unwrap(parsed.host, ""),
    )
  case
    parsed.userinfo == None
    && parsed.query == None
    && parsed.fragment == None
    && parsed.host != None
    && safe_header(value)
    && {
      case callback {
        True -> loopback && parsed.scheme == Some("http")
        False ->
          parsed.scheme == Some("https")
          || { loopback && parsed.scheme == Some("http") }
      }
    }
  {
    True -> Ok(Nil)
    False ->
      Error(
        "OAuth endpoint must be HTTPS or explicit loopback; callback must be loopback HTTP",
      )
  }
}
