/// xAI Responses on a single credential-scoped physical WS/WSS connection.
/// Shared Session owns continuation/pairing; shared transport owns RFC6455/TLS.
/// No reconnect, HTTP fallback, credential transfer or uncertain-send replay.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth/crypto
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket
import mimic/providers/contracts
import mimic/providers/ws_transport
import mimic/providers/xai/endpoint
import mimic/providers/xai/json_guard
import mimic/providers/xai/request as xai_request
import mimic/providers/xai/tools
import mimic/types.{Header}

pub opaque type Handle {
  Handle(
    connection: ws_transport.Connection,
    protocol: websocket.Session,
    scope: websocket.Scope,
    generation: String,
    config: endpoint.Config,
    auth_mode: String,
    operation: String,
    client_session: String,
    refs: List(tools.Ref),
  )
}

pub fn adapter(
  tenant: String,
  config: endpoint.Config,
  ca_file: Option(String),
) -> contracts.SessionAdapter(Handle) {
  contracts.SessionAdapter(
    open: fn(context, request) {
      open(tenant, config, ca_file, context, request)
    },
    send: send,
    receive: receive,
    cancel: fn(handle) { ws_transport.close(handle.connection) },
  )
}

/// For accounts whose selected runtime origin is approved for WebSocket.
/// OAuth proxy HTTP origin is NOT automatically upgraded or moved to api.x.ai.
pub fn selected_adapter(
  tenant: String,
  config: endpoint.Config,
  ca_file: Option(String),
) -> contracts.SessionAdapter(Handle) {
  let adapter = adapter(tenant, config, ca_file)
  contracts.SessionAdapter(
    ..adapter,
    open: fn(context: contracts.Context, request: contracts.Request) {
      use _ <- result.try(check(request.operation == "responses/websocket"))
      open(
        tenant,
        endpoint.Config(..config, websocket_base: Some(context.origin <> "/v1")),
        ca_file,
        context,
        request,
      )
    },
  )
}

fn open(
  tenant: String,
  config: endpoint.Config,
  ca_file: Option(String),
  context: contracts.Context,
  request: contracts.Request,
) {
  let mode = case config.mode {
    endpoint.ApiKey -> "api_key"
    endpoint.DeviceOAuth -> "oauth"
  }
  use _ <- result.try(check(
    tenant != ""
    && context.provider == "xai"
    && context.auth_mode == mode
    && context.account != ""
    && context.session_key != ""
    && request.session != "",
  ))
  use _ <- result.try(check_request(request, mode, context.account))
  use token <- result.try(case config.mode, context.credential {
    endpoint.ApiKey, contracts.ApiKey(token) -> Ok(token)
    endpoint.DeviceOAuth, contracts.OAuth(data) ->
      Ok(data.credential.access_token)
    _, _ -> Error(failure(contracts.NotSent))
  })
  use _ <- result.try(check(
    string.trim(token) != ""
    && !string.contains(token, "\r")
    && !string.contains(token, "\n")
    && !string.contains(token, "\u{0000}"),
  ))
  use plan <- result.try(endpoint.select(config, endpoint.WebSocket) |> before)
  use url <- result.try(
    uri.parse(plan.url) |> result.replace_error(failure(contracts.NotSent)),
  )
  let scheme = case url.scheme {
    Some("wss") -> Some("https")
    _ -> Some("http")
  }
  let origin =
    uri.to_string(
      uri.Uri(..url, scheme: scheme, path: "", query: None, fragment: None),
    )
  use _ <- result.try(check(origin == context.origin))
  let scope =
    websocket.Scope(
      tenant,
      "xai",
      crypto.pkce_challenge(token),
      context.account,
      request.model,
      context.session_key,
    )
  let generation = fresh_id()
  use protocol <- result.try(websocket.new(scope, generation) |> before)
  // Validate the first message before even the upgrade. open does not send it.
  use _ <- result.try(
    prepare(protocol, scope, generation, config, request.body) |> before,
  )
  use headers <- result.try(
    endpoint.headers(plan, context.session_key) |> before,
  )
  use connection <- result.try(
    ws_transport.open(
      context.origin,
      origin,
      url.path,
      [Header("Authorization", "Bearer " <> token), ..headers],
      ws_transport.Config(ca_file, 5000, 20, 1_048_576, 1_048_576),
    )
    |> result.replace_error(failure(contracts.Uncertain)),
  )
  Ok(contracts.Opened(
    101,
    [],
    Handle(
      connection,
      protocol,
      scope,
      generation,
      config,
      mode,
      request.operation,
      request.session,
      [],
    ),
  ))
}

