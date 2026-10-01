import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store as grants
import mimic/auth/storage
import mimic/fleet
import mimic/providers/contracts as c
import mimic/providers/registry
import mimic/providers/runtime

fn setup(
  material: c.AuthMaterial,
  policy: credentials.Policy,
  fun: fn(storage.Store, runtime.Runtime, c.Request) -> a,
) -> a {
  use directory, _, _ <- with_servers(<<>>, False, fn(_, _) { False })
  let assert Ok(store) = storage.new(directory)
  let mode = case material {
    c.OAuth(_) -> "oauth"
    _ -> "api_key"
  }
  let key = credentials.key("deadline", mode, "selected")
  grants.save(store, key, material) |> should.be_ok
  let assert Ok(registered) =
    registry.new([
      registry.Model("deadline", "configured", [mode], ["test"], ["test"], [
        c.Buffer,
      ]),
    ])
  let assert Ok(engine) =
    runtime.start(store, registered, [
      runtime.Account(
        "deadline",
        mode,
        "selected",
        "http://127.0.0.1:1",
        fleet.LocalLoopback,
        4,
        ["configured"],
        policy,
      ),
    ])
  let request =
    c.Request(
      "deadline",
      mode,
      "configured",
      "test",
      "test",
      c.Buffered,
      [c.Buffer],
      "synthetic",
      Some("selected"),
      "",
    )
  finally(fn() { fun(store, engine, request) }, fn() {
    runtime.stop(engine) |> should.be_ok
  })
}

fn adapter(invoked: process.Subject(process.Pid)) -> c.Adapter(Int) {
  c.Adapter(
    open: fn(_, _) {
      process.send(invoked, process.self())
      Ok(c.Opened(200, [], 0))
    },
    next: fn(_) { Ok(None) },
    cancel: fn(_) { Nil },
    rejection: fn(_, _) { None },
  )
}

pub fn expired_before_start_has_no_acquisition_adapter_or_lease_test() {
  use store, engine, request <- setup(
    c.ApiKey("synthetic"),
    credentials.StaticKey,
  )
  let key = credentials.key("deadline", "api_key", "selected")
  let assert Ok(before) = grants.load_record(store, key)
  let invoked = process.new_subject()
  runtime.open_until(engine, adapter(invoked), request, monotonic_ms() - 1)
  |> should.equal(Error(c.Failure(c.Cancelled, c.NotSent, None)))
  process.receive(invoked, 0) |> should.be_error
  runtime.active_leases(engine) |> should.equal(Ok(0))
  let assert Ok(after) = grants.load_record(store, key)
  { before == after } |> should.be_true
}

pub fn paused_acquisition_expires_no_late_lease_or_adapter_test() {
  use _, engine, request <- setup(c.ApiKey("synthetic"), credentials.StaticKey)
  let invoked = process.new_subject()
  let began = monotonic_ms()
  with_paused_runtime(engine, fn() {
    runtime.open_until(engine, adapter(invoked), request, began + 100)
    |> should.equal(Error(c.Failure(c.Cancelled, c.Uncertain, None)))
  })
  { monotonic_ms() - began <= 100 + runtime.deadline_cleanup_ms + 200 }
  |> should.be_true
  runtime.active_leases(engine) |> should.equal(Ok(0))
  process.receive(invoked, 0) |> should.be_error
}

