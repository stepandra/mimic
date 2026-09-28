import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/providers/contracts.{
  Adapter, Buffer, CredentialUnavailable, Failure, InvalidGrant, NotSent, OAuth,
  OAuthData, Opened, Persistence, ReauthorizationRequired, Refresh,
  RefreshRateLimited, RefreshRetryable, RefreshUnavailable, RefreshUnsupported,
  Request, Streaming,
}
import mimic/providers/registry
import mimic/providers/runtime

type Clock

type HttpFixture

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "new_clock")
fn new_clock(epoch: Int, monotonic: Int) -> Clock

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "set_clock")
fn set_clock(clock: Clock, epoch: Int, monotonic: Int) -> Nil

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "sample")
fn sample(clock: Clock) -> #(Int, Int)

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "block_mutation")
fn block_mutation(directory: String, key: String) -> Nil

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "unblock_mutation")
fn unblock_mutation(directory: String, key: String) -> Nil

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "http_start")
fn http_start() -> Result(HttpFixture, String)

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "http_port")
fn http_port(fixture: HttpFixture) -> Int

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "http_requests")
fn http_requests(fixture: HttpFixture) -> Int

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "http_stop")
fn http_stop(fixture: HttpFixture) -> Nil

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "http_refresh")
fn http_refresh(port: Int) -> Bool

fn key(id: String) -> String {
  credentials.key("synthetic-v4", "oauth", id)
}

fn oauth(access: String, expires: Int) -> contracts.AuthMaterial {
  OAuth(
    OAuthData(auth.Credential(access, "synthetic-refresh", expires), [
      #("identity", "synthetic-id"),
    ]),
  )
}

fn store() -> storage.Store {
  let assert Ok(value) = storage.new(directory())
  value
}

fn seed(store: storage.Store, key: String) {
  runtime_store.save(store, key, oauth("synthetic-expired", 0))
  |> should.be_ok
}

fn worker(
  store: storage.Store,
  key: String,
  clock: Clock,
  refresh: contracts.Refresh,
) -> credentials.Worker {
  let assert Ok(value) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { sample(clock) },
    )
  value
}

fn deferred(until: Int) -> runtime_store.RefreshStatus {
  runtime_store.Deferred(until)
}

fn unavailable(
  retry: Int,
) -> Result(contracts.AuthMaterial, contracts.Failure) {
  Error(Failure(CredentialUnavailable, NotSent, Some(retry)))
}

@external(erlang, "mimic_auth_runtime_v4_test_ffi", "fresh_vm_phase")
fn run_fresh_vm_phase(directory: String, restart: Bool) -> Bool

pub fn fresh_vm_preserves_latch_and_deferral_without_reseeding_test() {
  let directory = directory()
  run_fresh_vm_phase(directory, False) |> should.be_true
  run_fresh_vm_phase(directory, True) |> should.be_true
}

/// Two independent OS/BEAM processes use the same private store. The second
/// process never seeds a credential and no callback is permitted to execute.
pub fn fresh_vm_phase(directory: String, restart: Bool) {
  let assert Ok(store) = storage.new(directory)
  let clock = case restart {
    False -> new_clock(100_000, 200_000)
    True -> new_clock(200_000, 0)
  }
  let calls = process.new_subject()
  list.each(["latched", "deferred"], fn(id) {
    let key = key(id)
    case restart {
      False -> seed(store, key)
      True -> Nil
    }
    let worker =
      worker(
        store,
        key,
        clock,
        Refresh(fn(_, _) {
          process.send(calls, Nil)
          case id {
            "latched" -> Error(InvalidGrant)
            _ -> Error(RefreshRateLimited(600_000))
          }
        }),
      )
    case id {
      "latched" -> {
        credentials.acquire(worker)
        |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
        runtime_store.refresh_status(store, key)
        |> should.equal(Ok(runtime_store.NeedsReauthorization))
      }
      _ -> {
        let delay = case restart {
          False -> 600_000
          True -> 500_000
        }
        credentials.acquire(worker) |> should.equal(unavailable(delay))
        runtime_store.refresh_status(store, key)
        |> should.equal(Ok(deferred(700_000)))
      }
    }
    credentials.stop(worker)
  })
  case restart {
    True -> process.receive(calls, 0) |> should.equal(Error(Nil))
    False -> {
      process.receive(calls, 0) |> should.equal(Ok(Nil))
      process.receive(calls, 0) |> should.equal(Ok(Nil))
    }
  }
}

