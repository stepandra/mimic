/// Provider token protocol only. Runtime owns singleflight, storage and retries.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/auth
import mimic/ir
import mimic/providers/claude/json_guard
import mimic/types.{type Header, Header}

pub type TokenRequest {
  TokenRequest(url: String, headers: List(Header), body: String)
}

pub type TokenResponse {
  TokenResponse(status: Int, headers: List(Header), body: String)
}

/// These fields are private identity metadata, not diagnostics or log fields.
pub type Identity {
  Identity(account_uuid: Option(String), organization_uuid: Option(String))
}

pub type Tokens {
  Tokens(credential: auth.Credential, identity: Identity)
}

/// No variant contains response bodies, transport diagnostics, or secrets.
pub type Failure {
  InvalidCallback
  InvalidGrant
  RateLimited(retry_after_ms: Int)
  Unavailable
  InvalidResponse
  IdentityChanged
}

pub fn begin(config: auth.Config, id: String) -> Result(auth.Login, String) {
  use login <- result.try(auth.begin_login(config, id))
  Ok(auth.Login(..login, url: login.url <> "&code=true"))
}

/// Validate both the independent callback state and any pasted code#state.
/// The runtime must consume the pending Login once before invoking transport.
pub fn exchange_request(
  config: auth.Config,
  login: auth.Login,
  callback_state: String,
  code: String,
) -> Result(TokenRequest, Failure) {
  let parts = string.split(code, "#")
  let parsed = case parts {
    [code] if code != "" -> Ok(code)
    [code, state] if code != "" && state == login.state -> Ok(code)
    _ -> Error(InvalidCallback)
  }
  use code <- result.try(parsed)
  case
    callback_state == login.state && login.state != "" && login.verifier != ""
  {
    False -> Error(InvalidCallback)
    True ->
      Ok(
        token_request(config, [
          #("grant_type", ir.String("authorization_code")),
          #("code", ir.String(code)),
          #("redirect_uri", ir.String(config.redirect_uri)),
          #("client_id", ir.String(config.client_id)),
          #("code_verifier", ir.String(login.verifier)),
          #("state", ir.String(login.state)),
        ]),
      )
  }
}

pub fn refresh_request(
  config: auth.Config,
  refresh_token: String,
) -> Result(TokenRequest, Failure) {
  case string.trim(refresh_token) {
    "" -> Error(InvalidGrant)
    _ ->
      Ok(
        token_request(config, [
          #("client_id", ir.String(config.client_id)),
          #("grant_type", ir.String("refresh_token")),
          #("refresh_token", ir.String(refresh_token)),
          #("scope", ir.String(string.join(config.scopes, " "))),
        ]),
      )
  }
}

