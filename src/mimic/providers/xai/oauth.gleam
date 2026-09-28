import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/ir
import mimic/providers/xai/endpoint
import mimic/providers/xai/json_guard

pub const issuer = "https://auth.x.ai"

pub const discovery_url = "https://auth.x.ai/.well-known/openid-configuration"

pub const client_id = "b1a00492-073a-47ea-816f-4c329264a828"

pub const scope = "openid profile email offline_access grok-cli:access api:access"

pub const device_grant = "urn:ietf:params:oauth:grant-type:device_code"

pub const default_interval_ms = 5000

pub const max_poll_ms = 1_800_000

pub const http_timeout_ms = 30_000

pub const refresh_lead_ms = 300_000

/// Injected transport must verify TLS, refuse redirects and never log bodies.
/// Use http_send for the normal implementation. Clock is caller-owned.
pub type Send =
  fn(request.Request(String)) -> Result(response.Response(String), String)

pub type Config {
  Config(discovery_url: String, policy: endpoint.EndpointPolicy)
}

pub type Discovery {
  Discovery(device_endpoint: String, token_endpoint: String)
}

/// Contains the private device code; never serialize into captures/logs.
/// Display only user_code and verification_uri to the initiating operator.
pub opaque type Device {
  Device(
    device_code: String,
    user_code: String,
    verification_uri: String,
    token_endpoint: String,
    deadline_ms: Int,
    interval_ms: Int,
    next_poll_ms: Int,
  )
}

pub type Poll {
  Pending(device: Device, wait_ms: Int)
  Authorized(auth.Credential)
}

pub type RefreshError {
  InvalidGrant
  RateLimited(retry_after_ms: Int)
  Unavailable
}

pub fn user_prompt(device: Device) -> #(String, String) {
  #(device.user_code, device.verification_uri)
}

pub fn http_send(
  req: request.Request(String),
) -> Result(response.Response(String), String) {
  httpc.dispatch(httpc.configure() |> httpc.timeout(http_timeout_ms), req)
  |> result.map_error(fn(_) { "xAI OAuth transport unavailable" })
}

pub fn discover(config: Config, send: Send) -> Result(Discovery, String) {
  use _ <- result.try(validate_endpoint(config.discovery_url, config.policy))
  use req <- result.try(
    request.to(config.discovery_url)
    |> result.map_error(fn(_) { "Invalid xAI discovery URL" }),
  )
  use reply <- result.try(
    send(request.set_header(req, "accept", "application/json"))
    |> result.map_error(fn(_) { "xAI discovery unavailable" }),
  )
  use body <- result.try(json_guard.parse(reply.body))
  use _ <- result.try(ok_status(reply.status))
  use _ <- result.try(case ir.field(body, "error") == None {
    True -> Ok(Nil)
    False -> Error("Invalid xAI discovery response")
  })
  use device <- result.try(ir.string_field(
    body,
    "device_authorization_endpoint",
  ))
  use token <- result.try(ir.string_field(body, "token_endpoint"))
  let discovery = Discovery(device, token)
  use _ <- result.try(validate_endpoint(
    discovery.device_endpoint,
    config.policy,
  ))
  use _ <- result.try(validate_endpoint(discovery.token_endpoint, config.policy))
  Ok(discovery)
}

pub fn start(
  config: Config,
  discovery: Discovery,
  send: Send,
  now_ms: Int,
) -> Result(Device, String) {
  use _ <- result.try(validate_endpoint(discovery.token_endpoint, config.policy))
  use reply <- result.try(post(
    config,
    discovery.device_endpoint,
    [
      #("client_id", client_id),
      #("scope", scope),
    ],
    send,
  ))
  use body <- result.try(json_guard.parse(reply.body))
  use _ <- result.try(ok_status(reply.status))
  use _ <- result.try(case ir.field(body, "error") == None {
    True -> Ok(Nil)
    False -> Error("Invalid xAI device response")
  })
  use code <- result.try(ir.string_field(body, "device_code"))
  use user <- result.try(ir.string_field(body, "user_code"))
  use verification <- result.try(ir.string_field(body, "verification_uri"))
  use expires <- result.try(
    ir.required(body, "expires_in") |> result.try(ir.as_int),
  )
  use interval <- result.try(ir.optional_int(body, "interval"))
  let interval = case interval {
    Some(value) -> value
    None -> 5
  }
  use _ <- result.try(validate_endpoint(verification, config.policy))
  case
    string.trim(code) == ""
    || string.trim(user) == ""
    || expires <= 0
    || interval <= 0
  {
    True -> Error("Invalid xAI device lifetime or code")
    False ->
      Ok(Device(
        code,
        user,
        verification,
        discovery.token_endpoint,
        now_ms + int.min(expires * 1000, max_poll_ms),
        int.min(interval * 1000, max_poll_ms),
        now_ms,
      ))
  }
}

