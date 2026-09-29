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
import mimic/providers/contracts.{
  type SessionAdapter, ApiKey, Cancelled, CredentialUnavailable, Failure,
  InvalidConfiguration, NotSent, OAuth, OAuthData, Opened, Refresh, Request,
  SessionAdapter, Started, Stream, Streaming, Uncertain, Unsupported, WebSocket,
}
import mimic/providers/registry
import mimic/providers/runtime

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "mimic_provider_ws_runtime_test_ffi", "unlink_runtime")
fn unlink_runtime(value: runtime.Runtime) -> process.Pid

fn request() -> contracts.Request {
  Request(
    "synthetic-ws",
    "key",
    "model",
    "test",
    "generate",
    Streaming,
    [WebSocket],
    "session",
    None,
    "{}",
  )
}

fn registry() -> registry.Registry {
  let assert Ok(value) =
    registry.new([
      registry.Model(
        "synthetic-ws",
        "model",
        ["key", "oauth"],
        ["test"],
        ["generate"],
        [Stream, WebSocket],
      ),
      registry.Model(
        "synthetic-ws",
        "different",
        ["key", "oauth"],
        ["test"],
        ["generate"],
        [Stream, WebSocket],
      ),
    ])
  value
}

fn account(mode: String, policy: credentials.Policy) -> runtime.Account {
  runtime.Account(
    "synthetic-ws",
    mode,
    "a",
    "http://127.0.0.1:1",
    fleet.LocalLoopback,
    1,
    ["model"],
    policy,
  )
}

fn static_runtime() -> #(storage.Store, runtime.Runtime) {
  let assert Ok(store) = storage.new(directory())
  credentials.save_api_key(
    store,
    credentials.key("synthetic-ws", "key", "a"),
    "synthetic-original",
  )
  |> should.be_ok
  let assert Ok(value) =
    runtime.start(store, registry(), [
      account("key", credentials.StaticKey),
    ])
  #(store, value)
}