pub fn blocked_open_is_uncertain_non_retryable_and_other_lease_survives_test() {
  use _, engine, request <- setup(c.ApiKey("synthetic"), credentials.StaticKey)
  let invoked = process.new_subject()
  let base = adapter(invoked)
  let assert Ok(other) = runtime.open(engine, base, request)
  let blocked =
    c.Adapter(..base, open: fn(_, _) {
      process.send(invoked, process.self())
      process.sleep(5000)
      Ok(c.Opened(200, [], 0))
    })
  let began = monotonic_ms()
  runtime.open_until(engine, blocked, request, began + 150)
  |> should.equal(Error(c.Failure(c.Cancelled, c.Uncertain, None)))
  { monotonic_ms() - began <= 150 + runtime.deadline_cleanup_ms + 200 }
  |> should.be_true
  runtime.retryable(c.Failure(c.Cancelled, c.Uncertain, None))
  |> should.be_false
  runtime.active_leases(engine) |> should.equal(Ok(1))
  runtime.next(other.stream) |> should.equal(Ok(None))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn absolute_deadline_bounds_blocked_read_and_accepts_monotonic_origin_test() {
  use _, engine, request <- setup(c.ApiKey("synthetic"), credentials.StaticKey)
  let invoked = process.new_subject()
  let base = adapter(invoked)
  let blocked =
    c.Adapter(..base, next: fn(_) {
      process.sleep(5000)
      Ok(None)
    })
  let began = monotonic_ms()
  // The actual BEAM origin can be negative; no wall-time/nonnegative gate.
  let deadline = began + 150
  let assert Ok(response) =
    runtime.open_until(engine, blocked, request, deadline)
  runtime.next_until(response.stream, deadline)
  |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
  { monotonic_ms() - began <= 150 + runtime.deadline_cleanup_ms + 200 }
  |> should.be_true
  let assert Ok(execution) = process.receive(invoked, 0)
  process.is_alive(execution) |> should.be_false
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn idle_execution_expires_without_a_pull_and_later_deadline_cannot_extend_test() {
  use _, engine, request <- setup(c.ApiKey("synthetic"), credentials.StaticKey)
  let invoked = process.new_subject()
  let assert Ok(response) =
    runtime.open_until(engine, adapter(invoked), request, monotonic_ms() + 100)
  process.sleep(150)
  runtime.active_leases(engine) |> should.equal(Ok(0))
  runtime.next_until(response.stream, monotonic_ms() + 10_000)
  |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
}

pub fn revoked_owner_expired_pull_cannot_kill_adopted_execution_test() {
  use _, engine, request <- setup(c.ApiKey("synthetic"), credentials.StaticKey)
  let invoked = process.new_subject()
  let assert Ok(response) = runtime.open(engine, adapter(invoked), request)
  let ready = process.new_subject()
  let answer = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      runtime.adopt(response.stream) |> should.be_ok
      process.send(ready, release)
      let assert Ok(Nil) = process.receive(release, 2000)
      process.send(answer, runtime.next(response.stream))
    })
  use <- finally(_, fn() { process.kill(owner) })
  let assert Ok(release) = process.receive(ready, 1000)
  runtime.next_until(response.stream, monotonic_ms() - 1)
  |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
  runtime.active_leases(engine) |> should.equal(Ok(1))
  process.send(release, Nil)
  process.receive(answer, 1000) |> should.equal(Ok(Ok(None)))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn deadline_cancels_waiter_not_shared_credential_refresh_test() {
  let refreshing = process.new_subject()
  let policy =
    credentials.Refreshable(
      c.Refresh(fn(_, _) {
        let release = process.new_subject()
        process.send(refreshing, #(process.self(), release))
        let assert Ok(Nil) = process.receive(release, 2000)
        Ok(
          c.OAuthData(
            auth.Credential(
              "synthetic-new",
              "synthetic-refresh",
              epoch_ms() + 3_600_000,
            ),
            [],
          ),
        )
      }),
    )
  use _, engine, request <- setup(
    c.OAuth(
      c.OAuthData(auth.Credential("synthetic-old", "synthetic-refresh", 1), []),
    ),
    policy,
  )
  let invoked = process.new_subject()
  let timed_out = process.new_subject()
  let waiter =
    process.spawn_unlinked(fn() {
      process.send(
        timed_out,
        runtime.open_until(
          engine,
          adapter(invoked),
          request,
          monotonic_ms() + 200,
        ),
      )
    })
  use <- finally(_, fn() { process.kill(waiter) })
  let assert Ok(#(refresh_worker, release)) = process.receive(refreshing, 1000)
  process.receive(timed_out, 1500)
  |> should.equal(Ok(Error(c.Failure(c.Cancelled, c.Uncertain, None))))
  process.is_alive(refresh_worker) |> should.be_true
  process.receive(invoked, 0) |> should.be_error
  runtime.active_leases(engine) |> should.equal(Ok(0))
  process.send(release, Nil)
  let assert Ok(response) =
    runtime.open_until(engine, adapter(invoked), request, monotonic_ms() + 1000)
  runtime.next(response.stream) |> should.equal(Ok(None))
  process.receive(refreshing, 0) |> should.be_error
}

pub type Server

@external(erlang, "mimic_devin_f28_status_test_ffi", "with_servers")
fn with_servers(
  bytes: BitArray,
  hold: Bool,
  inspect: fn(String, BitArray) -> Bool,
  fun: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_f28_status_test_ffi", "finally")
fn finally(fun: fn() -> a, cleanup: fn() -> b) -> a

@external(erlang, "mimic_provider_deadline_test_ffi", "with_paused_runtime")
fn with_paused_runtime(runtime: runtime.Runtime, fun: fn() -> a) -> a

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_auth_ffi", "now_ms")
fn epoch_ms() -> Int
