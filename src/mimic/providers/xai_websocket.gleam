/// xAI Responses on a single credential-scoped physical WS/WSS connection.
/// Shared Session owns continuation/pairing; shared transport owns RFC6455/TLS.
/// No reconnect, HTTP fallback, credential transfer or uncertain-send replay.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth/crypto
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket
import mimic/providers/contracts
import mimic/providers/ws_transport
import mimic/providers/xai/endpoint
import mimic/providers/xai/json_guard
import mimic/providers/xai/models
import mimic/providers/xai/operations
import mimic/providers/xai/request as xai_request
import mimic/providers/xai/tools
import mimic/providers/xai_websocket/fence
import mimic/types.{Header}

/// A server-only close capability, never an upstream error body or diagnostic.
/// The root must check it again immediately before publication, then stop.
pub opaque type Terminal {
  Terminal(failure: contracts.Failure, fence: Option(fence.Fence))
}

pub type TerminalAction {
  Close(code: Int)
}

/// Additive callback for runtime.open_session_scoped. Existing SessionAdapter
/// send/receive/cancel remain unchanged; only the acquired-revision open differs.
pub type ScopedOpen =
  fn(contracts.Context, runtime_store.Revision, contracts.Request) ->
    Result(contracts.Opened(Handle), contracts.Failure)

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
    fence: Option(fence.Fence),
    notify: Option(fn(Terminal) -> Nil),
    active: Bool,
  )
}

pub fn adapter(
  tenant: String,
  config: endpoint.Config,
  ca_file: Option(String),
) -> contracts.SessionAdapter(Handle) {
  callbacks(fn(context, request) {
    open(tenant, config, ca_file, None, None, context, request)
  })
}

fn callbacks(open) -> contracts.SessionAdapter(Handle) {
  contracts.SessionAdapter(
    open: open,
    send: send,
    receive: receive,
    cancel: fn(handle) {
      let _ = ws_transport.abort(handle.connection)
      Nil
    },
  )
}

/// Explicit fixed library plan. The selected origin must match it exactly; it
/// cannot supply a missing websocket_base or replace an operator override.
/// Production root consumers use the configured scoped-open pair instead.
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
      use _ <- result.try(explicit_base(config))
      open(tenant, config, ca_file, None, None, context, request)
    },
  )
}

/// Resolve ONLY the actual runtime-selected operation binding. No account
/// origin, request URL, private OAuth metadata or first-account default is a
/// WebSocket destination. One existing credential worker remains authoritative.
pub fn configured_adapter(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
) -> contracts.SessionAdapter(Handle) {
  configured(tenant, bindings, ca_file, store, authorized, None)
}

/// A nonblocking root-owned Subject callback. No callback acknowledgement is
/// awaited, and no shared runtime/SessionAdapter ABI is changed.
pub fn configured_adapter_notifying(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
  notify: fn(Terminal) -> Nil,
) -> contracts.SessionAdapter(Handle) {
  configured(tenant, bindings, ca_file, store, authorized, Some(notify))
}

/// Root uses this callback with runtime.open_session_scoped and the existing
/// configured_adapter for send/receive/cancel. The acquired revision is passed
/// unchanged by runtime; binding a fresh read with equal material is forbidden.
pub fn configured_scoped_open(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
) -> ScopedOpen {
  scoped(tenant, bindings, ca_file, store, authorized, None)
}

pub fn configured_scoped_open_notifying(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
  notify: fn(Terminal) -> Nil,
) -> ScopedOpen {
  scoped(tenant, bindings, ca_file, store, authorized, Some(notify))
}

fn configured(tenant, bindings, ca_file, store, authorized, notify) {
  callbacks(fn(context, request) {
    use config <- result.try(selected_config(bindings, context, request))
    use bound_fence <- result.try(fence.bind(store, context, authorized))
    open(tenant, config, ca_file, Some(bound_fence), notify, context, request)
  })
}

fn scoped(tenant, bindings, ca_file, store, authorized, notify) -> ScopedOpen {
  fn(context, acquired, request) {
    use config <- result.try(selected_config(bindings, context, request))
    use bound_fence <- result.try(fence.bind_acquired(
      store,
      context,
      acquired,
      authorized,
    ))
    open(tenant, config, ca_file, Some(bound_fence), notify, context, request)
  }
}

fn selected_config(
  bindings: List(operations.Binding),
  context: contracts.Context,
  request: contracts.Request,
) -> Result(endpoint.Config, contracts.Failure) {
  use _ <- result.try(check(request.operation == "responses/websocket"))
  use config <- result.try(
    operations.select_configured(bindings, context, request)
    |> result.replace_error(contracts.Failure(
      contracts.Unsupported,
      contracts.NotSent,
      None,
    )),
  )
  use _ <- result.try(explicit_base(config))
  Ok(config)
}

fn explicit_base(config: endpoint.Config) {
  case config.websocket_base {
    None ->
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None))
    Some(_) -> Ok(Nil)
  }
}

/// Close-only xAI policy: no raw upstream error exposure is source-qualified.
/// A stale credential/client fence suppresses publication, not a generic error.
/// This is NOT the Codex error classifier or a claim of effective-chain parity.
pub fn terminal_action(
  terminal: Terminal,
) -> Result(TerminalAction, contracts.Failure) {
  use _ <- result.try(check_fence(terminal.fence))
  Ok(
    Close(case terminal.failure.reason {
      contracts.Unsupported
      | contracts.InvalidConfiguration
      | contracts.CredentialUnavailable
      | contracts.ReauthorizationRequired
      | contracts.NoAccount
      | contracts.Cancelled -> 1008
      _ -> 1011
    }),
  )
}

