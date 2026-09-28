/// Kimi device grant and refresh protocol. No implicit network access, browser
/// launching, sleeps, persistence or second account manager. The supplied send
/// callback must enforce approved endpoint TLS, timeout and no redirects/logs.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/json_guard
import mimic/types.{type Header, Header}

pub const client_id = "17e5f671-d194-4dfb-9706-5516cb48c098"

pub const device_grant = "urn:ietf:params:oauth:grant-type:device_code"

pub const refresh_lead_ms = 300_000

pub const default_interval_ms = 5000

pub const max_poll_ms = 900_000

/// Exact approved endpoints must be supplied by the operator, with a
/// deliberate domain choice. Fixture endpoints must be loopback HTTP only.
pub type Config {
  Config(
    domain: String,
    device_url: String,
    token_url: String,
    device_id: String,
  )
}

/// Secret-bearing in-memory plan; never capture, persist or log its body.
pub type TokenPlan {
  TokenPlan(url: String, headers: List(Header), body: String)
}

pub type TokenReply {
  TokenReply(status: Int, headers: List(Header), body: String)
}

pub type Send =
  fn(TokenPlan) -> Result(TokenReply, String)

pub opaque type Device {
  Device(
    code: String,
    user_code: String,
    verification_uri: String,
    deadline_ms: Int,
    interval_ms: Int,
    next_poll_ms: Int,
  )
}

pub type Poll {
  Pending(device: Device, wait_ms: Int)
  Authorized(credential: auth.Credential)
}

pub fn user_prompt(device: Device) -> #(String, String) {
  #(device.user_code, device.verification_uri)
}

pub fn validate(config: Config) -> Result(Nil, String) {
  use _ <- result.try(validate_endpoints(config))
  case safe(config.device_id) && string.trim(config.device_id) != "" {
    True -> Ok(Nil)
    False -> Error("Invalid Kimi OAuth device identity")
  }
}

/// Secret-free gateway configuration validation. A blank device_id is valid
/// here; login/import binds it from private input and refresher from OAuthData.
pub fn validate_endpoints(config: Config) -> Result(Nil, String) {
  use _ <- result.try(case config.domain {
    "kimi.com" | "kimi.ai" -> Ok(Nil)
    _ -> Error("Invalid Kimi domain")
  })
  use device <- result.try(approved_endpoint(
    config.domain,
    config.device_url,
    "/api/oauth/device_authorization",
  ))
  use token <- result.try(approved_endpoint(
    config.domain,
    config.token_url,
    "/api/oauth/token",
  ))
  case device == token {
    True -> Ok(Nil)
    False -> Error("Invalid Kimi OAuth endpoint pair")
  }
}

/// A single start call; no live request exists until the caller invokes this.
pub fn start(
  config: Config,
  send: Send,
  now_ms: Int,
) -> Result(Device, String) {
  use _ <- result.try(validate(config))
  use reply <- result.try(
    send(
      plan(config.device_url, config.device_id, [
        #("client_id", client_id),
      ]),
    )
    |> result.map_error(fn(_) { "Kimi device authorization unavailable" }),
  )
  use value <- result.try(json_guard.parse(reply.body))
  use _ <- result.try(
    case reply.status == 200 && ir.field(value, "error") == None {
      True -> Ok(Nil)
      False -> Error("Kimi device authorization rejected")
    },
  )
  use code <- result.try(ir.string_field(value, "device_code"))
  use user <- result.try(ir.string_field(value, "user_code"))
  use verification <- result.try(verification_url(value))
  use seconds <- result.try(
    ir.required(value, "expires_in") |> result.try(ir.as_int),
  )
  let interval = case ir.optional_int(value, "interval") {
    Ok(Some(value)) -> value
    Ok(None) -> 5
    Error(_) -> 0
  }
  use _ <- result.try(
    case
      code != ""
      && user != ""
      && seconds > 0
      && interval > 0
      && safe(code)
      && safe(user)
      && safe(verification)
    {
      True -> Ok(Nil)
      False -> Error("Invalid Kimi device authorization response")
    },
  )
  use _ <- result.try(verification_origin(config.domain, verification))
  Ok(Device(
    code,
    user,
    verification,
    now_ms + int.min(seconds * 1000, max_poll_ms),
    int.max(interval * 1000, default_interval_ms),
    now_ms + int.max(interval * 1000, default_interval_ms),
  ))
}

fn verification_url(value: ir.Value) -> Result(String, String) {
  case ir.optional_string(value, "verification_uri_complete") {
    Ok(Some(url)) if url != "" -> Ok(url)
    _ -> ir.string_field(value, "verification_uri")
  }
}