pub fn concurrent_json_429_singleflight_and_completion_epoch_boundary_test() {
  let assert Ok(http) = http_start()
  let store = store()
  let key = key("a")
  seed(store, key)
  let clock = new_clock(100_000, 200_000)
  let started = process.new_subject()
  let refresh =
    Refresh(fn(_, _) {
      http_refresh(http_port(http)) |> should.be_true
      case http_requests(http) {
        1 -> {
          let resume = process.new_subject()
          process.send(started, resume)
          let _ = process.receive_forever(resume)
          set_clock(clock, 101_000, 201_000)
        }
        _ -> Nil
      }
      Error(RefreshRateLimited(9000))
    })
  let worker = worker(store, key, clock, refresh)
  let replies = process.new_subject()
  list.each([1, 2, 3, 4], fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(replies, credentials.get(worker, 999_999_999))
      })
  })
  let assert Ok(resume) = process.receive(started, 1000)
  // The in-flight refresh is already fenced before the callback.
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  process.send(resume, Nil)
  list.each([1, 2, 3, 4], fn(_) {
    process.receive(replies, 1000) |> should.equal(Ok(unavailable(9000)))
  })
  http_requests(http) |> should.equal(1)
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(deferred(110_000)))
  set_clock(clock, 109_999, 209_999)
  credentials.acquire(worker) |> should.equal(unavailable(1))
  set_clock(clock, 110_000, 210_000)
  // Second failure doubles the bounded floor to 10s, above the 9s minimum.
  credentials.acquire(worker) |> should.equal(unavailable(10_000))
  http_requests(http) |> should.equal(2)
  credentials.stop(worker)
  http_stop(http)
}

pub fn forward_wall_jump_cannot_defeat_in_process_monotonic_gate_test() {
  let store = store()
  let key = key("a")
  seed(store, key)
  let clock = new_clock(100_000, 200_000)
  let calls = process.new_subject()
  let worker =
    worker(
      store,
      key,
      clock,
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        Error(RefreshRateLimited(30_000))
      }),
    )
  credentials.acquire(worker) |> should.equal(unavailable(30_000))
  set_clock(clock, 200_000, 200_001)
  credentials.get(worker, 999_999_999) |> should.equal(unavailable(29_999))
  set_clock(clock, 200_000, 230_000)
  credentials.acquire(worker) |> should.equal(unavailable(30_000))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 10) |> should.equal(Error(Nil))
  credentials.stop(worker)
}

pub fn rollback_during_exchange_floors_deadline_and_restart_restores_deferral_test() {
  let store = store()
  let key = key("a")
  seed(store, key)
  let clock = new_clock(100_000, 200_000)
  let calls = process.new_subject()
  let refresh =
    Refresh(fn(_, _) {
      process.send(calls, Nil)
      set_clock(clock, 90_000, 201_000)
      Error(RefreshRateLimited(20_000))
    })
  let first = worker(store, key, clock, refresh)
  credentials.acquire(first) |> should.equal(unavailable(31_000))
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(deferred(121_000)))
  credentials.stop(first)
  // Simulate corrected wall time before the new actor reconstructs its
  // monotonic fence; the conservative persisted deadline still holds.
  set_clock(clock, 110_000, 211_000)
  let restarted = worker(store, key, clock, refresh)
  credentials.acquire(restarted) |> should.equal(unavailable(11_000))
  set_clock(clock, 120_999, 221_999)
  credentials.acquire(restarted) |> should.equal(unavailable(1))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 10) |> should.equal(Error(Nil))
  credentials.stop(restarted)
}

