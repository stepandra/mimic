/// Codex OAuth Responses over one credential-scoped physical connection.
/// No HTTP fallback, transcript repair, reconnect or uncertain-send replay.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/auth/crypto
import mimic/auth/storage
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/sparse
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket
import mimic/providers/codex/json_guard
import mimic/providers/codex/lite
import mimic/providers/codex/models
import mimic/providers/codex/oauth
import mimic/providers/codex/request as codex_request
import mimic/providers/codex/session
import mimic/providers/codex_websocket/errors
import mimic/providers/codex_websocket/fence
import mimic/providers/contracts
import mimic/providers/ws_transport
import mimic/types.{Header}

type Admission {
  Compatibility(notify: Option(fn(Terminal) -> Nil))
  Native(
    store: storage.Store,
    header_lite: Bool,
    authorized: fn() -> Bool,
    notify: Option(fn(Terminal) -> Nil),
  )
}

/// Created only from a codec-validated, classified non-duplex terminal error.
/// Root must call terminal_action immediately before publication; the selected
/// revision/client fence remains part of this private capability.
pub opaque type Terminal {
  Terminal(action: errors.Action, fence: Option(fence.Fence))
}

pub fn terminal_action(
  terminal: Terminal,
) -> Result(errors.Action, contracts.Failure) {
  use _ <- result.try(check_fence(terminal.fence))
  Ok(terminal.action)
}