/// One poll step. The caller owns sleeping, cancellation, expiry and storage.
pub fn poll(
  config: Config,
  device: Device,
  send: Send,
  now_ms: Int,
  cancelled: Bool,
) -> Result(Poll, String) {
  use _ <- result.try(validate(config))
  case cancelled, now_ms >= device.deadline_ms, now_ms < device.next_poll_ms {
    True, _, _ -> Error("Kimi device authorization cancelled")
    _, True, _ -> Error("Kimi device authorization expired")
    _, _, True -> Ok(Pending(device, device.next_poll_ms - now_ms))
    _, _, _ -> {
      use reply <- result.try(
        send(
          plan(config.token_url, config.device_id, [
            #("client_id", client_id),
            #("device_code", device.code),
            #("grant_type", device_grant),
          ]),
        )
        |> result.map_error(fn(_) { "Kimi device authorization unavailable" }),
      )
      use value <- result.try(json_guard.parse(reply.body))
      let token_fields = has_token(value)
      case reply.status, ir.field(value, "error"), token_fields {
        200, Some(ir.String("authorization_pending")), False ->
          pending(device, now_ms, device.interval_ms)
        200, Some(ir.String("slow_down")), False ->
          pending(device, now_ms, device.interval_ms + default_interval_ms)
        _, Some(ir.String("expired_token")), _ ->
          Error("Kimi device authorization expired")
        _, Some(ir.String("access_denied")), _ ->
          Error("Kimi device authorization denied")
        _, Some(_), _ -> Error("Kimi device authorization rejected")
        200, None, _ -> parse_token(value, "", now_ms) |> result.map(Authorized)
        _, _, _ -> Error("Kimi device authorization rejected")
      }
    }
  }
}

fn pending(
  device: Device,
  now_ms: Int,
  interval_ms: Int,
) -> Result(Poll, String) {
  let wait = int.min(interval_ms, device.deadline_ms - now_ms)
  Ok(Pending(Device(..device, interval_ms:, next_poll_ms: now_ms + wait), wait))
}

/// Caller must persist OAuthData before using the rotated credential. Unknown
/// outcomes may conceal token rotation and are never eligible for blind retry.
pub fn refresh(
  config: Config,
  current: auth.Credential,
  send: Send,
  now_ms: Int,
) -> Result(auth.Credential, contracts.RefreshFailure) {
  use _ <- result.try(
    validate(config)
    |> result.map_error(fn(_) { contracts.RefreshUnsupported }),
  )
  use _ <- result.try(case string.trim(current.refresh_token) {
    "" -> Error(contracts.InvalidGrant)
    _ -> Ok(Nil)
  })
  use reply <- result.try(
    send(
      plan(config.token_url, config.device_id, [
        #("client_id", client_id),
        #("grant_type", "refresh_token"),
        #("refresh_token", current.refresh_token),
      ]),
    )
    |> result.map_error(fn(_) { contracts.RefreshUnavailable }),
  )
  // A bare status cannot establish whether a rotating grant was consumed.
  use value <- result.try(
    json_guard.parse(reply.body)
    |> result.map_error(fn(_) { contracts.RefreshUnavailable }),
  )
  case reply.status, ir.field(value, "error"), has_token(value) {
    400, Some(ir.String("invalid_grant")), False ->
      Error(contracts.InvalidGrant)
    401, Some(ir.String("invalid_grant")), False ->
      Error(contracts.InvalidGrant)
    200, None, _ ->
      parse_token(value, current.refresh_token, now_ms)
      |> result.map_error(fn(_) { contracts.RefreshUnavailable })
    _, _, _ -> Error(contracts.RefreshUnavailable)
  }
}

