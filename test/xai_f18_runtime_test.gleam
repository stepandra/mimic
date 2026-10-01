/// Synthetic actual xAI adapter/runtime sockets, not native/live/CPA evidence.
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/xai/operations
import mimic/providers/xai_websocket as xai
import mist
import xai_websocket_native_test as native

type Switch

type AcceptProbe

@external(erlang, "mimic_xai_f18_test_ffi", "start_accept_probe")
fn start_accept_probe() -> Result(#(AcceptProbe, Int), String)

@external(erlang, "mimic_xai_f18_test_ffi", "accept_count")
fn accept_count(probe: AcceptProbe) -> Int

@external(erlang, "mimic_xai_f18_test_ffi", "stop_accept_probe")
fn stop_accept_probe(probe: AcceptProbe) -> Result(Nil, String)

@external(erlang, "mimic_xai_f18_test_ffi", "new_switch")
fn new_switch() -> Switch

@external(erlang, "mimic_xai_f18_test_ffi", "allowed")
fn allowed(switch: Switch) -> Bool

@external(erlang, "mimic_xai_f18_test_ffi", "revoke")
fn revoke(switch: Switch) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

const create = "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"input\":[],\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"function\",\"name\":\"run\"}]}]}"

const follow = "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"previous_response_id\":\"resp_synthetic_0\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_synthetic\",\"output\":\"synthetic-result\"}]}"

const reset = "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"input\":[]}"

fn material(mode: String) {
  case mode {
    "api_key" -> c.ApiKey("synthetic-f18-access")
    _ ->
      c.OAuth(
        c.OAuthData(
          auth.Credential(
            "synthetic-f18-access",
            "synthetic-f18-refresh",
            9_000_000_000_000,
          ),
          [#("token_endpoint", "https://auth.x.ai/synthetic-token")],
        ),
      )
  }
}

fn setup(origin: String, mode: String) {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("xai", mode, "selected")
  runtime_store.save(store, key, material(mode)) |> should.be_ok
  let assert Ok(binding) =
    operations.new(
      "selected",
      mode,
      "responses",
      "responses/websocket",
      origin <> "/v1",
      True,
    )
  let assert Ok(absent) =
    operations.new(
      "absent",
      mode,
      "responses",
      "responses/websocket",
      "http://127.0.0.1:1/v1",
      True,
    )
  let assert Ok(row) =
    operations.registration("selected", mode, [binding], "grok-4.7")
  let assert Ok(catalog) = registry.new([row])
  let policy = case mode {
    "api_key" -> credentials.StaticKey
    _ ->
      credentials.Refreshable(
        c.Refresh(fn(_, _) { panic as "fresh synthetic grant must not refresh" }),
      )
  }
  let assert Ok(pool) =
    runtime.start_with_bindings(
      store,
      catalog,
      [
        runtime.Account(
          "xai",
          mode,
          "absent",
          "http://127.0.0.1:1",
          fleet.LocalLoopback,
          1,
          ["grok-4.7"],
          policy,
        ),
        runtime.Account(
          "xai",
          mode,
          "selected",
          origin,
          fleet.LocalLoopback,
          1,
          ["grok-4.7"],
          policy,
        ),
      ],
      operations.runtime_bindings([absent, binding]),
    )
  #(store, key, [absent, binding], pool)
}

fn terminal(session: runtime.Session, attempts: Int) -> ir.Value {
  let assert Ok(message) = runtime.session_poll(session)
  case message, attempts {
    Some(message), n if n > 0 -> {
      let assert Ok(event) = ir.parse(message)
      case ir.string_field(event, "type") {
        Ok("response.completed") -> event
        _ -> terminal(session, n - 1)
      }
    }
    None, n if n > 0 -> terminal(session, n - 1)
    _, _ -> panic as "synthetic terminal deadline"
  }
}

fn cleanup(pool: runtime.Runtime, server: process.Pid) {
  runtime.stop(pool) |> should.be_ok
  process.unlink(server)
  process.send_exit(server)
}

pub fn explicit_api_key_and_oauth_runtime_same_socket_tools_continuation_reset_test() {
  list.each(["api_key", "oauth"], fn(mode) {
    let #(server, origin, observed, closed) = native.peer(None, "normal")
    let #(store, _, bindings, pool) = setup(origin, mode)
    let adapter =
      xai.configured_adapter("synthetic-tenant", bindings, None, store, fn() {
        True
      })
    let request = native.req(mode, create)
    let assert Ok(session) = runtime.open_session(pool, adapter, request)
    runtime.session_account(session) |> should.equal("selected")
    runtime.session_send(session, request) |> should.be_ok
    let done = terminal(session, 100)
    let assert Some(response) = ir.field(done, "response")
    let assert Some(ir.Array([call])) = ir.field(response, "output")
    ir.string_field(call, "name") |> should.equal(Ok("run"))
    ir.string_field(call, "namespace") |> should.equal(Ok("shell"))
    let assert Some(usage) = ir.field(response, "usage")
    ir.field(usage, "total_tokens") |> should.equal(Some(ir.Integer(5)))
    runtime.session_send(session, native.req(mode, follow)) |> should.be_ok
    let _ = terminal(session, 100)
    runtime.session_send(session, native.req(mode, reset)) |> should.be_ok
    let _ = terminal(session, 100)
    // Only one handshake (authorization/path), followed by three creates.
    list.each([0, 1, 2, 3, 4], fn(_) {
      process.receive(observed, 1000) |> should.be_ok
    })
    process.receive(observed, 20) |> should.be_error
    runtime.session_cancel(session)
    process.receive(closed, 1000) |> should.be_ok
    runtime.active_leases(pool) |> should.equal(Ok(0))
    // A new generation cannot consume the previous physical socket receipt.
    runtime.open_session(pool, adapter, native.req(mode, follow))
    |> should.be_error
    process.receive(observed, 20) |> should.be_error
    cleanup(pool, server.pid)
  })
}

pub fn idle_poll_detects_provider_revision_or_current_client_revocation_test() {
  list.each(["same-value", "rotate", "delete", "client"], fn(mutation) {
    let #(server, origin, _, closed) = native.peer(None, "normal")
    let #(store, key, bindings, pool) = setup(origin, "api_key")
    let switch = new_switch()
    let adapter =
      xai.configured_adapter("synthetic-tenant", bindings, None, store, fn() {
        allowed(switch)
      })
    let request = native.req("api_key", create)
    let assert Ok(session) = runtime.open_session(pool, adapter, request)
    runtime.session_send(session, request) |> should.be_ok
    let _ = terminal(session, 100)
    case mutation {
      "same-value" ->
        runtime_store.save(store, key, material("api_key")) |> should.be_ok
      "rotate" ->
        runtime_store.save(store, key, c.ApiKey("synthetic-rotated"))
        |> should.be_ok
      "delete" -> runtime_store.delete(store, key) |> should.be_ok
      _ -> revoke(switch)
    }
    runtime.session_poll(session) |> should.be_error
    process.receive(closed, 1000) |> should.be_ok
    runtime.active_leases(pool) |> should.equal(Ok(0))
    runtime.session_send(session, native.req("api_key", follow))
    |> should.be_error
    cleanup(pool, server.pid)
  })
}

fn failure_peer(kind: String) {
  let started = process.new_subject()
  let closed = process.new_subject()
  let creates = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(req) {
      mist.websocket(
        req,
        fn(state, message, connection) {
          case message {
            mist.Text(_) -> {
              process.send(creates, Nil)
              let assert Ok(_) =
                mist.send_text_frame(
                  connection,
                  "{\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_failure\",\"status\":\"in_progress\",\"output\":[]}}",
                )
              let terminal = case kind {
                "malformed" ->
                  "{\"type\":\"response.completed\",\"type\":\"error\"}"
                "error" ->
                  "{\"type\":\"error\",\"error\":{\"message\":\"synthetic-f18-access must never be published\"}}"
                _ ->
                  "{\"type\":\"response."
                  <> kind
                  <> "\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_failure\",\"status\":\""
                  <> kind
                  <> "\",\"output\":[],\"error\":{\"message\":\"synthetic-f18-access must never be published\"}}}"
              }
              let assert Ok(_) = mist.send_text_frame(connection, terminal)
              mist.continue(state)
            }
            _ -> mist.continue(state)
          }
        },
        fn(_) { #(Nil, None) },
        fn(_) { process.send(closed, Nil) },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
    |> mist.start
  let assert Ok(port) = process.receive(started, 5000)
  #(server, "http://127.0.0.1:" <> int.to_string(port), closed, creates)
}

fn runtime_failure(session: runtime.Session, attempts: Int) -> c.Failure {
  case runtime.session_poll(session), attempts {
    Ok(None), n if n > 0 -> runtime_failure(session, n - 1)
    Error(error), _ -> error
    _, _ -> panic as "runtime terminal path returned raw provider data or idled"
  }
}

fn runtime_message(session: runtime.Session, attempts: Int) -> String {
  case runtime.session_poll(session), attempts {
    Ok(Some(message)), _ -> message
    Ok(None), n if n > 0 -> runtime_message(session, n - 1)
    _, _ -> panic as "synthetic runtime prefix deadline"
  }
}

pub fn malformed_and_non_success_terminals_notify_once_then_runtime_cancels_and_releases_test() {
  list.each(
    ["malformed", "error", "failed", "incomplete", "cancelled"],
    fn(kind) {
      let #(server, origin, closed, creates) = failure_peer(kind)
      let #(store, key, bindings, pool) = setup(origin, "api_key")
      let terminals = process.new_subject()
      let adapter =
        xai.configured_adapter_notifying(
          "synthetic-tenant",
          bindings,
          None,
          store,
          fn() { True },
          fn(terminal) { process.send(terminals, terminal) },
        )
      let request = native.req("api_key", reset)
      let assert Ok(session) = runtime.open_session(pool, adapter, request)
      runtime.session_send(session, request) |> should.be_ok
      runtime.active_leases(pool) |> should.equal(Ok(1))
      let prefix = runtime_message(session, 100)
      let assert Ok(prefix) = ir.parse(prefix)
      ir.string_field(prefix, "type") |> should.equal(Ok("response.created"))
      runtime_failure(session, 100)
      |> should.equal(c.Failure(c.Cancelled, c.Started, None))
      // Callback and runtime replies have different senders. Wait for the
      // terminal capability rather than infer delivery order from the Error.
      let assert Ok(terminal) = process.receive(terminals, 1000)
      xai.terminal_action(terminal) |> should.equal(Ok(xai.Close(1011)))
      runtime.active_leases(pool) |> should.equal(Ok(0))
      runtime.session_poll(session) |> should.be_error
      runtime.session_send(session, request) |> should.be_error
      process.receive(terminals, 20) |> should.be_error
      process.receive(creates, 1000) |> should.be_ok
      process.receive(creates, 20) |> should.be_error
      process.receive(closed, 1000) |> should.be_ok
      // Publication uses the captured revision, not whichever grant exists now.
      runtime_store.save(store, key, material("api_key")) |> should.be_ok
      xai.terminal_action(terminal) |> should.be_error
      cleanup(pool, server.pid)
    },
  )
}

fn next(
  adapter: c.SessionAdapter(xai.Handle),
  handle: xai.Handle,
  attempts: Int,
) -> #(String, xai.Handle) {
  let assert Ok(#(message, handle)) = adapter.receive(handle)
  case message, attempts {
    Some(message), _ -> #(message, handle)
    None, n if n > 0 -> next(adapter, handle, n - 1)
    _, _ -> panic as "synthetic prefix deadline"
  }
}

fn adapter_terminal(
  adapter: c.SessionAdapter(xai.Handle),
  handle: xai.Handle,
  attempts: Int,
) -> #(ir.Value, xai.Handle) {
  let #(message, handle) = next(adapter, handle, 100)
  let assert Ok(event) = ir.parse(message)
  case ir.string_field(event, "type"), attempts {
    Ok("response.completed"), _ -> #(event, handle)
    _, n if n > 0 -> adapter_terminal(adapter, handle, n - 1)
    _, _ -> panic as "synthetic configured-adapter terminal deadline"
  }
}

pub fn configured_adapter_accepts_full_mixed_auth_lists_and_preserves_selected_partition_test() {
  let #(api_server, api_origin, api_observed, api_closed) =
    native.peer(None, "normal")
  let #(oauth_server, oauth_origin, oauth_observed, oauth_closed) =
    native.peer(None, "normal")
  let assert Ok(store) = storage.new(directory())
  let assert Ok(api_binding) =
    operations.new(
      "api-selected",
      "api_key",
      "responses",
      "responses/websocket",
      api_origin <> "/v1",
      True,
    )
  let assert Ok(oauth_binding) =
    operations.new(
      "oauth-selected",
      "oauth",
      "responses",
      "responses/websocket",
      oauth_origin <> "/v1",
      True,
    )
  let bindings = [api_binding, oauth_binding]
  let accounts = [
    #(
      "api-selected",
      "api_key",
      api_origin,
      api_observed,
      api_closed,
      api_binding,
    ),
    #(
      "oauth-selected",
      "oauth",
      oauth_origin,
      oauth_observed,
      oauth_closed,
      oauth_binding,
    ),
  ]
  list.each(accounts, fn(account) {
    runtime_store.save(
      store,
      credentials.key("xai", account.1, account.0),
      material(account.1),
    )
    |> should.be_ok
    operations.validate_account(account.0, account.1, [account.5])
    |> should.be_ok
  })
  list.each([bindings, list.reverse(bindings)], fn(all_bindings) {
    let adapter =
      xai.configured_adapter(
        "synthetic-tenant",
        all_bindings,
        None,
        store,
        fn() { True },
      )
    list.each(accounts, fn(account) {
      let context =
        c.Context(
          "xai",
          account.1,
          account.0,
          account.2,
          "synthetic-opaque-" <> account.0,
          material(account.1),
        )
      let request =
        c.Request(
          ..native.req(account.1, create),
          pinned_account: Some(account.0),
        )
      let assert Ok(opened) = adapter.open(context, request)
      let assert Ok(handle) = adapter.send(opened.handle, request)
      let #(_, handle) = adapter_terminal(adapter, handle, 20)
      adapter.cancel(handle)
      process.receive(account.4, 1000) |> should.be_ok
      list.each([0, 1, 2], fn(_) {
        process.receive(account.3, 1000) |> should.be_ok
      })
      process.receive(account.3, 20) |> should.be_error
      let denied = Error(c.Failure(c.Unsupported, c.NotSent, None))
      let other =
        list.filter(all_bindings, fn(binding) { binding != account.5 })
      xai.configured_adapter("synthetic-tenant", other, None, store, fn() {
        True
      }).open(context, request)
      |> should.equal(denied)
      xai.configured_adapter(
        "synthetic-tenant",
        [account.5, ..all_bindings],
        None,
        store,
        fn() { True },
      ).open(context, request)
      |> should.equal(denied)
      let assert Ok(conflicting) =
        operations.new(
          account.0,
          account.1,
          "responses",
          "responses/websocket",
          "http://127.0.0.1:1/v1",
          True,
        )
      xai.configured_adapter(
        "synthetic-tenant",
        [conflicting, ..all_bindings],
        None,
        store,
        fn() { True },
      ).open(context, request)
      |> should.equal(denied)
      adapter.open(c.Context(..context, origin: "http://127.0.0.1:1"), request)
      |> should.equal(denied)
      adapter.open(context, c.Request(..request, pinned_account: Some("other")))
      |> should.equal(denied)
      process.receive(account.3, 20) |> should.be_error
    })
  })
  list.each([api_server.pid, oauth_server.pid], fn(server) {
    process.unlink(server)
    process.send_exit(server)
  })
}

pub fn configured_adapter_model_qualification_matches_ws_registration_before_transport_test() {
  let #(server, origin, observed, _) = native.peer(None, "normal")
  let #(store, _, bindings, pool) = setup(origin, "api_key")
  let adapter =
    xai.configured_adapter("synthetic-tenant", bindings, None, store, fn() {
      True
    })
  let context =
    c.Context(
      "xai",
      "api_key",
      "selected",
      origin,
      "nonempty-synthetic-composer-conversation",
      material("api_key"),
    )
  list.each(
    ["grok-composer-2.5-fast", "grok-build-0.1", "grok-4.7-build-fast"],
    fn(model) {
      let body =
        "{\"type\":\"response.create\",\"model\":\""
        <> model
        <> "\",\"input\":[]}"
      adapter.open(
        context,
        c.Request(..native.req("api_key", body), model: model),
      )
      |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
      process.receive(observed, 20) |> should.be_error
    },
  )
  cleanup(pool, server.pid)
}

pub fn runtime_scoped_open_retains_unchanged_acquired_revision_before_upgrade_test() {
  list.each(["api_key", "oauth"], fn(mode) {
    let #(server, origin, observed, closed) = native.peer(None, "normal")
    let #(store, key, bindings, pool) = setup(origin, mode)
    let assert Ok(before) = runtime_store.load_record(store, key)
    let seen = process.new_subject()
    let adapter =
      xai.configured_adapter("synthetic-tenant", bindings, None, store, fn() {
        True
      })
    let scoped_open =
      xai.configured_scoped_open(
        "synthetic-tenant",
        bindings,
        None,
        store,
        fn() { True },
      )
    let request =
      c.Request(..native.req(mode, create), pinned_account: Some("selected"))
    let assert Ok(session) =
      runtime.open_session_scoped(
        pool,
        adapter,
        fn(context, acquired, request) {
          acquired |> should.equal(runtime_store.revision(before))
          context.credential
          |> should.equal(runtime_store.record_material(before))
          process.send(seen, acquired)
          scoped_open(context, acquired, request)
        },
        request,
      )
    let assert Ok(acquired) = process.receive(seen, 1000)
    let assert Ok(after) = runtime_store.load_record(store, key)
    runtime_store.revision(after) |> should.equal(acquired)
    runtime.session_send(session, request) |> should.be_ok
    let _ = terminal(session, 100)
    runtime.active_leases(pool) |> should.equal(Ok(1))
    list.each([0, 1, 2], fn(_) {
      process.receive(observed, 1000) |> should.be_ok
    })
    process.receive(observed, 20) |> should.be_error
    runtime.session_cancel(session)
    runtime.active_leases(pool) |> should.equal(Ok(0))
    // Physical peer closure remains a separate assertion, not abort-Ok proof.
    process.receive(closed, 1000) |> should.be_ok
    cleanup(pool, server.pid)
  })
}

pub fn runtime_acquisition_to_bind_replacement_denies_same_and_different_material_before_tcp_test() {
  list.each(["api_key", "oauth"], fn(mode) {
    list.each(["same-material", "different-material"], fn(mutation) {
      let assert Ok(#(probe, port)) = start_accept_probe()
      let origin = "http://127.0.0.1:" <> int.to_string(port)
      let #(store, key, bindings, pool) = setup(origin, mode)
      let assert Ok(before) = runtime_store.load_record(store, key)
      let seen = process.new_subject()
      let terminals = process.new_subject()
      let notify = fn(terminal) { process.send(terminals, terminal) }
      let adapter =
        xai.configured_adapter_notifying(
          "synthetic-tenant",
          bindings,
          None,
          store,
          fn() { True },
          notify,
        )
      let scoped_open =
        xai.configured_scoped_open_notifying(
          "synthetic-tenant",
          bindings,
          None,
          store,
          fn() { True },
          notify,
        )
      let request =
        c.Request(..native.req(mode, create), pinned_account: Some("selected"))
      runtime.open_session_scoped(
        pool,
        adapter,
        fn(context, acquired, request) {
          acquired |> should.equal(runtime_store.revision(before))
          context.credential
          |> should.equal(runtime_store.record_material(before))
          // The real runtime has already acquired R1. Replace inside this
          // exact callback BEFORE calling provider bind: no sleeps or guessed
          // scheduling, and no replacement of runtime's supplied revision.
          let replacement = case mutation, context.credential {
            "same-material", material -> material
            _, c.ApiKey(_) -> c.ApiKey("synthetic-f18-race-replaced")
            _, c.OAuth(data) ->
              c.OAuth(
                c.OAuthData(
                  ..data,
                  credential: auth.Credential(
                    ..data.credential,
                    access_token: "synthetic-f18-race-replaced",
                  ),
                ),
              )
            _, _ -> panic as "unexpected synthetic acquisition material"
          }
          runtime_store.save(store, key, replacement) |> should.be_ok
          let assert Ok(after) = runtime_store.load_record(store, key)
          { runtime_store.revision(after) == acquired } |> should.equal(False)
          runtime_store.record_material(after) |> should.equal(replacement)
          process.send(seen, acquired)
          scoped_open(context, acquired, request)
        },
        request,
      )
      |> should.equal(
        Error(c.Failure(c.CredentialUnavailable, c.NotSent, None)),
      )
      process.receive(seen, 1000) |> should.be_ok
      // No physical accept means no handshake/inference traffic. The probe
      // increments before closing any unexpected connection, not after a timer.
      accept_count(probe) |> should.equal(0)
      runtime.active_leases(pool) |> should.equal(Ok(0))
      process.receive(terminals, 20) |> should.be_error
      runtime.stop(pool) |> should.be_ok
      stop_accept_probe(probe) |> should.be_ok
    })
  })
}