pub opaque type Handle {
  Handle(
    connection: ws_transport.Connection,
    protocol: websocket.Session,
    scope: websocket.Scope,
    generation: String,
    context: codex_request.Context,
    efforts: List(String),
    modalities: List(String),
    header_lite: Bool,
    fence: Option(fence.Fence),
    active: Bool,
    closed: Bool,
    notify: Option(fn(Terminal) -> Nil),
    redactions: List(String),
    binding: contracts.Request,
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
  compatibility(tenant, catalog, user_agent, ca_file, None)
}

/// Compatibility root error projection uses the same typed terminal channel.
/// The plain low-level adapter stays strict/fail-closed, not a public gateway
/// error projection owner. No store or additional credential owner is created.
pub fn adapter_notifying(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  notify: fn(Terminal) -> Nil,
) -> contracts.SessionAdapter(Handle) {
  compatibility(tenant, catalog, user_agent, ca_file, Some(notify))
}

fn compatibility(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  notify: Option(fn(Terminal) -> Nil),
) -> contracts.SessionAdapter(Handle) {
  contracts.SessionAdapter(
    open: fn(context, request) {
      open(
        tenant,
        catalog,
        user_agent,
        ca_file,
        Compatibility(notify),
        context,
        request,
      )
    },
    send: send,
    receive: receive,
    cancel: abort_handle,
  )
}

/// Root opt-in consumer. The Bool is validated handshake intent, never catalog
/// authority. Context is runtime-selected; the store/client check are trusted
/// server capabilities. Existing adapter stays compatibility/default-strict.
pub fn native_adapter(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  header_lite: Bool,
  store: storage.Store,
  authorized: fn() -> Bool,
) -> contracts.SessionAdapter(Handle) {
  native(
    tenant,
    catalog,
    user_agent,
    ca_file,
    header_lite,
    store,
    authorized,
    None,
  )
}

/// Typed one-shot close notification for the root actor. Notifications are not
/// ordinary wire events or magic error strings. The root publishes at most once
/// after terminal_action's fence, then closes; this Handle is already closed.
pub fn native_adapter_notifying(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  header_lite: Bool,
  store: storage.Store,
  authorized: fn() -> Bool,
  notify: fn(Terminal) -> Nil,
) -> contracts.SessionAdapter(Handle) {
  native(
    tenant,
    catalog,
    user_agent,
    ca_file,
    header_lite,
    store,
    authorized,
    Some(notify),
  )
}

fn native(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  header_lite: Bool,
  store: storage.Store,
  authorized: fn() -> Bool,
  notify: Option(fn(Terminal) -> Nil),
) -> contracts.SessionAdapter(Handle) {
  contracts.SessionAdapter(
    open: fn(context, request) {
      open(
        tenant,
        catalog,
        user_agent,
        ca_file,
        Native(store, header_lite, authorized, notify),
        context,
        request,
      )
    },
    send: send,
    receive: receive,
    cancel: abort_handle,
  )
}

fn abort_handle(handle: Handle) -> Nil {
  let _ = ws_transport.abort(handle.connection)
  Nil
}

/// Selected-plan policy. Public WS forwarding preserves native completion
/// output (unlike public HTTP's hydration); F11 owns observation/reconstruction.
pub fn policy(mode: codex_request.ResponseMode) -> stream.Policy {
  case mode {
    codex_request.StrictResponses -> stream.Strict
    codex_request.NativeLiteResponses ->
      stream.NativeSparse(sparse.Transparent, 8_388_608, 32_768)
  }
}

fn open(
  tenant: String,
  catalog: models.Catalog,
  user_agent: String,
  ca_file: Option(String),
  admission: Admission,
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
    && request.mode == contracts.Streaming
    && context.origin != ""
    && context.session_key != ""
    && case request.pinned_account {
      None -> True
      Some(account) -> account == context.account
    }
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
  use document <- result.try(json_guard.parse(request.body) |> before)
  let header_lite = case admission {
    Compatibility(_) -> False
    Native(_, intent, _, _) -> intent
  }
  use mode <- result.try(intent(document, header_lite) |> before)
  use _ <- result.try(case admission, mode, model.responses_lite {
    Compatibility(_), codex_request.StrictResponses, False -> Ok(Nil)
    Native(_, _, _, _), codex_request.StrictResponses, _ -> Ok(Nil)
    Native(_, _, _, _), codex_request.NativeLiteResponses, True -> Ok(Nil)
    _, _, _ -> Error(unsupported(contracts.NotSent))
  })
  use _ <- result.try(
    lite.validate_modalities(document, model.input_modalities) |> before,
  )
  use bound_fence <- result.try(case admission {
    Compatibility(_) -> Ok(None)
    Native(store, _, authorized, _) ->
      fence.bind(store, context, authorized) |> result.map(Some)
  })
  // This random generation is created for this open only. Never retain/reuse it
  // on transport replacement; reconnect and HTTP replay do not exist here.
  let generation = crypto.random_url_token()
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
  use protocol <- result.try(
    websocket.new_with_policy(scope, generation, policy(mode)) |> before,
  )
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
    codex_request.prepare_websocket(
      first.1.document,
      provider_context,
      None,
      model.reasoning_efforts,
      mode,
      header_lite,
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
  case check_fence(bound_fence) {
    Error(error) -> {
      case ws_transport.abort(connection) {
        Ok(_) -> Error(error)
        Error(_) -> Error(failure(contracts.Uncertain))
      }
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
          provider_context,
          model.reasoning_efforts,
          model.input_modalities,
          header_lite,
          bound_fence,
          False,
          False,
          case admission {
            Compatibility(notify) -> notify
            Native(_, _, _, notify) -> notify
          },
          [data.credential.access_token, data.credential.refresh_token],
          contracts.Request(..request, body: ""),
          None,
          prepared,
        ),
      ))
  }
}

fn send(
  handle: Handle,
  request: contracts.Request,
) -> Result(Handle, contracts.Failure) {
  close_on_error(handle, send_checked(handle, request))
}