/// One bounded poll step: caller owns cancellation, sleeping and persistence.
/// No network call occurs before next_poll_ms or at/after expiration.
pub fn poll(
  config: Config,
  device: Device,
  send: Send,
  now_ms: Int,
  cancelled: Bool,
) -> Result(Poll, String) {
  case cancelled {
    True -> Error("xAI device authorization cancelled")
    False if now_ms >= device.deadline_ms ->
      Error("xAI device authorization expired")
    False if now_ms < device.next_poll_ms ->
      Ok(Pending(device, device.next_poll_ms - now_ms))
    False -> {
      use reply <- result.try(post(
        config,
        device.token_endpoint,
        [
          #("grant_type", device_grant),
          #("device_code", device.device_code),
          #("client_id", client_id),
        ],
        send,
      ))
      use body <- result.try(json_guard.parse(reply.body))
      let token_fields = has_token_fields(body)
      case oauth_error(body) {
        "authorization_pending" if reply.status == 400 && !token_fields ->
          pending(device, now_ms, device.interval_ms)
        "slow_down" if reply.status == 400 && !token_fields ->
          pending(device, now_ms, device.interval_ms + default_interval_ms)
        "access_denied" -> Error("xAI device authorization denied")
        "expired_token" -> Error("xAI device authorization expired")
        "" -> {
          use _ <- result.try(ok_status(reply.status))
          use _ <- result.try(case ir.field(body, "error") == None {
            True -> Ok(Nil)
            False -> Error("xAI device token rejected")
          })
          token(body, "", now_ms) |> result.map(Authorized)
        }
        _ -> Error("xAI device token rejected")
      }
    }
  }
}

fn pending(device: Device, now_ms: Int, interval: Int) -> Result(Poll, String) {
  let wait = int.min(interval, device.deadline_ms - now_ms)
  Ok(Pending(
    Device(..device, interval_ms: interval, next_poll_ms: now_ms + wait),
    wait,
  ))
}

/// Runtime wraps this callback in singleflight and persists before use.
/// The saved token endpoint is revalidated on every refresh.
pub fn refresh(
  config: Config,
  token_endpoint: String,
  current: auth.Credential,
  send: Send,
  now_ms: Int,
) -> Result(auth.Credential, String) {
  refresh_outcome(config, token_endpoint, current, send, now_ms)
  |> result.map_error(fn(failure) {
    case failure {
      InvalidGrant -> "xAI refresh requires reauthorization"
      RateLimited(_) | Unavailable -> "xAI refresh unavailable"
    }
  })
}

/// Runtime v4 refresh fence: only a recognized, unambiguous 429 may carry
/// rate-limit cooldown. Transport errors and malformed successes may conceal
/// rotation; a bare status, contradictory token fields or duplicate key does
/// not authorize retry.
pub fn refresh_outcome(
  config: Config,
  token_endpoint: String,
  current: auth.Credential,
  send: Send,
  now_ms: Int,
) -> Result(auth.Credential, RefreshError) {
  case string.trim(current.refresh_token) == "" {
    True -> Error(InvalidGrant)
    False -> {
      use reply <- result.try(
        post(
          config,
          token_endpoint,
          [
            #("grant_type", "refresh_token"),
            #("refresh_token", current.refresh_token),
            #("client_id", client_id),
          ],
          send,
        )
        |> result.map_error(fn(_) { Unavailable }),
      )
      use body <- result.try(
        json_guard.parse(reply.body)
        |> result.map_error(fn(_) { Unavailable }),
      )
      let token_fields = has_token_fields(body)
      let has_error = ir.field(body, "error") != None
      case reply.status, oauth_error(body) {
        400, "invalid_grant" if !token_fields -> Error(InvalidGrant)
        429, "rate_limit_exceeded" if !token_fields ->
          case retry_after(reply) {
            Ok(delay) -> Error(RateLimited(delay))
            Error(_) -> Error(Unavailable)
          }
        200, "" if !has_error ->
          token(body, current.refresh_token, now_ms)
          |> result.map_error(fn(_) { Unavailable })
        _, _ -> Error(Unavailable)
      }
    }
  }
}