pub fn invalid_grant_and_unsupported_latch_across_restart_and_reads_test() {
  list.each([InvalidGrant, RefreshUnsupported], fn(reason) {
    let store = store()
    let key = key("a")
    seed(store, key)
    let clock = new_clock(100_000, 200_000)
    let calls = process.new_subject()
    let refresh =
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        Error(reason)
      })
    let first = worker(store, key, clock, refresh)
    credentials.acquire(first)
    |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
    runtime_store.load(store, key) |> should.be_ok
    runtime_store.metadata(store, key) |> should.be_ok
    runtime_store.refresh_status(store, key)
    |> should.equal(Ok(runtime_store.NeedsReauthorization))
    credentials.acquire(first)
    |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
    credentials.stop(first)
    let restarted = worker(store, key, clock, refresh)
    credentials.get(restarted, 0)
    |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
    process.receive(calls, 1000) |> should.equal(Ok(Nil))
    process.receive(calls, 10) |> should.equal(Error(Nil))
    // Even identical token bytes are an explicit administrative generation.
    let assert Ok(material) = runtime_store.load(store, key)
    runtime_store.save(store, key, material) |> should.be_ok
    runtime_store.refresh_status(store, key)
    |> should.equal(Ok(runtime_store.Ready))
    credentials.acquire(restarted)
    |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
    process.receive(calls, 1000) |> should.equal(Ok(Nil))
    credentials.stop(restarted)
  })
}

pub fn same_token_save_clears_deferred_gate_and_old_snapshot_cannot_complete_test() {
  let store = store()
  let key = key("a")
  seed(store, key)
  let clock = new_clock(100_000, 200_000)
  let calls = process.new_subject()
  let worker =
    worker(
      store,
      key,
      clock,
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        Error(RefreshRateLimited(100_000))
      }),
    )
  credentials.acquire(worker) |> should.equal(unavailable(100_000))
  let assert Ok(snapshot) = runtime_store.load_record(store, key)
  runtime_store.save_if_unchanged(
    store,
    key,
    runtime_store.record_material(snapshot),
    runtime_store.record_material(snapshot),
  )
  |> should.be_ok
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(deferred(200_000)))
  runtime_store.save(store, key, runtime_store.record_material(snapshot))
  |> should.be_ok
  runtime_store.revision(snapshot)
  |> should.not_equal({
    let assert Ok(fresh) = runtime_store.load_record(store, key)
    runtime_store.revision(fresh)
  })
  runtime_store.transition(
    store,
    key,
    snapshot,
    runtime_store.record_material(snapshot),
    runtime_store.Ready,
  )
  |> should.be_error
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Ready))
  credentials.acquire(worker) |> should.equal(unavailable(100_000))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  credentials.stop(worker)
}

pub fn blocked_callback_loses_to_same_token_save_or_delete_for_terminal_and_429_test() {
  list.each([InvalidGrant, RefreshRateLimited(20_000)], fn(outcome) {
    list.each([False, True], fn(delete) {
      let store = store()
      let key = key("a")
      seed(store, key)
      let clock = new_clock(100_000, 200_000)
      let entered = process.new_subject()
      let replies = process.new_subject()
      let worker =
        worker(
          store,
          key,
          clock,
          Refresh(fn(_, _) {
            let resume = process.new_subject()
            process.send(entered, resume)
            let _ = process.receive_forever(resume)
            Error(outcome)
          }),
        )
      let _ =
        process.spawn_unlinked(fn() {
          process.send(replies, credentials.acquire(worker))
        })
      let assert Ok(resume) = process.receive(entered, 1000)
      let assert Ok(before) = runtime_store.load_record(store, key)
      runtime_store.record_status(before)
      |> should.equal(runtime_store.NeedsReauthorization)
      case delete {
        True -> runtime_store.delete(store, key) |> should.be_ok
        False ->
          runtime_store.save(store, key, runtime_store.record_material(before))
          |> should.be_ok
      }
      process.send(resume, Nil)
      process.receive(replies, 1000)
      |> should.equal(Ok(Error(Failure(Persistence, NotSent, None))))
      case delete {
        True -> {
          let _ = runtime_store.load(store, key) |> should.be_error
          Nil
        }
        False -> {
          runtime_store.load(store, key)
          |> should.equal(Ok(runtime_store.record_material(before)))
          runtime_store.refresh_status(store, key)
          |> should.equal(Ok(runtime_store.Ready))
        }
      }
      credentials.stop(worker)
    })
  })
}