fn send_checked(
  handle: Handle,
  request: contracts.Request,
) -> Result(Handle, contracts.Failure) {
  use _ <- result.try(check_open(handle))
  use _ <- result.try(check_fence(handle.fence))
  use handle <- result.try(case handle.active {
    True -> Error(failure(contracts.Started))
    False -> {
      // Inspect already queued socket data before starting another turn. A
      // terminal followed by unsolicited/malformed data cannot authorize a
      // continuation merely because the client create won the gateway tick.
      use connection <- result.try(
        ws_transport.ensure_idle(handle.connection) |> after,
      )
      use _ <- result.try(check_fence(handle.fence))
      Ok(Handle(..handle, connection: connection))
    }
  })
  use _ <- result.try(
    case same_binding(handle.binding, request, handle.scope.account) {
      True -> Ok(Nil)
      False -> Error(unsupported(contracts.Started))
    },
  )
  use document <- result.try(json_guard.parse(request.body) |> after)
  use mode <- result.try(intent(document, handle.header_lite) |> after)
  // The pin uses the current frame, not inherited metadata. Header=true is
  // socket-wide intent; without it each native frame must carry its own marker.
  // No strict/lite policy switch can broaden this physical socket's authority.
  use _ <- result.try(case mode == handle.prepared.response_mode {
    True -> Ok(Nil)
    False -> Error(unsupported(contracts.Started))
  })
  use _ <- result.try(
    lite.validate_modalities(document, handle.modalities) |> after,
  )
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
    codex_request.prepare_websocket(
      created.1.document,
      handle.context,
      handle.receipt,
      handle.efforts,
      mode,
      handle.header_lite,
    )
    |> after,
  )
  use body <- result.try(responses.request_from_value(prepared.body) |> after)
  use message <- result.try(websocket.encode_create(body) |> after)
  use _ <- result.try(check_fence(handle.fence))
  use _ <- result.try(ws_transport.send(handle.connection, message) |> after)
  use _ <- result.try(check_fence(handle.fence))
  Ok(
    Handle(
      ..handle,
      protocol: created.0,
      active: True,
      receipt: None,
      prepared: prepared,
    ),
  )
}

fn receive(
  handle: Handle,
) -> Result(#(Option(String), Handle), contracts.Failure) {
  close_on_error(handle, receive_checked(handle))
}