/// Runtime invokes the callback under its own refresh singleflight/fence.
pub fn refresher(config: Config, send: Send) -> contracts.Refresh {
  contracts.Refresh(fn(data, now_ms) {
    case
      list.filter(data.private_metadata, fn(pair) { pair.0 == "domain" }),
      list.filter(data.private_metadata, fn(pair) { pair.0 == "device_id" }),
      list.filter(data.private_metadata, fn(pair) { pair.0 == "token_url" })
    {
      [#(_, domain)], [#(_, device_id)], [#(_, token_url)]
        if domain == config.domain && token_url == config.token_url
      ->
        // Device identity is private per grant, not a provider-wide Config
        // capture. The callback binds and revalidates it on every refresh.
        refresh(Config(..config, device_id:), data.credential, send, now_ms)
        |> result.map(fn(credential) {
          contracts.OAuthData(..data, credential:)
        })
      _, _, _ -> Error(contracts.RefreshUnsupported)
    }
  })
}

/// Private domain/device identity persists with the runtime's 0600 grant file.
pub fn material(
  config: Config,
  credential: auth.Credential,
) -> Result(contracts.AuthMaterial, String) {
  use _ <- result.try(validate(config))
  use _ <- result.try(
    case
      string.trim(credential.access_token) != ""
      && string.trim(credential.refresh_token) != ""
      && safe(credential.access_token)
      && safe(credential.refresh_token)
      && credential.expires_at_ms > 0
      && credential.expires_at_ms <= 9_999_999_999_999
    {
      True -> Ok(Nil)
      False -> Error("Invalid Kimi OAuth credential")
    },
  )
  Ok(
    contracts.OAuth(
      contracts.OAuthData(credential, [
        #("domain", config.domain),
        #("device_id", config.device_id),
        #("token_url", config.token_url),
      ]),
    ),
  )
}

/// A saved, positive but expired grant is importable: runtime must refresh
/// before use. Do not invent an expiry when importing external credentials.
pub fn import_material(
  config: Config,
  credential: auth.Credential,
) -> Result(contracts.AuthMaterial, String) {
  material(config, credential)
}

fn parse_token(
  value: ir.Value,
  previous_refresh: String,
  now_ms: Int,
) -> Result(auth.Credential, String) {
  use access <- result.try(ir.string_field(value, "access_token"))
  use maybe_refresh <- result.try(ir.optional_string(value, "refresh_token"))
  let refresh = case maybe_refresh {
    Some(token) if token != "" -> token
    Some(_) | None -> previous_refresh
  }
  use maybe_seconds <- result.try(ir.optional_int(value, "expires_in"))
  let seconds = case maybe_seconds {
    Some(value) -> value
    None -> 0
  }
  use token_type <- result.try(ir.optional_string(value, "token_type"))
  case
    access != ""
    && safe(access)
    && safe(refresh)
    && seconds > 0
    && seconds <= 2_147_483
    && case token_type {
      None -> True
      Some(value) -> string.lowercase(value) == "bearer"
    }
  {
    True -> Ok(auth.Credential(access, refresh, now_ms + seconds * 1000))
    False -> Error("Invalid Kimi token response")
  }
}

fn has_token(value: ir.Value) -> Bool {
  ir.field(value, "access_token") != None
  || ir.field(value, "refresh_token") != None
}

fn plan(
  url: String,
  device_id: String,
  fields: List(#(String, String)),
) -> TokenPlan {
  TokenPlan(
    url,
    [
      Header("Content-Type", "application/x-www-form-urlencoded"),
      Header("Accept", "application/json"),
      Header("X-Msh-Device-Id", device_id),
    ],
    uri.query_to_string(fields),
  )
}

fn approved_endpoint(
  domain: String,
  url: String,
  path: String,
) -> Result(String, String) {
  case uri.parse(url) {
    Ok(uri.Uri(scheme, None, Some(host), port, actual_path, None, None))
      if actual_path == path
    -> {
      let official_host = case domain {
        "kimi.ai" -> "auth.kimi.ai"
        _ -> "auth.kimi.com"
      }
      case
        { scheme == Some("https") && host == official_host && port == None }
        || {
          scheme == Some("http")
          && { host == "127.0.0.1" || host == "[::1]" || host == "::1" }
          && case port {
            Some(p) -> p > 0 && p <= 65_535
            None -> True
          }
        }
      {
        True ->
          Ok(
            host
            <> ":"
            <> case port {
              Some(p) -> int.to_string(p)
              None -> ""
            },
          )
        False -> Error("Unapproved Kimi OAuth endpoint")
      }
    }
    _ -> Error("Unapproved Kimi OAuth endpoint")
  }
}

fn verification_origin(domain: String, url: String) -> Result(Nil, String) {
  case uri.parse(url) {
    Ok(uri.Uri(Some("https"), None, Some(host), _, _, _, None)) ->
      case host == domain || host == "auth." <> domain {
        True -> Ok(Nil)
        False -> Error("Unapproved Kimi verification URL")
      }
    Ok(uri.Uri(Some("http"), None, Some(host), _, _, _, None))
      if host == "127.0.0.1" || host == "[::1]" || host == "::1"
    -> Ok(Nil)
    _ -> Error("Unapproved Kimi verification URL")
  }
}

fn safe(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}
