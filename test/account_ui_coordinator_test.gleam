/// Synthetic shortened-time tests of the shell lifecycle, not live OAuth.
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/account_ui/coordinator.{Authorization}
import mimic/account_ui/primitives
import mimic/auth/crypto
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/gateway/config
import mimic/ir
import mimic/providers/claude/policy
import mimic/providers/kimi/oauth

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

type Clock

@external(erlang, "mimic_account_ui_test_ffi", "clock_new")
fn clock_new(now: Int) -> Clock

@external(erlang, "mimic_account_ui_test_ffi", "clock_get")
fn clock_get(clock: Clock) -> Int

@external(erlang, "mimic_account_ui_test_ffi", "clock_set")
fn clock_set(clock: Clock, now: Int) -> Nil

type Fixture {
  Fixture(
    engine: coordinator.Coordinator,
    store: storage.Store,
    bootstrap: String,
  )
}

fn fixture(limits: coordinator.Limits, send: oauth.Send) -> Fixture {
  fixture_with_clock(limits, send, primitives.monotonic_ms)
}

fn fixture_with_clock(
  limits: coordinator.Limits,
  send: oauth.Send,
  clock: fn() -> Int,
) -> Fixture {
  let assert Ok(store) = storage.new(directory())
  let bootstrap = crypto.random_url_token()
  primitives.create_private(store.directory, "bootstrap-test.txt", bootstrap)
  |> should.be_ok
  let account =
    config.Account(
      "kimi",
      "oauth",
      "one",
      "http://127.0.0.1:43210",
      ["kimi-k2.7-code"],
      fleet.LocalLoopback,
      Some(
        config.KimiOAuth(oauth.Config(
          "kimi.com",
          "http://127.0.0.1:43210/api/oauth/device_authorization",
          "http://127.0.0.1:43210/api/oauth/token",
          "",
        )),
      ),
      "/coding",
      claude_policy: policy.native(),
      claude_client_headers: [],
      xai_operations: [],
    )
  let assert Ok(engine) =
    coordinator.start_with_clock(
      store,
      [account],
      "synthetic-device",
      send,
      "bootstrap-test.txt",
      bootstrap,
      limits,
      clock,
    )
  Fixture(engine, store, bootstrap)
}

pub fn negative_monotonic_origin_does_not_block_first_bootstrap_test() {
  let fixture =
    fixture_with_clock(
      coordinator.Limits(1000, 1000, 1000, 10),
      fn(_) { Error("no provider I/O") },
      fn() { -100_000 },
    )
  let auth = unlock(fixture)
  coordinator.status(fixture.engine, auth).status |> should.equal(200)
  coordinator.stop(fixture.engine) |> should.be_ok
}

fn unlock(fixture: Fixture) -> coordinator.Authorization {
  let reply = coordinator.exchange(fixture.engine, fixture.bootstrap)
  reply.status |> should.equal(200)
  let assert Some(token) = reply.session_cookie
  let assert Ok(value) = ir.parse(json.to_string(reply.body))
  let assert Ok(csrf) = ir.string_field(value, "csrf")
  Authorization(token, csrf)
}

pub fn bootstrap_actual_expiry_and_single_use_test() {
  let called = process.new_subject()
  let send = fn(_) {
    process.send(called, Nil)
    Error("synthetic")
  }
  let expired = fixture(coordinator.Limits(30, 1000, 1000, 10), send)
  process.sleep(60)
  coordinator.exchange(expired.engine, expired.bootstrap).status
  |> should.equal(401)
  primitives.private_read(expired.store.directory <> "/bootstrap-test.txt")
  |> should.be_error
  coordinator.stop(expired.engine) |> should.be_ok
  let used = fixture(coordinator.Limits(1000, 1000, 1000, 10), send)
  let auth = unlock(used)
  coordinator.exchange(used.engine, used.bootstrap).status |> should.equal(401)
  coordinator.status(used.engine, auth).status |> should.equal(200)
  coordinator.logout(used.engine, auth).status |> should.equal(200)
  coordinator.status(used.engine, auth).status |> should.equal(401)
  process.receive(called, 0) |> should.equal(Error(Nil))
  coordinator.stop(used.engine) |> should.be_ok
}

pub fn session_and_attempt_expiry_cancel_inflight_work_test() {
  list.each(["session", "attempt"], fn(kind) {
    let entered = process.new_subject()
    let clock = clock_new(-100_000)
    let limits = case kind {
      "session" -> coordinator.Limits(10_000, 1000, 10_000, 10)
      _ -> coordinator.Limits(10_000, 10_000, 1000, 10)
    }
    let fixture =
      fixture_with_clock(
        limits,
        fn(_) {
          let release = process.new_subject()
          process.send(entered, release)
          let _ = process.receive(release, 10_000)
          Error("synthetic")
        },
        fn() { clock_get(clock) },
      )
    let auth = unlock(fixture)
    coordinator.login(fixture.engine, auth, "one").status |> should.equal(202)
    let assert Ok(release) = process.receive(entered, 5000)
    // Advance only after actual async entry. No bootstrap/filesystem timing
    // assumption is hidden in an 80ms sleep on a concurrently loaded machine.
    clock_set(clock, -98_000)
    let expected = case kind {
      "session" -> 401
      _ -> 200
    }
    coordinator.status(fixture.engine, auth).status |> should.equal(expected)
    storage.read_runtime_slot(
      fixture.store,
      credentials.key("kimi", "oauth", "one"),
    )
    |> should.equal(Ok(None))
    let assert Ok(worker) = process.subject_owner(release)
    process.sleep(50)
    process.is_alive(worker) |> should.be_false
    coordinator.stop(fixture.engine) |> should.be_ok
  })
}

pub fn unavailable_slot_blocks_network_and_rate_is_bounded_test() {
  let called = process.new_subject()
  let fixture =
    fixture(coordinator.Limits(2000, 2000, 2000, 10), fn(_) {
      process.send(called, Nil)
      Error("synthetic")
    })
  let auth = unlock(fixture)
  let assert Ok(ticket) =
    runtime_store.begin_enrollment(
      fixture.store,
      credentials.key("kimi", "oauth", "one"),
    )
  coordinator.login(fixture.engine, auth, "one").status |> should.equal(409)
  process.receive(called, 0) |> should.equal(Error(Nil))
  list.each(list.repeat(Nil, 20), fn(_) {
    coordinator.admit(fixture.engine, Authorization("", "")) |> should.be_true
  })
  coordinator.admit(fixture.engine, Authorization("", "")) |> should.be_false
  coordinator.admit(fixture.engine, auth) |> should.be_true
  runtime_store.cancel_enrollment(ticket) |> should.be_ok
  coordinator.stop(fixture.engine) |> should.be_ok
}