fn adapter(events: process.Subject(String)) -> SessionAdapter(Int) {
  SessionAdapter(
    open: fn(_, _) {
      process.send(events, "open")
      Ok(Opened(101, [], 0))
    },
    send: fn(handle, _) {
      process.send(events, "send")
      Ok(handle + 1)
    },
    receive: fn(handle) {
      process.send(events, "poll")
      case handle {
        0 -> Ok(#(None, handle))
        _ -> Ok(#(Some("frame-" <> int.to_string(handle)), handle))
      }
    },
    cancel: fn(_) { process.send(events, "cancel") },
  )
}

fn wait_for_cleanup(value: runtime.Runtime, attempts: Int) {
  case runtime.active_leases(value), attempts {
    Ok(0), _ -> Nil
    _, 0 -> panic as "synthetic WebSocket lease was not released"
    _, _ -> {
      process.sleep(5)
      wait_for_cleanup(value, attempts - 1)
    }
  }
}

fn events_equal(events: process.Subject(String), expected: List(String)) {
  list.each(expected, fn(event) {
    process.receive(events, 1000) |> should.equal(Ok(event))
  })
  process.receive(events, 20) |> should.equal(Error(Nil))
}

pub fn requires_websocket_capability_before_open_test() {
  let #(_, value) = static_runtime()
  let events = process.new_subject()
  runtime.open_session(
    value,
    adapter(events),
    Request(..request(), required: []),
  )
  |> should.equal(Error(Failure(Unsupported, NotSent, None)))
  runtime.active_leases(value) |> should.equal(Ok(0))
  events_equal(events, [])
  runtime.stop(value) |> should.be_ok
}

pub fn synchronous_handoff_revokes_alive_owner_and_survives_old_death_test() {
  let #(_, value) = static_runtime()
  let events = process.new_subject()
  let ready = process.new_subject()
  let stale = process.new_subject()
  let old_owner =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      let assert Ok(session) =
        runtime.open_session(value, adapter(events), request())
      process.send(ready, #(session, commands))
      let _ = process.receive_forever(commands)
      process.send(stale, #(
        runtime.session_send(session, request()),
        runtime.session_poll(session),
        runtime.session_adopt(session),
      ))
      runtime.session_cancel(session)
      process.sleep_forever()
    })
  let assert Ok(#(session, commands)) = process.receive(ready, 1000)
  runtime.session_account(session) |> should.equal("a")
  runtime.active_leases(value) |> should.equal(Ok(1))
  runtime.session_adopt(session) |> should.equal(Ok(Nil))
  process.send(commands, Nil)
  let denied = Error(Failure(Cancelled, Started, None))
  let assert Ok(#(stale_send, stale_poll, stale_adopt)) =
    process.receive(stale, 1000)
  stale_send |> should.equal(denied)
  stale_poll |> should.equal(Error(Failure(Cancelled, Started, None)))
  stale_adopt |> should.equal(denied)
  // The stale owner's cancel must not close the replacement's connection.
  runtime.active_leases(value) |> should.equal(Ok(1))
  runtime.session_send(session, request()) |> should.equal(Ok(Nil))
  runtime.session_poll(session) |> should.equal(Ok(Some("frame-1")))
  process.kill(old_owner)
  runtime.session_send(session, request()) |> should.equal(Ok(Nil))
  runtime.session_poll(session) |> should.equal(Ok(Some("frame-2")))
  runtime.session_cancel(session)
  wait_for_cleanup(value, 100)
  events_equal(events, ["open", "send", "poll", "send", "poll", "cancel"])
  runtime.stop(value) |> should.be_ok
}

pub fn adoption_during_in_flight_send_or_poll_fails_closed_test() {
  list.each(["send", "poll"], fn(operation) {
    let #(_, value) = static_runtime()
    let events = process.new_subject()
    let ready = process.new_subject()
    let started = process.new_subject()
    let finished = process.new_subject()
    let base = adapter(events)
    let blocked = case operation {
      "send" ->
        SessionAdapter(..base, send: fn(handle, request) {
          let resume = process.new_subject()
          process.send(started, resume)
          let _ = process.receive_forever(resume)
          base.send(handle, request)
        })
      _ ->
        SessionAdapter(..base, receive: fn(handle) {
          let resume = process.new_subject()
          process.send(started, resume)
          let _ = process.receive_forever(resume)
          base.receive(handle)
        })
    }
    let owner =
      process.spawn_unlinked(fn() {
        let go = process.new_subject()
        let assert Ok(session) = runtime.open_session(value, blocked, request())
        process.send(ready, #(session, go))
        let _ = process.receive_forever(go)
        let result = case operation {
          "send" -> runtime.session_send(session, request()) |> is_ok
          _ -> runtime.session_poll(session) |> is_ok
        }
        process.send(finished, result)
        process.sleep_forever()
      })
    let assert Ok(#(session, go)) = process.receive(ready, 1000)
    process.send(go, Nil)
    let assert Ok(resume) = process.receive(started, 1000)
    runtime.session_adopt(session)
    |> should.equal(Error(Failure(Cancelled, Started, None)))
    runtime.active_leases(value) |> should.equal(Ok(1))
    process.send(resume, Nil)
    process.receive(finished, 1000) |> should.equal(Ok(True))
    // An unsuccessful adoption does not revoke the original owner.
    runtime.session_adopt(session) |> should.equal(Ok(Nil))
    process.kill(owner)
    case operation {
      "send" ->
        runtime.session_poll(session) |> should.equal(Ok(Some("frame-1")))
      _ -> runtime.session_send(session, request()) |> should.equal(Ok(Nil))
    }
    runtime.session_cancel(session)
    wait_for_cleanup(value, 100)
    runtime.stop(value) |> should.be_ok
  })
}

fn is_ok(value: Result(a, b)) -> Bool {
  case value {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn dead_owner_cannot_transfer_and_releases_only_lease_test() {
  let #(_, value) = static_runtime()
  let events = process.new_subject()
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(session) =
        runtime.open_session(value, adapter(events), request())
      process.send(ready, session)
      process.sleep_forever()
    })
  let assert Ok(session) = process.receive(ready, 1000)
  runtime.active_leases(value) |> should.equal(Ok(1))
  let monitor = process.monitor(owner)
  process.kill(owner)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  runtime.session_adopt(session) |> should.be_error
  wait_for_cleanup(value, 100)
  // max_in_flight is one; reopening proves no leaked or double-held lease.
  let assert Ok(replacement) =
    runtime.open_session(value, adapter(events), request())
  runtime.active_leases(value) |> should.equal(Ok(1))
  runtime.session_cancel(replacement)
  wait_for_cleanup(value, 100)
  runtime.stop(value) |> should.be_ok
}

pub fn runtime_death_revokes_live_session_and_releases_store_owner_test() {
  let #(store, value) = static_runtime()
  let events = process.new_subject()
  let assert Ok(session) =
    runtime.open_session(value, adapter(events), request())
  runtime.active_leases(value) |> should.equal(Ok(1))
  let pid = unlink_runtime(value)
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  runtime.session_adopt(session) |> should.be_error
  runtime.session_send(session, request()) |> should.be_error
  runtime.session_poll(session) |> should.be_error
  // The store guard monitors the runtime. A fresh actor must be able to claim
  // the same state directory after its DOWN and hold one new lease.
  let restarted = restart(store, 100)
  let assert Ok(new_session) =
    runtime.open_session(restarted, adapter(events), request())
  runtime.active_leases(restarted) |> should.equal(Ok(1))
  runtime.session_cancel(new_session)
  wait_for_cleanup(restarted, 100)
  runtime.stop(restarted) |> should.be_ok
}

fn restart(store: storage.Store, attempts: Int) -> runtime.Runtime {
  case
    runtime.start(store, registry(), [
      account("key", credentials.StaticKey),
    ]),
    attempts
  {
    Ok(value), _ -> value
    Error(_), 0 -> panic as "runtime death left the store locked"
    Error(_), _ -> {
      process.sleep(5)
      restart(store, attempts - 1)
    }
  }
}

pub fn static_credential_rotation_and_deletion_before_next_send_never_replay_test() {
  list.each(["rotate", "same-token-save", "delete"], fn(change) {
    let #(store, value) = static_runtime()
    let events = process.new_subject()
    let assert Ok(session) =
      runtime.open_session(value, adapter(events), request())
    runtime.session_send(session, request()) |> should.equal(Ok(Nil))
    let key = credentials.key("synthetic-ws", "key", "a")
    case change {
      "delete" -> runtime_store.delete(store, key) |> should.be_ok
      "same-token-save" ->
        runtime_store.save(store, key, ApiKey("synthetic-original"))
        |> should.be_ok
      _ ->
        runtime_store.save(store, key, ApiKey("synthetic-rotated"))
        |> should.be_ok
    }
    runtime.session_send(session, request())
    |> should.equal(Error(Failure(CredentialUnavailable, Started, None)))
    wait_for_cleanup(value, 100)
    events_equal(events, ["open", "send", "cancel"])
    runtime.session_send(session, request()) |> should.be_error
    runtime.stop(value) |> should.be_ok
  })
}

pub fn refreshed_oauth_before_second_send_invalidates_socket_without_replay_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic-ws", "oauth", "a")
  let original =
    OAuth(
      OAuthData(
        auth.Credential(
          "synthetic-old",
          "synthetic-refresh",
          now_ms() + 3_600_000,
        ),
        [],
      ),
    )
  runtime_store.save(store, key, original) |> should.be_ok
  let refreshed = process.new_subject()
  let refresh =
    Refresh(fn(_, now) {
      process.send(refreshed, Nil)
      Ok(
        OAuthData(
          auth.Credential("synthetic-new", "synthetic-next", now + 3_600_000),
          [],
        ),
      )
    })
  let assert Ok(value) =
    runtime.start(store, registry(), [
      account("oauth", credentials.Refreshable(refresh)),
    ])
  let events = process.new_subject()
  let req = Request(..request(), auth_mode: "oauth")
  let assert Ok(session) = runtime.open_session(value, adapter(events), req)
  runtime.session_send(session, req) |> should.equal(Ok(Nil))
  runtime_store.save(
    store,
    key,
    OAuth(
      OAuthData(
        auth.Credential("synthetic-expired", "synthetic-refresh", 0),
        [],
      ),
    ),
  )
  |> should.be_ok
  runtime.session_send(session, req)
  |> should.equal(Error(Failure(CredentialUnavailable, Started, None)))
  process.receive(refreshed, 1000) |> should.equal(Ok(Nil))
  wait_for_cleanup(value, 100)
  events_equal(events, ["open", "send", "cancel"])
  runtime.stop(value) |> should.be_ok
}

pub fn scoped_model_session_and_account_are_immutable_after_open_test() {
  let fields = ["model", "session", "account"]
  list.each(fields, fn(field) {
    let #(_, value) = static_runtime()
    let events = process.new_subject()
    let assert Ok(session) =
      runtime.open_session(value, adapter(events), request())
    let changed = case field {
      "model" -> Request(..request(), model: "different")
      "session" -> Request(..request(), session: "different")
      _ -> Request(..request(), pinned_account: Some("b"))
    }
    runtime.session_send(session, changed)
    |> should.equal(Error(Failure(InvalidConfiguration, Started, None)))
    wait_for_cleanup(value, 100)
    events_equal(events, ["open", "cancel"])
    runtime.stop(value) |> should.be_ok
  })
}

pub fn idle_cancel_and_failed_active_poll_close_exactly_once_test() {
  let #(_, value) = static_runtime()
  let events = process.new_subject()
  let assert Ok(idle) = runtime.open_session(value, adapter(events), request())
  runtime.session_poll(idle) |> should.equal(Ok(None))
  runtime.active_leases(value) |> should.equal(Ok(1))
  runtime.session_cancel(idle)
  runtime.session_cancel(idle)
  wait_for_cleanup(value, 100)
  events_equal(events, ["open", "poll", "cancel"])

  let base = adapter(events)
  let failing =
    SessionAdapter(..base, receive: fn(_) {
      process.send(events, "poll")
      Error(Failure(Cancelled, Uncertain, None))
    })
  let assert Ok(active) = runtime.open_session(value, failing, request())
  runtime.session_poll(active)
  |> should.equal(Error(Failure(Cancelled, Started, None)))
  runtime.session_cancel(active)
  runtime.session_cancel(active)
  wait_for_cleanup(value, 100)
  events_equal(events, ["open", "poll", "cancel"])
  runtime.stop(value) |> should.be_ok
}
