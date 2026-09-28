/// Codex OAuth Responses over one credential-scoped physical connection.
/// No HTTP fallback, transcript repair, reconnect or uncertain-send replay.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/auth/crypto
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket
import mimic/providers/codex/json_guard
import mimic/providers/codex/models
import mimic/providers/codex/oauth
import mimic/providers/codex/request as codex_request
import mimic/providers/codex/routes
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/providers/ws_transport
import mimic/types.{Header}

pub opaque type Handle {
  Handle(
    connection: ws_transport.Connection,
    protocol: websocket.Session,
    scope: websocket.Scope,
    generation: String,
    context: codex_request.Context,
    efforts: List(String),
    receipt: Option(session.Continuation),
    prepared: codex_request.Prepared,
  )
}

pub fn adapter(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
) -> contracts.SessionAdapter(Handle) {
  contracts.SessionAdapter(
    open: fn(context, request) {
      open(tenant, catalog, user_agent, ca_file, context, request)
    },
    send: send,
    receive: receive,
    cancel: fn(handle) { ws_transport.close(handle.connection) },
  )
}

fn open(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  context: contracts.Context,
  request: contracts.Request,
) -> Result(contracts.Opened(Handle), contracts.Failure) {
  use _ <- result.try(check(
    tenant != ""
    && context.provider == "codex"
    && context.auth_mode == "oauth"
    && request.provider == "codex"
    && request.auth_mode == "oauth"
    && request.protocol == "responses"
    && request.operation == "responses"
    && list.contains(request.required, contracts.WebSocket),
  ))
  use data <- result.try(case context.credential {
    contracts.OAuth(data) -> Ok(data)
    _ -> Error(failure(contracts.NotSent))
  })
  use account <- result.try(
    case
      list.filter(data.private_metadata, fn(pair) {
        pair.0 == "chatgpt_account_id"
      })
    {
      [#(_, account)] ->
        check(oauth.safe_header(account)) |> result.map(fn(_) { account })
      _ -> Error(failure(contracts.NotSent))
    },
  )
  use model <- result.try(models.lookup(catalog, request.model) |> before)
  use _ <- result.try(check(!model.responses_lite))
  use _ <- result.try(json_guard.parse(request.body) |> before)
  let generation = fresh_id()
  let credential_id = crypto.pkce_challenge(data.credential.access_token)
  let scope =
    websocket.Scope(
      tenant,
      "codex",
      credential_id,
      context.account,
      request.model,
      context.session_key,
    )
  use protocol <- result.try(websocket.new(scope, generation) |> before)
  // Validate before connecting. In particular, no receipt survives a reconnect.
  use first <- result.try(
    websocket.create(protocol, scope, generation, request.body) |> before,
  )
  use _ <- result.try(case ir.field(first.1.document, "generate") {
    Some(ir.Boolean(False)) -> Error(failure(contracts.NotSent))
    _ -> Ok(Nil)
  })
  let provider_context =
    codex_request.Context(
      session.Scope(
        tenant,
        credential_id,
        account,
        request.model,
        context.session_key,
      ),
      data.credential.access_token,
      user_agent,
      Some(generation),
    )
  use prepared <- result.try(
    codex_request.prepare(
      first.1.document,
      provider_context,
      routes.Route(routes.Responses, routes.Websocket, True),
      None,
      model.reasoning_efforts,
    )
    |> before,
  )
  use connection <- result.try(
    ws_transport.open(
      context.origin,
      context.origin,
      prepared.target,
      [
        Header("OpenAI-Beta", "responses_websockets=2026-02-06"),
        ..prepared.headers
      ],
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
      provider_context,
      model.reasoning_efforts,
      None,
      prepared,
    ),
  ))
}

fn send(
  handle: Handle,
  request: contracts.Request,
) -> Result(Handle, contracts.Failure) {
  use _ <- result.try(json_guard.parse(request.body) |> after)
  use created <- result.try(
    websocket.create(
      handle.protocol,
      handle.scope,
      handle.generation,
      request.body,
    )
    |> after,
  )
  // generate=false warmup has distinct CPA behavior; don't claim it works by
  // waiting for a terminal that may never arrive.
  use _ <- result.try(case ir.field(created.1.document, "generate") {
    Some(ir.Boolean(False)) -> Error(failure(contracts.Started))
    _ -> Ok(Nil)
  })
  use prepared <- result.try(
    codex_request.prepare(
      created.1.document,
      handle.context,
      routes.Route(routes.Responses, routes.Websocket, True),
      handle.receipt,
      handle.efforts,
    )
    |> after,
  )
  use body <- result.try(responses.request_from_value(prepared.body) |> after)
  use message <- result.try(websocket.encode_create(body) |> after)
  use _ <- result.try(ws_transport.send(handle.connection, message) |> after)
  Ok(Handle(..handle, protocol: created.0, prepared: prepared))
}

fn receive(
  handle: Handle,
) -> Result(#(Option(String), Handle), contracts.Failure) {
  use polled <- result.try(ws_transport.poll(handle.connection) |> after)
  let handle = Handle(..handle, connection: polled.0)
  case polled.1 {
    None -> Ok(#(None, handle))
    Some(message) -> {
      use _ <- result.try(json_guard.parse(message) |> after)
      use received <- result.try(
        websocket.receive(
          handle.protocol,
          handle.scope,
          handle.generation,
          message,
        )
        |> after,
      )
      let event = received.1
      use receipt <- result.try(case event.name {
        "response.completed" -> {
          use response <- result.try(stream.terminal_response(event) |> after)
          use _ <- result.try(case ir.field(response.document, "model") {
            None -> Ok(Nil)
            Some(ir.String(model)) if model == handle.scope.model -> Ok(Nil)
            _ -> Error(failure(contracts.Started))
          })
          use calls <- result.try(responses.output_calls(response) |> after)
          session.completed_ws(
            handle.prepared.identity,
            response.id,
            list.append(handle.prepared.pending_calls, calls),
            handle.generation,
          )
          |> after
          |> result.map(Some)
        }
        "response.failed"
        | "response.incomplete"
        | "response.cancelled"
        | "error" -> Ok(None)
        _ -> Ok(handle.receipt)
      })
      Ok(#(
        Some(message),
        Handle(..handle, protocol: received.0, receipt: receipt),
      ))
    }
  }
}

fn check(valid: Bool) -> Result(Nil, contracts.Failure) {
  case valid {
    True -> Ok(Nil)
    False -> Error(failure(contracts.NotSent))
  }
}

fn failure(delivery: contracts.Delivery) -> contracts.Failure {
  contracts.Failure(contracts.InvalidResponse, delivery, None)
}

fn before(value: Result(a, String)) -> Result(a, contracts.Failure) {
  result.replace_error(value, failure(contracts.NotSent))
}

fn after(value: Result(a, String)) -> Result(a, contracts.Failure) {
  result.replace_error(value, failure(contracts.Started))
}

@external(erlang, "mimic_gateway_ffi", "fresh_id")
fn fresh_id() -> String
