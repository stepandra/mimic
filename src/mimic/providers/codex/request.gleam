import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses
import mimic/ir
import mimic/providers/codex/lite
import mimic/providers/codex/normalize
import mimic/providers/codex/oauth
import mimic/providers/codex/routes
import mimic/providers/codex/session
import mimic/types.{type Header, Header}

pub type Context {
  Context(
    scope: session.Scope,
    access_token: String,
    user_agent: String,
    connection_generation: Option(String),
  )
}

/// Selected-provider policy, not a caller marker. The low-level constructor
/// stays strict; selected HTTP/WS adapters qualify NativeLite against a catalog.
pub type ResponseMode {
  StrictResponses
  NativeLiteResponses
}

/// Ephemeral outbound request. Authorization/body must NOT enter the corpus.
/// Caller uses configured origin; this adapter never selects a live endpoint.
pub type Prepared {
  Prepared(
    target: String,
    headers: List(Header),
    body: ir.Value,
    identity: session.Identity,
    credential_id: String,
    pending_calls: List(responses.PendingCall),
    response_mode: ResponseMode,
  )
}

pub fn prepare(
  body: ir.Value,
  context: Context,
  route: routes.Route,
  continuation: Option(session.Continuation),
  reasoning_efforts: List(String),
) -> Result(Prepared, String) {
  prepare_mode(
    body,
    context,
    route,
    continuation,
    reasoning_efforts,
    StrictResponses,
    False,
  )
}

/// Additive F13 seam for the selected WS adapter, not raw client admission.
/// response_mode must already be catalog-qualified. A metadata marker stays
/// in the frame; only a handshake marker adds the upstream Lite header, as in
/// the pinned native WS fixture. Existing prepare/HTTP behavior stays strict.
pub fn prepare_websocket(
  body: ir.Value,
  context: Context,
  continuation: Option(session.Continuation),
  reasoning_efforts: List(String),
  response_mode: ResponseMode,
  header_lite: Bool,
) -> Result(Prepared, String) {
  prepare_mode(
    body,
    context,
    routes.Route(routes.Responses, routes.Websocket, True),
    continuation,
    reasoning_efforts,
    response_mode,
    header_lite,
  )
}