fn receive_checked(
  handle: Handle,
) -> Result(#(Option(String), Handle), contracts.Failure) {
  use _ <- result.try(check_open(handle))
  use _ <- result.try(check_fence(handle.fence))
  use polled <- result.try(ws_transport.poll(handle.connection) |> after)
  let handle = Handle(..handle, connection: polled.0)
  // A credential/client mutation while poll blocks must suppress even valid
  // terminal data. Poll's None is idle, not permission to skip this recheck.
  use _ <- result.try(check_fence(handle.fence))
  case polled.1 {
    None -> Ok(#(None, handle))
    Some(message) -> {
      use document <- result.try(json_guard.parse(message) |> after)
      use _ <- result.try(check_model(document, handle.scope.model) |> after)
      use received <- result.try(
        websocket.receive_wire(
          handle.protocol,
          handle.scope,
          handle.generation,
          message,
        )
        |> after,
      )
      let event = stream.wire_event(received.1)
      case event.name {
        "error" -> finish_error(handle, received.0, received.1)
        _ -> receive_event(handle, received.0, received.1)
      }
    }
  }
}

fn receive_event(
  handle: Handle,
  protocol: websocket.Session,
  wire: stream.WireEvent,
) -> Result(#(Option(String), Handle), contracts.Failure) {
  let event = stream.wire_event(wire)
  use receipt <- result.try(case event.name {
    "response.completed" -> {
      use response <- result.try(eligible(wire, handle.prepared.response_mode))
      case response {
        None -> Ok(None)
        Some(response) -> {
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
      }
    }
    "response.failed" | "response.incomplete" | "response.cancelled" -> Ok(None)
    _ -> Ok(handle.receipt)
  })
  // The report grants protocol evidence only. Publish privately to this
  // same physical Handle only after the current selected revision/client
  // fence; any later error closes and discards both codec/provider receipts.
  use _ <- result.try(check_fence(handle.fence))
  Ok(#(
    Some(stream.wire_data(wire)),
    Handle(
      ..handle,
      protocol: protocol,
      active: case event.name {
        "response.completed"
        | "response.failed"
        | "response.incomplete"
        | "response.cancelled"
        | "error" -> False
        _ -> True
      },
      receipt: receipt,
    ),
  ))
}

fn finish_error(
  handle: Handle,
  protocol: websocket.Session,
  wire: stream.WireEvent,
) -> Result(#(Option(String), Handle), contracts.Failure) {
  let continuing = case ir.field(handle.prepared.body, "previous_response_id") {
    Some(ir.String(_)) -> True
    _ -> False
  }
  let action =
    errors.classify(
      stream.wire_event(wire).document,
      stream.wire_data(wire),
      continuing,
      handle.redactions,
    )
  // No recoverable non-duplex error. Clear every cursor and permanently close
  // the handle before the callback. An absent callback never returns idle for
  // suppressed errors, so low-level consumers cannot keep a reusable lease.
  let closed =
    Handle(
      ..handle,
      protocol: websocket.cancel(protocol).0,
      active: False,
      closed: True,
      receipt: None,
    )
  use _ <- result.try(ws_transport.abort(closed.connection) |> after)
  use _ <- result.try(check_fence(closed.fence))
  case closed.notify {
    Some(notify) -> {
      notify(Terminal(action, closed.fence))
      Ok(#(None, closed))
    }
    None ->
      case action {
        errors.RequestFault(data) -> Ok(#(Some(data), closed))
        _ ->
          Error(contracts.Failure(contracts.Cancelled, contracts.Started, None))
      }
  }
}

fn check_open(handle: Handle) -> Result(Nil, contracts.Failure) {
  case handle.closed {
    True ->
      Error(contracts.Failure(contracts.Cancelled, contracts.Started, None))
    False -> Ok(Nil)
  }
}

fn eligible(
  wire: stream.WireEvent,
  mode: codex_request.ResponseMode,
) -> Result(Option(responses.Response), contracts.Failure) {
  case mode {
    codex_request.StrictResponses ->
      stream.terminal_response(stream.wire_event(wire))
      |> after
      |> result.map(Some)
    codex_request.NativeLiteResponses ->
      case stream.wire_report(wire) {
        None -> Error(failure(contracts.Started))
        Some(report) ->
          case sparse.authority(report) {
            sparse.ContinuationEligible(response) -> Ok(Some(response))
            sparse.Ineligible(_) -> Ok(None)
          }
      }
  }
}

fn intent(
  document: ir.Value,
  header_lite: Bool,
) -> Result(codex_request.ResponseMode, String) {
  use body_lite <- result.try(lite.enabled(document))
  Ok(case header_lite || body_lite {
    True -> codex_request.NativeLiteResponses
    False -> codex_request.StrictResponses
  })
}

fn check_model(document: ir.Value, model: String) -> Result(Nil, String) {
  case ir.field(document, "response") {
    None -> Ok(Nil)
    Some(response) ->
      case ir.field(response, "model") {
        None -> Ok(Nil)
        Some(ir.String(value)) if value == model -> Ok(Nil)
        _ -> Error("Codex WS response model differs from selected scope")
      }
  }
}

fn same_binding(
  first: contracts.Request,
  next: contracts.Request,
  selected_account: String,
) -> Bool {
  first.provider == next.provider
  && first.auth_mode == next.auth_mode
  && first.model == next.model
  && first.protocol == next.protocol
  && first.operation == next.operation
  && first.mode == next.mode
  && first.session == next.session
  && list.contains(next.required, contracts.WebSocket)
  && case next.pinned_account {
    None -> True
    Some(account) -> account == selected_account
  }
}

fn check_fence(bound: Option(fence.Fence)) -> Result(Nil, contracts.Failure) {
  case bound {
    None -> Ok(Nil)
    Some(bound) -> fence.check(bound)
  }
}

fn close_on_error(
  handle: Handle,
  value: Result(a, contracts.Failure),
) -> Result(a, contracts.Failure) {
  case value {
    Ok(_) -> value
    Error(_) -> {
      case ws_transport.abort(handle.connection) {
        Ok(_) -> value
        Error(_) -> Error(failure(contracts.Started))
      }
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

fn unsupported(delivery: contracts.Delivery) -> contracts.Failure {
  contracts.Failure(contracts.Unsupported, delivery, None)
}

fn before(value: Result(a, String)) -> Result(a, contracts.Failure) {
  result.replace_error(value, failure(contracts.NotSent))
}

fn after(value: Result(a, String)) -> Result(a, contracts.Failure) {
  result.replace_error(value, failure(contracts.Started))
}