pub fn prearm_failure_skips_callback_and_completion_failure_keeps_restart_fence_test() {
  let store = store()
  let key = key("a")
  seed(store, key)
  let clock = new_clock(100_000, 200_000)
  let called = process.new_subject()
  let refresh =
    Refresh(fn(_, _) {
      process.send(called, Nil)
      block_mutation(store.directory, key)
      Error(RefreshRateLimited(10_000))
    })
  block_mutation(store.directory, key)
  let first = worker(store, key, clock, refresh)
  credentials.acquire(first)
  |> should.equal(Error(Failure(Persistence, NotSent, None)))
  process.receive(called, 10) |> should.equal(Error(Nil))
  unblock_mutation(store.directory, key)
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Ready))
  // Quarantine keeps the same worker from retrying after a failed arm.
  credentials.acquire(first)
  |> should.equal(Error(Failure(Persistence, NotSent, None)))
  credentials.stop(first)
  let second = worker(store, key, clock, refresh)
  credentials.acquire(second)
  |> should.equal(Error(Failure(Persistence, NotSent, None)))
  process.receive(called, 1000) |> should.equal(Ok(Nil))
  unblock_mutation(store.directory, key)
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  credentials.acquire(second)
  |> should.equal(Error(Failure(Persistence, NotSent, None)))
  process.receive(called, 10) |> should.equal(Error(Nil))
  credentials.stop(second)
  let restarted = worker(store, key, clock, refresh)
  credentials.acquire(restarted)
  |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
  process.receive(called, 10) |> should.equal(Error(Nil))
  credentials.stop(restarted)
}

pub fn killed_during_refresh_keeps_recovery_fence_on_restart_test() {
  let store = store()
  let key = key("a")
  seed(store, key)
  let clock = new_clock(100_000, 200_000)
  let entered = process.new_subject()
  let calls = process.new_subject()
  let first =
    worker(
      store,
      key,
      clock,
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        process.send(entered, Nil)
        process.sleep_forever()
        Error(RefreshRetryable)
      }),
    )
  let _ =
    process.spawn_unlinked(fn() {
      let _ = credentials.acquire(first)
      Nil
    })
  process.receive(entered, 1000) |> should.equal(Ok(Nil))
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  credentials.stop(first)
  let restarted =
    worker(
      store,
      key,
      clock,
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        Error(RefreshRetryable)
      }),
    )
  credentials.acquire(restarted)
  |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 10) |> should.equal(Error(Nil))
  credentials.stop(restarted)
}

pub fn panic_and_malformed_success_latch_without_repeating_after_restart_test() {
  list.each([0, 1, 2], fn(scenario) {
    let store = store()
    let key = key("a")
    seed(store, key)
    let clock = new_clock(100_000, 200_000)
    let calls = process.new_subject()
    let refresh =
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        case scenario {
          0 -> panic as "synthetic uncertain exchange"
          1 ->
            Ok(OAuthData(auth.Credential("", "synthetic-refresh", 300_000), []))
          _ -> {
            set_clock(clock, 90_000, 220_000)
            // Wall-clock expiry looks valid, but the monotonic elapsed floor
            // places completion at 120000 and requires expiry > 180000.
            Ok(
              OAuthData(
                auth.Credential("synthetic-new", "synthetic-refresh", 180_000),
                [],
              ),
            )
          }
        }
      })
    let first = worker(store, key, clock, refresh)
    credentials.acquire(first)
    |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
    runtime_store.refresh_status(store, key)
    |> should.equal(Ok(runtime_store.NeedsReauthorization))
    credentials.stop(first)
    let restarted = worker(store, key, clock, refresh)
    credentials.acquire(restarted)
    |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
    process.receive(calls, 1000) |> should.equal(Ok(Nil))
    process.receive(calls, 10) |> should.equal(Error(Nil))
    credentials.stop(restarted)
  })
}

pub fn delay_fallback_unclamped_positive_and_overflow_latch_test() {
  list.each([#(0, 5000), #(1, 5000), #(600_000, 600_000)], fn(pair) {
    let store = store()
    let key = key("a")
    seed(store, key)
    let clock = new_clock(100_000, 200_000)
    let worker =
      worker(
        store,
        key,
        clock,
        Refresh(fn(_, _) { Error(RefreshRateLimited(pair.0)) }),
      )
    credentials.acquire(worker) |> should.equal(unavailable(pair.1))
    runtime_store.refresh_status(store, key)
    |> should.equal(Ok(deferred(100_000 + pair.1)))
    credentials.stop(worker)
  })
  let store = store()
  let key = key("overflow")
  seed(store, key)
  let clock = new_clock(runtime_store.max_timestamp_ms - 1, 100)
  let calls = process.new_subject()
  let worker =
    worker(
      store,
      key,
      clock,
      Refresh(fn(_, _) {
        process.send(calls, Nil)
        Error(RefreshRateLimited(runtime_store.max_timestamp_ms))
      }),
    )
  credentials.acquire(worker)
  |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  credentials.acquire(worker)
  |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 10) |> should.equal(Error(Nil))
  credentials.stop(worker)
}