fn prepare_mode(
  body: ir.Value,
  context: Context,
  route: routes.Route,
  continuation: Option(session.Continuation),
  reasoning_efforts: List(String),
  response_mode: ResponseMode,
  header_lite: Bool,
) -> Result(Prepared, String) {
  use decoded <- result.try(responses.request_from_value(body))
  use marked_lite <- result.try(lite.enabled(body))
  let is_lite =
    marked_lite
    || route.operation == routes.Lite
    || response_mode == NativeLiteResponses
  use _ <- result.try(
    case is_lite, route.operation, route.transport, response_mode {
      True, routes.Compact, _, _ -> Error("Codex compact is not Responses-lite")
      True, _, routes.Websocket, StrictResponses ->
        Error("Codex Responses-lite WebSocket requires separate support")
      _, _, _, _ -> Ok(Nil)
    },
  )
  use _ <- result.try(case route.transport, ir.field(body, "generate") {
    routes.Websocket, Some(value) ->
      ir.as_bool(value) |> result.map(fn(_) { Nil })
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case ir.field(body, "context_management") {
    None | Some(ir.Null) -> Ok(Nil)
    _ ->
      Error(
        "Codex context_management is unsupported; use the separate compact operation",
      )
  })
  let model = decoded.model
  use _ <- result.try(
    case
      model == context.scope.model
      && oauth.safe_header(model)
      && oauth.safe_header(context.access_token)
      && oauth.safe_header(context.scope.account_id)
      && oauth.safe_header(context.user_agent)
    {
      True -> Ok(Nil)
      False -> Error("invalid Codex request identity or header")
    },
  )
  use target <- result.try(case route.operation, route.transport {
    routes.Responses, _ -> Ok("/backend-api/codex/responses")
    routes.Lite, routes.Http -> Ok("/backend-api/codex/responses")
    routes.Compact, routes.Http -> Ok("/backend-api/codex/responses/compact")
    _, _ -> Error("Codex operation is unsupported on this transport")
  })
  use identity <- result.try(session.identity(context.scope))
  use source <- result.try(ir.required(body, "input"))
  use items <- result.try(normalize.input(source))
  use _ <- result.try(
    case
      route.transport == routes.Http
      && list.any(items, fn(item) {
        ir.field(item, "type") == Some(ir.String("item_reference"))
      })
    {
      True -> Error("Codex HTTP requires complete items, not item references")
      False -> Ok(Nil)
    },
  )
  let previous = decoded.previous_response_id
  use history <- result.try(continue_input(
    items,
    previous,
    route.transport,
    identity,
    continuation,
    context.connection_generation,
  ))
  use _ <- result.try(normalize.reasoning(body, reasoning_efforts))
  use body <- result.try(normalize.tools(body))
  let body =
    body
    |> normalize.put("input", ir.Array(history.0))
    |> normalize.put("store", ir.Boolean(False))
    |> normalize.put("prompt_cache_key", ir.String(identity.cache_id))
    |> normalize.remove([
      "user", "context_management", "max_output_tokens", "max_completion_tokens",
      "temperature", "top_p", "truncation", "prompt_cache_options",
      "prompt_cache_retention", "safety_identifier", "stream_options",
    ])
  let body = case route.native || is_lite, ir.field(body, "instructions") {
    False, None | False, Some(ir.Null) ->
      normalize.put(body, "instructions", ir.String(""))
    _, _ -> body
  }
  let body = case route.transport {
    routes.Http ->
      normalize.remove(body, ["previous_response_id", "type", "generate"])
    routes.Websocket -> body
  }
  let body = case route.operation {
    routes.Compact -> normalize.remove(body, ["stream"])
    _ -> normalize.put(body, "stream", ir.Boolean(True))
  }
  // Keep caller-requested include data in addition to required encrypted reasoning.
  use include <- result.try(case ir.field(body, "include") {
    None -> Ok([])
    Some(ir.Array(values)) -> list.try_map(values, ir.as_string)
    _ -> Error("Codex include must be an array of strings")
  })
  let body =
    normalize.put(
      body,
      "include",
      ir.Array(
        list.unique(list.append(include, ["reasoning.encrypted_content"]))
        |> list.map(ir.String),
      ),
    )
  let body = case ir.field(body, "tools") {
    Some(ir.Array([_, ..])) ->
      case ir.field(body, "parallel_tool_calls") {
        None -> normalize.put(body, "parallel_tool_calls", ir.Boolean(True))
        _ -> body
      }
    _ -> normalize.remove(body, ["parallel_tool_calls"])
  }
  use body <- result.try(case is_lite {
    True -> lite.normalize(body)
    False -> Ok(body)
  })
  use body <- result.try(service_tier(body))
  use decoded <- result.try(case route.operation {
    routes.Compact -> responses.decode_compact_request(ir.stringify(body))
    _ -> responses.request_from_value(body)
  })
  use pending <- result.try(responses.pair_input(decoded, history.1))
  let accept = case route.operation {
    routes.Compact -> "application/json"
    _ -> "text/event-stream"
  }
  let hint =
    "model="
    <> model
    <> case ir.field(body, "service_tier") {
      Some(ir.String(tier)) -> ";tier=" <> tier
      _ -> ""
    }
  // Deliberately construct, rather than merge, security/identity headers.
  // No client Authorization, Chatgpt-Account-Id or raw Session-Id is forwarded.
  Ok(Prepared(
    target,
    [
      Header("Authorization", "Bearer " <> context.access_token),
      Header("Chatgpt-Account-Id", context.scope.account_id),
      Header("Content-Type", "application/json"),
      Header("Accept", accept),
      Header("User-Agent", context.user_agent),
      Header("Originator", "codex_cli_rs"),
      Header("Session-Id", identity.session_id),
      Header("X-Codex-Routing-Hint", hint),
    ]
      |> fn(headers) {
        case is_lite && { route.transport == routes.Http || header_lite } {
          True -> [
            Header("X-OpenAI-Internal-Codex-Responses-Lite", "true"),
            ..headers
          ]
          False -> headers
        }
      },
    body,
    identity,
    context.scope.credential_id,
    pending,
    response_mode,
  ))
}

fn continue_input(
  items: List(ir.Value),
  previous: Option(String),
  transport: routes.Transport,
  identity: session.Identity,
  continuation: Option(session.Continuation),
  generation: Option(String),
) -> Result(#(List(ir.Value), List(responses.PendingCall)), String) {
  case previous {
    None -> Ok(#(items, []))
    Some(id) -> {
      use pending <- result.try(session.validate(continuation, identity, id))
      case transport, continuation {
        routes.Websocket, _ -> {
          use _ <- result.try(session.validate_connection(
            continuation,
            generation,
          ))
          Ok(#(items, pending))
        }
        routes.Http, Some(receipt) -> {
          use history <- result.try(session.replay(receipt))
          Ok(#(list.append(history, items), []))
        }
        _, _ -> Error("Codex continuation unavailable")
      }
    }
  }
}

fn service_tier(body: ir.Value) -> Result(ir.Value, String) {
  case ir.field(body, "service_tier") {
    None -> Ok(body)
    Some(ir.String(tier)) ->
      case string.lowercase(string.trim(tier)) {
        "fast" | "priority" ->
          Ok(normalize.put(body, "service_tier", ir.String("priority")))
        "ultrafast" ->
          Ok(normalize.put(body, "service_tier", ir.String("ultrafast")))
        // Do not silently discard a requested billing/latency policy.
        _ -> Error("unsupported Codex service tier")
      }
    _ -> Error("invalid Codex service tier")
  }
}
