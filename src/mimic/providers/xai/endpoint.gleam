import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/types.{type Header, Header}

pub const api_base = "https://api.x.ai/v1"

pub const proxy_base = "https://cli-chat-proxy.grok.com/v1"

pub type Mode {
  ApiKey
  DeviceOAuth
}

pub type Operation {
  Chat
  Responses
  Compact
  WebSocket
}

/// LocalMock never permits non-loopback endpoints, even if HTTPS.
pub type EndpointPolicy {
  VerifiedTls
  LocalMock
}

/// Overrides are operation-specific. Secrets are supplied by the runtime,
/// never included in a plan or copied from downstream request headers.
pub type Config {
  Config(
    mode: Mode,
    using_api: Bool,
    websockets: Bool,
    http_base: Option(String),
    compact_base: Option(String),
    websocket_base: Option(String),
    policy: EndpointPolicy,
  )
}

pub type Plan {
  Plan(url: String, operation: Operation, proxy_identity: Bool)
}

pub fn defaults(mode: Mode) -> Config {
  Config(mode, mode == ApiKey, False, None, None, None, VerifiedTls)
}

/// Auto only upgrades streaming downstream WS requests. Required replay cannot
/// silently change protocols. Compact remains an explicit HTTP operation.
pub fn select_auto(
  config: Config,
  streaming: Bool,
  downstream_websocket: Bool,
  requires_websocket: Bool,
) -> Result(Plan, String) {
  case streaming && downstream_websocket && config.websockets {
    True -> select(config, WebSocket)
    False if requires_websocket ->
      Error("xAI replay requires enabled upstream WebSocket")
    False -> select(config, Responses)
  }
}

pub fn select(config: Config, operation: Operation) -> Result(Plan, String) {
  use base <- result.try(case operation {
    WebSocket if !config.websockets -> Error("xAI WebSocket is not enabled")
    WebSocket -> Ok(option.unwrap(config.websocket_base, api_base))
    Compact -> Ok(option.unwrap(config.compact_base, api_base))
    Chat | Responses -> {
      let configured = trim_slashes(option.unwrap(config.http_base, api_base))
      Ok(case config.using_api || configured != api_base {
        True -> configured
        False -> proxy_base
      })
    }
  })
  let base = trim_slashes(base)
  use _ <- result.try(validate_base(base, config.policy))
  use _ <- result.try(case operation {
    Compact | WebSocket ->
      case is_proxy(base) {
        True -> Error("Grok CLI proxy does not support compact or WebSocket")
        False -> Ok(Nil)
      }
    _ -> Ok(Nil)
  })
  let path = case operation {
    Compact -> "/responses/compact"
    _ -> "/responses"
  }
  let url = case operation {
    WebSocket ->
      base
      |> string.replace("https://", "wss://")
      |> string.replace("http://", "ws://")
    _ -> base
  }
  Ok(Plan(
    url <> path,
    operation,
    !config.using_api
      && base == proxy_base
      && operation != Compact
      && operation != WebSocket,
  ))
}

fn is_proxy(base: String) -> Bool {
  case uri.parse(base) {
    Ok(uri.Uri(host: Some(host), ..)) ->
      string.lowercase(host) == "cli-chat-proxy.grok.com"
    _ -> False
  }
}

pub fn validate_base(
  base: String,
  policy: EndpointPolicy,
) -> Result(Nil, String) {
  case uri.parse(base) {
    Ok(uri.Uri(scheme, None, Some(host), port, path, None, None)) -> {
      let transport_ok = case policy {
        VerifiedTls -> scheme == Some("https")
        LocalMock ->
          scheme == Some("http")
          && { host == "127.0.0.1" || host == "[::1]" || host == "::1" }
      }
      let port_ok = case port {
        None -> True
        Some(p) -> p > 0 && p <= 65_535
      }
      case
        transport_ok
        && port_ok
        && host != ""
        && !string.contains(base, "\\")
        && !string.contains(base, " ")
        && !string.contains(base, "\n")
        && !string.contains(base, "\r")
        && { path == "" || string.starts_with(path, "/") }
      {
        True -> Ok(Nil)
        False -> Error("Invalid xAI endpoint transport or authority")
      }
    }
    _ -> Error("xAI endpoint must not contain userinfo, query or fragment")
  }
}

pub fn headers(
  plan: Plan,
  conversation_id: String,
) -> Result(List(Header), String) {
  use _ <- result.try(case safe_header(conversation_id) {
    True -> Ok(Nil)
    False -> Error("Invalid xAI conversation identifier")
  })
  let accept = case plan.operation {
    Compact | WebSocket -> "application/json"
    _ -> "text/event-stream"
  }
  let base = [
    Header("Content-Type", "application/json"),
    Header("Accept", accept),
  ]
  let base = case conversation_id {
    "" -> base
    _ -> list.append(base, [Header("x-grok-conv-id", conversation_id)])
  }
  Ok(case plan.proxy_identity {
    False -> base
    True ->
      list.append(base, [
        Header("X-XAI-Token-Auth", "xai-grok-cli"),
        Header("x-grok-client-version", "0.2.120"),
        Header("User-Agent", "xai-grok-workspace/0.2.120"),
        Header("x-grok-client-identifier", "grok-shell"),
        Header("x-authenticateresponse", "authenticate-response"),
      ])
  })
}

fn safe_header(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn trim_slashes(base: String) -> String {
  case string.ends_with(base, "/") {
    True -> trim_slashes(string.drop_end(base, 1))
    False -> base
  }
}

/// Structured key, never delimiter concatenation; no credentials in the key.
pub type SessionKey {
  SessionKey(
    tenant: String,
    credential_id: String,
    mode: Mode,
    endpoint: String,
    conversation: String,
  )
}

pub fn session_key(
  tenant: String,
  credential_id: String,
  mode: Mode,
  plan: Plan,
  conversation: String,
) -> Result(SessionKey, String) {
  case tenant == "" || credential_id == "" || conversation == "" {
    True -> Error("xAI session requires tenant, credential and conversation")
    False -> Ok(SessionKey(tenant, credential_id, mode, plan.url, conversation))
  }
}