fn open(
  tenant: String,
  config: endpoint.Config,
  ca_file: Option(String),
  bound_fence: Option(fence.Fence),
  notify: Option(fn(Terminal) -> Nil),
  context: contracts.Context,
  request: contracts.Request,
) -> Result(contracts.Opened(Handle), contracts.Failure) {
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
  use _ <- result.try(check_fence(bound_fence))
  use _ <- result.try(check_request(request, mode, context.account))
  use _ <- result.try(case config.using_api {
    True -> Ok(Nil)
    False ->
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None))
  })
  // Registration and direct adapter admission must agree. In particular,
  // nonempty history/session is not a composer WebSocket capability.
  use registered <- result.try(
    models.registration_for(request.model, config)
    |> result.replace_error(contracts.Failure(
      contracts.Unsupported,
      contracts.NotSent,
      None,
    )),
  )
  use _ <- result.try(
    case
      list.contains(registered.operations, "responses/websocket")
      && list.contains(registered.capabilities, contracts.WebSocket)
    {
      True -> Ok(Nil)
      False ->
        Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None))
    },
  )
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
  let generation = crypto.random_url_token()
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
  case check_fence(bound_fence) {
    Error(error) -> {
      let _ = ws_transport.abort(connection)
      Error(error)
    }
    Ok(_) ->
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
          bound_fence,
          notify,
          False,
        ),
      ))
  }
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
  let attempted = {
    use _ <- result.try(check_fence(handle.fence))
    use _ <- result.try(
      check_request(request, handle.auth_mode, handle.scope.account)
      |> result.replace_error(failure(contracts.Started)),
    )
    use _ <- result.try(
      check(
        request.session == handle.client_session
        && request.model == handle.scope.model
        && request.operation == handle.operation
        && !handle.active,
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
    // A completed receipt does not make queued/partial provider bytes part of
    // the next turn. Use F13's shared physical idle fence, never a second parser.
    use connection <- result.try(
      ws_transport.ensure_idle(handle.connection) |> after,
    )
    use _ <- result.try(check_fence(handle.fence))
    use _ <- result.try(ws_transport.send(connection, prepared.2) |> after)
    use _ <- result.try(check_fence(handle.fence))
    Ok(
      Handle(
        ..handle,
        connection: connection,
        protocol: prepared.0,
        refs: prepared.1,
        active: True,
      ),
    )
  }
  case attempted {
    Ok(next) -> Ok(next)
    Error(error) -> {
      let _ = ws_transport.abort(handle.connection)
      Error(error)
    }
  }
}

fn receive(handle: Handle) {
  case receive_open(handle) {
    Ok(next) -> Ok(next)
    Error(error) -> terminate(handle, error)
  }
}

fn receive_open(handle: Handle) {
  use _ <- result.try(check_fence(handle.fence))
  use polled <- result.try(ws_transport.poll(handle.connection) |> after)
  let handle = Handle(..handle, connection: polled.0)
  use _ <- result.try(check_fence(handle.fence))
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
      use _ <- result.try(validate_event(received.1, handle.scope.model))
      use _ <- result.try(check_fence(handle.fence))
      let restored = xai_request.restore_event(document, handle.refs)
      let outgoing = case restored == document {
        True -> message
        False -> ir.stringify(restored)
      }
      Ok(#(
        Some(outgoing),
        Handle(
          ..handle,
          protocol: received.0,
          active: received.1.name != "response.completed",
        ),
      ))
    }
  }
}

fn validate_event(event: stream.Event, model: String) {
  // Raw shared validation has already happened. Unknown error envelopes or
  // failed/incomplete/cancelled terminals cannot become public error text or a
  // reusable cursor. Preserve only the earlier validated event prefix.
  use _ <- result.try(case event.name {
    "error"
    | "response.failed"
    | "response.incomplete"
    | "response.cancelled" -> Error(failure(contracts.Started))
    _ -> Ok(Nil)
  })
  use _ <- result.try(case has_error(event.document) {
    True -> Error(failure(contracts.Started))
    False -> Ok(Nil)
  })
  case ir.field(event.document, "response") {
    Some(response) ->
      case ir.field(response, "model") {
        None -> Ok(Nil)
        Some(ir.String(actual)) if actual == model -> Ok(Nil)
        _ -> Error(failure(contracts.Started))
      }
    None -> Ok(Nil)
  }
}

fn has_error(document: ir.Value) -> Bool {
  let own = case ir.field(document, "error") {
    None | Some(ir.Null) -> False
    Some(_) -> True
  }
  own
  || case ir.field(document, "response") {
    Some(response) ->
      case ir.field(response, "error") {
        None | Some(ir.Null) -> False
        Some(_) -> True
      }
    None -> False
  }
}

fn terminate(handle: Handle, error: contracts.Failure) {
  let _ = ws_transport.abort(handle.connection)
  // No next Handle/Session/receipt is returned. Runtime Error cleanup attempts
  // cancel/release independently of notification; direct callers MUST discard
  // the immutable handle on Error. Abort Ok is not physical-close evidence.
  case handle.notify {
    Some(notify) -> {
      notify(Terminal(error, handle.fence))
      Error(contracts.Failure(contracts.Cancelled, contracts.Started, None))
    }
    None -> Error(error)
  }
}

fn check_fence(bound_fence: Option(fence.Fence)) {
  case bound_fence {
    None -> Ok(Nil)
    Some(bound_fence) -> fence.check(bound_fence)
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
