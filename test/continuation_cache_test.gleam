import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/protocol/continuation as cache
import mimic/providers/contracts

type Clock

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "new_clock")
fn clock(epoch: Int, monotonic: Int) -> Clock

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "set_clock")
fn set_clock(clock: Clock, epoch: Int, monotonic: Int) -> Nil

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "sample")
fn sample(clock: Clock) -> #(Int, Int)

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "erlang", "external_size")
fn size(value: value) -> Int

fn generation() -> runtime_store.Revision {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic", "key", "account")
  credentials.save_api_key(store, key, "synthetic-not-retained") |> should.be_ok
  let assert Ok(record) = runtime_store.load_record(store, key)
  runtime_store.revision(record)
}

fn context() -> contracts.Context {
  contracts.Context(
    "synthetic",
    "key",
    "account",
    "http://127.0.0.1:1",
    "trusted-session",
    contracts.ApiKey("synthetic-not-retained"),
  )
}

fn request() -> contracts.Request {
  contracts.Request(
    "synthetic",
    "key",
    "model",
    "responses",
    "generate",
    contracts.Streaming,
    [],
    "client",
    None,
    "{}",
  )
}

fn scope() -> cache.Scope {
  let assert Ok(scope) =
    cache.scope("tenant", context(), generation(), request())
  scope
}

pub fn all_trusted_scope_dimensions_are_separate_test() {
  let revision = generation()
  let c = context()
  let r = request()
  let assert Ok(scope) = cache.scope("tenant", c, revision, r)
  let assert Ok(store) = cache.start(cache.Limits(10, 65_536, 4096, 1000))
  cache.put(store, scope, "r", "private native history") |> should.be_ok
  [
    cache.scope("other", c, revision, r),
    cache.scope("tenant", c, generation(), r),
    cache.scope(
      "tenant",
      contracts.Context(..c, provider: "other"),
      revision,
      contracts.Request(..r, provider: "other"),
    ),
    cache.scope(
      "tenant",
      contracts.Context(..c, auth_mode: "oauth"),
      revision,
      contracts.Request(..r, auth_mode: "oauth"),
    ),
    cache.scope("tenant", contracts.Context(..c, account: "other"), revision, r),
    cache.scope(
      "tenant",
      contracts.Context(..c, origin: "http://127.0.0.1:2"),
      revision,
      r,
    ),
    cache.scope("tenant", c, revision, contracts.Request(..r, model: "other")),
    cache.scope("tenant", c, revision, contracts.Request(..r, session: "other")),
    cache.scope(
      "tenant",
      c,
      revision,
      contracts.Request(..r, protocol: "websocket"),
    ),
    cache.scope(
      "tenant",
      c,
      revision,
      contracts.Request(..r, operation: "compact"),
    ),
  ]
  |> list.each(fn(other) {
    let assert Ok(other) = other
    cache.get(store, other, "r") |> should.be_error
  })
  cache.get(store, scope, "r") |> should.equal(Ok("private native history"))
  cache.scope("", c, revision, r) |> should.be_error
  cache.scope(
    "tenant",
    c,
    revision,
    contracts.Request(..r, provider: "mismatch"),
  )
  |> should.be_error
  cache.stop(store) |> should.be_ok
}

pub fn ttl_boundary_is_inclusive_and_reclaims_capacity_test() {
  let clock = clock(0, -100)
  let scope = scope()
  let assert Ok(store) =
    cache.start_with_clock(cache.Limits(1, 4096, 4096, 10), fn() {
      sample(clock).1
    })
  cache.put(store, scope, "r", "native") |> should.be_ok
  cache.put(store, scope, "r2", "native") |> should.be_error
  set_clock(clock, 0, -91)
  cache.get(store, scope, "r") |> should.equal(Ok("native"))
  set_clock(clock, 0, -90)
  cache.get(store, scope, "r") |> should.be_error
  cache.put(store, scope, "r2", "native") |> should.be_ok
  cache.stop(store) |> should.be_ok
}