pub fn negative_delay_and_uncertain_refresh_latch_retryable_uses_fallback_test() {
  list.each(
    [RefreshRateLimited(-1), RefreshUnavailable, RefreshRetryable],
    fn(outcome) {
      let store = store()
      let key = key("a")
      seed(store, key)
      let clock = new_clock(100_000, 200_000)
      let calls = process.new_subject()
      let first =
        worker(
          store,
          key,
          clock,
          Refresh(fn(_, _) {
            process.send(calls, Nil)
            Error(outcome)
          }),
        )
      case outcome {
        RefreshRetryable -> {
          credentials.acquire(first) |> should.equal(unavailable(5000))
          runtime_store.refresh_status(store, key)
          |> should.equal(Ok(deferred(105_000)))
        }
        _ -> {
          credentials.acquire(first)
          |> should.equal(
            Error(Failure(ReauthorizationRequired, NotSent, None)),
          )
          runtime_store.refresh_status(store, key)
          |> should.equal(Ok(runtime_store.NeedsReauthorization))
        }
      }
      process.receive(calls, 1000) |> should.equal(Ok(Nil))
      credentials.stop(first)
      let restarted =
        worker(
          store,
          key,
          clock,
          Refresh(fn(_, _) {
            panic as "synthetic unexpected refresh after restart"
          }),
        )
      case outcome {
        RefreshRetryable ->
          credentials.acquire(restarted) |> should.equal(unavailable(5000))
        _ ->
          credentials.acquire(restarted)
          |> should.equal(
            Error(Failure(ReauthorizationRequired, NotSent, None)),
          )
      }
      credentials.stop(restarted)
    },
  )
}

pub fn invalid_clock_and_monotonic_overflow_fail_closed_test() {
  list.each(
    [
      #(runtime_store.max_timestamp_ms + 1, 0),
      #(-1, 0),
      #(100_000, runtime_store.max_timestamp_ms),
    ],
    fn(pair) {
      let store = store()
      let key = key("a")
      seed(store, key)
      let calls = process.new_subject()
      let worker =
        worker(
          store,
          key,
          new_clock(pair.0, pair.1),
          Refresh(fn(_, _) {
            process.send(calls, Nil)
            Error(RefreshUnavailable)
          }),
        )
      credentials.acquire(worker)
      |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
      case pair.1 == runtime_store.max_timestamp_ms {
        True -> process.receive(calls, 1000) |> should.equal(Ok(Nil))
        False -> process.receive(calls, 10) |> should.equal(Error(Nil))
      }
      runtime_store.refresh_status(store, key)
      |> should.equal(Ok(runtime_store.NeedsReauthorization))
      credentials.stop(worker)
    },
  )
}

pub fn v1_read_is_ready_and_static_policies_never_sample_clock_test() {
  let store = store()
  let key = key("a")
  storage.write_runtime(
    store,
    key,
    "{\"version\":1,\"kind\":\"oauth\",\"access_token\":\"synthetic-v1\",\"refresh_token\":\"synthetic-refresh\",\"expires_at_ms\":0,\"private_metadata\":[]}",
  )
  |> should.be_ok
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Ready))
  let assert Ok(record) = runtime_store.load_record(store, key)
  runtime_store.record_material(record)
  |> should.equal(
    OAuth(
      OAuthData(auth.Credential("synthetic-v1", "synthetic-refresh", 0), []),
    ),
  )
  let static_key = credentials.key("synthetic-v4", "key", "a")
  let static_session = credentials.key("synthetic-v4", "session", "a")
  runtime_store.save(store, static_key, contracts.ApiKey("synthetic-key"))
  |> should.be_ok
  runtime_store.save(
    store,
    static_session,
    contracts.SessionToken("synthetic-session", []),
  )
  |> should.be_ok
  let clock = fn() -> #(Int, Int) { panic as "static policy sampled clock" }
  let assert Ok(a) =
    credentials.start_with_clock(
      store,
      static_key,
      credentials.StaticKey,
      clock,
    )
  let assert Ok(b) =
    credentials.start_with_clock(
      store,
      static_session,
      credentials.StaticSession,
      clock,
    )
  credentials.get(a, -1)
  |> should.equal(Ok(contracts.ApiKey("synthetic-key")))
  credentials.acquire(b)
  |> should.equal(Ok(contracts.SessionToken("synthetic-session", [])))
  credentials.stop(a)
  credentials.stop(b)
}