fn token_request(
  config: auth.Config,
  fields: List(#(String, ir.Value)),
) -> TokenRequest {
  TokenRequest(
    config.token_url,
    [
      Header("Content-Type", "application/json"),
      Header("Accept", "application/json"),
    ],
    ir.stringify(ir.Object(fields)),
  )
}

/// Code exchange has no persistence side effect. Runtime consumes the Login
/// before calling this function and persists the returned grant privately.
pub fn exchange(
  config: auth.Config,
  login: auth.Login,
  callback_state: String,
  code: String,
  now_ms: Int,
  send: fn(TokenRequest) -> Result(TokenResponse, String),
) -> Result(Tokens, Failure) {
  use request <- result.try(exchange_request(
    config,
    login,
    callback_state,
    code,
  ))
  use response <- result.try(
    send(request) |> result.map_error(fn(_) { Unavailable }),
  )
  parse_tokens(
    response,
    Tokens(auth.Credential("", "", 0), Identity(None, None)),
    now_ms,
  )
}

/// Transport must POST once to the explicitly approved URL, without redirects.
/// Arbitrary transport errors are deliberately discarded.
pub fn refresh(
  config: auth.Config,
  previous: Tokens,
  now_ms: Int,
  send: fn(TokenRequest) -> Result(TokenResponse, String),
) -> Result(Tokens, Failure) {
  use request <- result.try(refresh_request(
    config,
    previous.credential.refresh_token,
  ))
  use response <- result.try(
    send(request) |> result.map_error(fn(_) { Unavailable }),
  )
  parse_tokens(response, previous, now_ms)
}

pub fn parse_tokens(
  response: TokenResponse,
  previous: Tokens,
  now_ms: Int,
) -> Result(Tokens, Failure) {
  // Every token/error envelope is checked while raw keys still exist, before
  // status can authorize success or a retry-safe rate-limit classification.
  use body <- result.try(json_guard.parse(response.body) |> invalid_response)
  use _ <- result.try(ir.as_object(body) |> invalid_response)
  use _ <- result.try(case response.status {
    200 ->
      case ir.field(body, "error") {
        None -> Ok(Nil)
        Some(_) -> Error(InvalidResponse)
      }
    _ ->
      case
        ir.field(body, "access_token") != None
        || ir.field(body, "refresh_token") != None
        || ir.field(body, "expires_in") != None
      {
        True -> Error(InvalidResponse)
        False -> Ok(Nil)
      }
  })
  case response.status {
    200 -> {
      use access <- result.try(
        ir.string_field(body, "access_token") |> invalid_response,
      )
      use expires <- result.try(
        ir.required(body, "expires_in")
        |> result.try(ir.as_int)
        |> invalid_response,
      )
      use refresh <- result.try(
        ir.optional_string(body, "refresh_token") |> invalid_response,
      )
      let refresh = case refresh {
        Some(value) if value != "" -> value
        _ -> previous.credential.refresh_token
      }
      use _ <- result.try(
        case
          string.trim(access) != ""
          && refresh != ""
          && expires > 0
          && now_ms >= 0
        {
          True -> Ok(Nil)
          False -> Error(InvalidResponse)
        },
      )
      use account <- result.try(identity_field(
        body,
        "account",
        previous.identity.account_uuid,
      ))
      use organization <- result.try(identity_field(
        body,
        "organization",
        previous.identity.organization_uuid,
      ))
      Ok(Tokens(
        auth.Credential(access, refresh, now_ms + expires * 1000),
        Identity(account, organization),
      ))
    }
    429 -> Error(RateLimited(retry_after(response.headers)))
    401 | 403 -> Error(InvalidGrant)
    400 ->
      case ir.string_field(body, "error") {
        Ok("invalid_grant") -> Error(InvalidGrant)
        _ -> Error(InvalidResponse)
      }
    status if status >= 500 -> Error(Unavailable)
    _ -> Error(InvalidResponse)
  }
}

fn identity_field(
  body: ir.Value,
  key: String,
  previous: Option(String),
) -> Result(Option(String), Failure) {
  let value = case ir.field(body, key) {
    None -> Ok(None)
    Some(value) -> {
      use _ <- result.try(ir.as_object(value) |> invalid_response)
      ir.optional_string(value, "uuid") |> invalid_response
    }
  }
  use value <- result.try(value)
  case previous, value {
    _, None | _, Some("") -> Ok(previous)
    Some(old), Some(new) if old != new -> Error(IdentityChanged)
    _, _ -> Ok(value)
  }
}

fn invalid_response(value: Result(a, String)) -> Result(a, Failure) {
  result.map_error(value, fn(_) { InvalidResponse })
}

/// CPA bounds refresh cooldown to 5s..5m. HTTP-date values require a runtime
/// clock-aware parser; absent/unsupported/invalid values conservatively use 5s.
pub fn retry_after(headers: List(Header)) -> Int {
  let seconds =
    list.find(headers, fn(header) {
      string.lowercase(header.name) == "retry-after"
    })
    |> result.try(fn(header) { int.parse(string.trim(header.value)) })
  case seconds {
    Ok(seconds) -> int.clamp(seconds, min: 5, max: 300) * 1000
    Error(_) -> {
      let milliseconds =
        list.find(headers, fn(header) {
          string.lowercase(header.name) == "retry-after-ms"
        })
        |> result.try(fn(header) { int.parse(string.trim(header.value)) })
        |> result.unwrap(5000)
      int.clamp(milliseconds, min: 5000, max: 300_000)
    }
  }
}