pub fn byte_budgets_count_actual_scope_id_and_opaque_value_test() {
  let scope = scope()
  let value = string.repeat("x", 1000)
  let bytes = size(#(scope, "r1", value))
  let assert Ok(store) = cache.start(cache.Limits(10, bytes * 2, bytes, 1000))
  cache.put(store, scope, "r1", value) |> should.be_ok
  cache.put(store, scope, "r1", "replacement") |> should.be_error
  cache.put(store, scope, "r2", value) |> should.be_ok
  cache.put(store, scope, "r3", value) |> should.be_error
  cache.remove(store, scope, "r1") |> should.be_ok
  cache.put(store, scope, "r3", value) |> should.be_ok
  cache.clear_scope(store, scope) |> should.be_ok
  cache.get(store, scope, "r2") |> should.be_error
  cache.put(store, scope, "r1", value <> "x") |> should.be_error
  cache.stop(store) |> should.be_ok
}

pub fn rollback_overflow_and_clock_failure_latch_until_restart_test() {
  let scope = scope()
  let clock = clock(0, 100)
  let assert Ok(store) =
    cache.start_with_clock(cache.Limits(2, 4096, 4096, 10), fn() {
      sample(clock).1
    })
  cache.put(store, scope, "r", "native") |> should.be_ok
  set_clock(clock, 0, 99)
  cache.get(store, scope, "r") |> should.be_error
  set_clock(clock, 0, 110)
  cache.put(store, scope, "r", "native") |> should.be_error
  cache.stop(store) |> should.be_ok
  let assert Ok(overflow) =
    cache.start_with_clock(cache.Limits(2, 4096, 4096, 10), fn() {
      9_223_372_036_854_775_807
    })
  cache.put(overflow, scope, "r", "native") |> should.be_error
  cache.stop(overflow) |> should.be_ok
  let assert Ok(panic_clock) =
    cache.start_with_clock(cache.Limits(2, 4096, 4096, 10), fn() {
      panic as "synthetic clock failure"
    })
  cache.put(panic_clock, scope, "r", "native") |> should.be_error
  cache.stop(panic_clock) |> should.be_ok
}

pub fn concurrent_duplicate_admission_is_atomic_and_restart_is_empty_test() {
  let scope = scope()
  let assert Ok(store) = cache.start(cache.Limits(2, 4096, 4096, 1000))
  let replies = process.new_subject()
  list.each(list.repeat(Nil, 10), fn(_) {
    process.spawn_unlinked(fn() {
      process.send(replies, cache.put(store, scope, "r", "native"))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 10), fn(_) {
      let assert Ok(answer) = process.receive(replies, 1000)
      answer
    })
  list.count(outcomes, result.is_ok) |> should.equal(1)
  cache.stop(store) |> should.be_ok
  cache.get(store, scope, "r") |> should.be_error
  let assert Ok(fresh) = cache.start(cache.Limits(2, 4096, 4096, 1000))
  cache.get(fresh, scope, "r") |> should.be_error
  cache.stop(fresh) |> should.be_ok
}

pub fn preselection_is_unique_scoped_and_not_generation_authority_test() {
  let clock = clock(0, 0)
  let assert Ok(store) =
    cache.start_with_clock(cache.Limits(10, 65_536, 4096, 10), fn() {
      sample(clock).1
    })
  let old = generation()
  let current = generation()
  let assert Ok(old_scope) = cache.scope("tenant", context(), old, request())
  let assert Ok(current_scope) =
    cache.scope("tenant", context(), current, request())
  cache.put(store, old_scope, "r", "old-native") |> should.be_ok
  cache.locate(store, "tenant", request(), "r") |> should.equal(Ok("account"))
  // Finding the account cannot authorize stale material after selection.
  cache.get(store, current_scope, "r") |> should.be_error
  cache.put(store, current_scope, "r", "new-native") |> should.be_ok
  cache.locate(store, "tenant", request(), "r") |> should.equal(Ok("account"))
  cache.locate(store, "other", request(), "r") |> should.be_error
  cache.locate(store, "tenant", request(), "unknown") |> should.be_error
  let r = request()
  [
    contracts.Request(..r, provider: "other"),
    contracts.Request(..r, auth_mode: "other"),
    contracts.Request(..r, model: "other"),
    contracts.Request(..r, session: "other"),
    contracts.Request(..r, protocol: "other"),
    contracts.Request(..r, operation: "other"),
    contracts.Request(..r, session: ""),
    contracts.Request(..r, pinned_account: Some("account")),
  ]
  |> list.each(fn(r) {
    cache.locate(store, "tenant", r, "r") |> should.be_error
  })
  let assert Ok(other_scope) =
    cache.scope(
      "tenant",
      contracts.Context(..context(), account: "different"),
      current,
      r,
    )
  cache.put(store, other_scope, "r", "different-account") |> should.be_ok
  cache.locate(store, "tenant", r, "r") |> should.be_error
  cache.remove(store, other_scope, "r") |> should.be_ok
  cache.locate(store, "tenant", r, "r") |> should.equal(Ok("account"))
  set_clock(clock, 0, 10)
  cache.locate(store, "tenant", r, "r") |> should.be_error
  cache.stop(store) |> should.be_ok
}