fn registry() -> registry.Registry {
  let assert Ok(value) =
    registry.new([
      registry.Model(
        "synthetic-v4",
        "model",
        ["oauth"],
        ["test"],
        ["generate"],
        [
          Buffer,
        ],
      ),
    ])
  value
}

fn account(id: String, refresh: contracts.Refresh) -> runtime.Account {
  runtime.Account(
    "synthetic-v4",
    "oauth",
    id,
    "http://127.0.0.1:1",
    fleet.LocalLoopback,
    8,
    ["model"],
    credentials.Refreshable(refresh),
  )
}

fn request(pin: Option(String)) -> contracts.Request {
  Request(
    "synthetic-v4",
    "oauth",
    "model",
    "test",
    "generate",
    Streaming,
    [],
    "synthetic-session",
    pin,
    "{}",
  )
}

fn adapter() -> contracts.Adapter(List(BitArray)) {
  Adapter(
    open: fn(_, _) { Ok(Opened(200, [], [bit_array.from_string("ok")])) },
    next: fn(chunks) {
      case chunks {
        [] -> Ok(None)
        [first, ..rest] -> Ok(Some(#(first, rest)))
      }
    },
    cancel: fn(_) { Nil },
    rejection: fn(_, _) { None },
  )
}

pub fn runtime_failover_for_unpinned_and_typed_pinned_errors_test() {
  let store = store()
  seed(store, key("a"))
  runtime_store.save(
    store,
    key("b"),
    oauth("synthetic-valid", 9_000_000_000_000),
  )
  |> should.be_ok
  let refresh = Refresh(fn(_, _) { Error(InvalidGrant) })
  let assert Ok(running) =
    runtime.start(store, registry(), [
      account("a", refresh),
      account("b", refresh),
    ])
  runtime.execute(running, adapter(), request(Some("a")))
  |> should.equal(Error(Failure(ReauthorizationRequired, NotSent, None)))
  let assert Ok(response) = runtime.execute(running, adapter(), request(None))
  response.account |> should.equal("b")
  runtime.stop(running) |> should.be_ok
  // Only one eligible account: a typed RetryAfter must survive NoAccount.
  let assert Ok(other_store) = storage.new(directory())
  seed(other_store, key("a"))
  let assert Ok(running) =
    runtime.start(other_store, registry(), [
      account("a", Refresh(fn(_, _) { Error(RefreshRateLimited(42_000)) })),
    ])
  let assert Error(Failure(CredentialUnavailable, NotSent, Some(retry))) =
    runtime.execute(running, adapter(), request(None))
  should.be_true(retry >= 42_000)
  runtime.stop(running) |> should.be_ok
}

pub fn runtime_later_uncertain_or_started_failure_beats_earlier_retry_after_test() {
  list.each([contracts.Uncertain, contracts.Started], fn(delivery) {
    let store = store()
    seed(store, key("a"))
    runtime_store.save(
      store,
      key("b"),
      oauth("synthetic-valid", 9_000_000_000_000),
    )
    |> should.be_ok
    let refresh = Refresh(fn(_, _) { Error(RefreshRateLimited(1000)) })
    let assert Ok(running) =
      runtime.start(store, registry(), [
        account("a", refresh),
        account("b", refresh),
      ])
    let base = adapter()
    let terminal =
      Adapter(..base, open: fn(context: contracts.Context, request) {
        case context.account {
          "b" -> Error(Failure(contracts.Unavailable, delivery, Some(2000)))
          _ -> base.open(context, request)
        }
      })
    runtime.execute(running, terminal, request(None))
    |> should.equal(Error(Failure(contracts.Unavailable, delivery, Some(2000))))
    runtime.stop(running) |> should.be_ok
  })
}
