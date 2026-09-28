/// Route INTENT, not server registration. Coordinator applies ingress auth
/// before dispatching any alias. A Chat Completions request is never native Codex.
pub type Operation {
  Responses
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