fn has_token_fields(body: ir.Value) -> Bool {
  list.any(
    ["access_token", "refresh_token", "id_token", "token_type", "expires_in"],
    fn(key) { ir.field(body, key) != None },
  )
}

fn retry_after(reply: response.Response(String)) -> Result(Int, Nil) {
  let headers =
    reply.headers
    |> list.filter(fn(pair) { string.lowercase(pair.0) == "retry-after" })
  case headers {
    [] -> Ok(0)
    [#(_, value)] ->
      case int.parse(string.trim(value)) {
        Ok(seconds) if seconds >= 0 && seconds <= 86_400 -> Ok(seconds * 1000)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn post(
  config: Config,
  url: String,
  form: List(#(String, String)),
  send: Send,
) {
  use _ <- result.try(validate_endpoint(url, config.policy))
  use req <- result.try(
    request.to(url) |> result.map_error(fn(_) { "Invalid xAI OAuth URL" }),
  )
  send(
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_header("accept", "application/json")
    |> request.set_body(uri.query_to_string(form)),
  )
  |> result.map_error(fn(_) { "xAI OAuth transport unavailable" })
}

fn ok_status(status: Int) -> Result(Nil, String) {
  case status {
    200 -> Ok(Nil)
    _ -> Error("xAI OAuth endpoint rejected request")
  }
}

fn oauth_error(body: ir.Value) -> String {
  ir.string_field(body, "error") |> result.unwrap("")
}

fn token(body: ir.Value, previous_refresh: String, now_ms: Int) {
  use access <- result.try(ir.string_field(body, "access_token"))
  use refresh <- result.try(ir.optional_string(body, "refresh_token"))
  use kind <- result.try(ir.optional_string(body, "token_type"))
  use expires <- result.try(
    ir.required(body, "expires_in") |> result.try(ir.as_int),
  )
  let refresh = case refresh {
    Some(value) -> value
    None -> ""
  }
  let kind = case kind {
    Some(value) -> value
    None -> "Bearer"
  }
  let refresh = case string.trim(refresh) {
    "" -> previous_refresh
    _ -> refresh
  }
  case
    string.trim(access) == ""
    || string.trim(refresh) == ""
    || expires <= 0
    || string.lowercase(kind) != "bearer"
    || string.contains(access, "\r")
    || string.contains(access, "\n")
  {
    True -> Error("Invalid xAI token response")
    False -> Ok(auth.Credential(access, refresh, now_ms + expires * 1000))
  }
}

/// Apply this to discovered device and token endpoints, including stored
/// refresh endpoints. No redirects to unvalidated origins are authorized.
pub fn validate_endpoint(
  url: String,
  policy: endpoint.EndpointPolicy,
) -> Result(Nil, String) {
  case endpoint.validate_base(url, policy) {
    Error(error) -> Error(error)
    Ok(_) ->
      case policy {
        endpoint.LocalMock -> Ok(Nil)
        endpoint.VerifiedTls ->
          case uri.parse(url) {
            Ok(uri.Uri(_, None, Some(host), _, _, None, None)) -> {
              let host = string.lowercase(host)
              case host == "x.ai" || string.ends_with(host, ".x.ai") {
                True -> Ok(Nil)
                False -> Error("xAI discovery endpoint is outside x.ai")
              }
            }
            _ -> Error("Invalid xAI discovery endpoint")
          }
      }
  }
}