fn check_request(request: contracts.Request, mode: String, account: String) {
  check(
    request.provider == "xai"
    && request.auth_mode == mode
    && request.protocol == "responses"
    && {
      request.operation == "responses"
      || request.operation == "responses/websocket"
    }
    && request.mode == contracts.Streaming
    && list.contains(request.required, contracts.WebSocket)
    && list.all(request.required, fn(capability) {
      list.contains(
        [
          contracts.Stream,
          contracts.Tools,
          contracts.Continuation,
          contracts.WebSocket,
        ],
        capability,
      )
    })
    && {
      request.pinned_account == None || request.pinned_account == Some(account)
    },
  )
}

fn prepare(protocol, scope, generation, config, body) {
  use document <- result.try(json_guard.parse(body))
  use _ <- result.try(case ir.field(document, "generate") {
    Some(ir.Boolean(False)) -> Error("xAI warmup is not enabled")
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    case
      list.any(
        [
          "prompt_cache_retention",
          "safety_identifier",
          "stream_options",
          "stop",
        ],
        fn(key) { ir.field(document, key) != None },
      )
    {
      True -> Error("Unsupported xAI request field")
      False -> Ok(Nil)
    },
  )
  use created <- result.try(websocket.create(protocol, scope, generation, body))
  use prepared <- result.try(xai_request.prepare(
    config,
    endpoint.WebSocket,
    created.1.document,
    scope.client_session,
  ))
  use native <- result.try(
    responses.request_from_value(tools.remove(prepared.body, ["type"])),
  )
  use message <- result.try(websocket.encode_create(native))
  Ok(#(created.0, prepared.tool_refs, message))
}

fn send(handle: Handle, request: contracts.Request) {
  use _ <- result.try(
    check_request(request, handle.auth_mode, handle.scope.account)
    |> result.replace_error(failure(contracts.Started)),
  )
  use _ <- result.try(
    check(
      request.session == handle.client_session
      && request.model == handle.scope.model
      && request.operation == handle.operation,
    )
    |> result.replace_error(failure(contracts.Started)),
  )
  use prepared <- result.try(
    prepare(
      handle.protocol,
      handle.scope,
      handle.generation,
      handle.config,
      request.body,
    )
    |> after,
  )
  use _ <- result.try(ws_transport.send(handle.connection, prepared.2) |> after)
  Ok(Handle(..handle, protocol: prepared.0, refs: prepared.1))
}

fn receive(handle: Handle) {
  use polled <- result.try(ws_transport.poll(handle.connection) |> after)
  let handle = Handle(..handle, connection: polled.0)
  case polled.1 {
    None -> Ok(#(None, handle))
    Some(message) -> {
      use document <- result.try(json_guard.parse(message) |> after)
      // Validate wire identities BEFORE restoration: different namespaces can
      // have the same short name. Session receipts pair call ids/kinds, not
      // aliases, so its request-side pairing needs no name rewriting.
      use received <- result.try(
        websocket.receive(
          handle.protocol,
          handle.scope,
          handle.generation,
          message,
        )
        |> after,
      )
      use _ <- result.try(case stream.terminal_response(received.1) {
        Ok(response) ->
          case ir.field(response.document, "model") {
            None -> Ok(Nil)
            Some(ir.String(model)) if model == handle.scope.model -> Ok(Nil)
            _ -> Error(failure(contracts.Started))
          }
        Error(_) -> Ok(Nil)
      })
      let restored =
        xai_request.restore_event(document, handle.refs) |> ir.stringify
      Ok(#(Some(restored), Handle(..handle, protocol: received.0)))
    }
  }
}

fn check(valid) {
  case valid {
    True -> Ok(Nil)
    False -> Error(failure(contracts.NotSent))
  }
}

fn failure(delivery) {
  contracts.Failure(contracts.InvalidResponse, delivery, None)
}

fn before(value) {
  result.replace_error(value, failure(contracts.NotSent))
}

fn after(value) {
  result.replace_error(value, failure(contracts.Started))
}

@external(erlang, "mimic_gateway_ffi", "fresh_id")
fn fresh_id() -> String
