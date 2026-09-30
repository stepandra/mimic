/// Route INTENT, not server registration. Coordinator applies ingress auth
/// before dispatching any alias. A Chat Completions request is never native Codex.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/providers/codex/lite
import mimic/providers/codex/oauth
import mimic/types.{type Header}

pub type Operation {
  Responses
  /// Internal gateway intent, not a distinct public URL.
  Lite
  Compact
  Models
}

pub type Transport {
  Http
  Websocket
}

pub type Route {
  Route(operation: Operation, transport: Transport, native: Bool)
}

/// Codex 0.158.0 thread-granular hint, NOT authentication. Integration namespaces
/// it under its authenticated principal before setting Request.session.
/// session-id is deliberately ignored: native clients also use it for cache
/// affinity/shared subagents. x-codex-turn-state must not span turns.
pub fn client_session_hint(
  headers: List(Header),
) -> Result(Option(String), String) {
  use thread <- result.try(single_hint(headers, "thread-id"))
  use request <- result.try(single_hint(headers, "x-client-request-id"))
  case thread, request {
    Some(thread), Some(request) if thread != request ->
      Error("conflicting Codex thread identifiers")
    Some(value), _ | _, Some(value) -> Ok(Some(value))
    None, None -> Ok(None)
  }
}

fn single_hint(
  headers: List(Header),
  name: String,
) -> Result(Option(String), String) {
  case list.filter(headers, fn(h) { string.lowercase(h.name) == name }) {
    [] -> Ok(None)
    [header] ->
      case
        oauth.safe_header(header.value)
        && string.byte_size(header.value) <= 1024
      {
        True -> Ok(Some(header.value))
        False -> Error("invalid Codex thread identifier")
      }
    _ -> Error("duplicate Codex thread identifier")
  }
}

/// Gateway hook after ingress authentication. Lite shares Responses aliases;
/// there is intentionally no /responses/lite URL.
pub fn resolve_http(
  method: String,
  path: String,
  native_hint: Bool,
  headers: List(Header),
) -> Result(Route, String) {
  use route <- result.try(resolve(method, path, False, native_hint))
  use enabled <- result.try(lite.header_enabled(headers))
  case enabled, route.operation {
    False, _ -> Ok(route)
    True, Responses -> Ok(Route(Lite, Http, True))
    True, _ -> Error("Responses-lite header requires ordinary Responses route")
  }
}

pub fn resolve(
  method: String,
  path: String,
  upgrade: Bool,
  native_hint: Bool,
) -> Result(Route, String) {
  case method, path, upgrade {
    "POST", "/v1/responses", False | "POST", "/responses", False ->
      Ok(Route(Responses, Http, native_hint))
    "POST", "/backend-api/codex/responses", False ->
      Ok(Route(Responses, Http, True))
    "GET", "/v1/responses", True | "GET", "/responses", True ->
      Ok(Route(Responses, Websocket, native_hint))
    "GET", "/backend-api/codex/responses", True ->
      Ok(Route(Responses, Websocket, True))
    "POST", "/v1/responses/compact", False
    | "POST", "/responses/compact", False
    -> Ok(Route(Compact, Http, native_hint))
    "POST", "/backend-api/codex/responses/compact", False ->
      Ok(Route(Compact, Http, True))
    "GET", "/backend-api/codex/models", False | "GET", "/models", False ->
      Ok(Route(Models, Http, True))
    "GET", "/v1/models", False -> Ok(Route(Models, Http, native_hint))
    _, _, _ -> Error("unsupported Codex route or transport")
  }
}
