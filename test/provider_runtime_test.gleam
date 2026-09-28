import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/providers/contracts.{
  Adapter, ApiKey, Buffer, Context, Continuation, Failure, InvalidConfiguration,
  NoAccount, NotSent, OAuth, OAuthData, Opened, Quota, Refresh,
  RefreshUnsupported, Rejected, Request, Started, Stream, Streaming, Unavailable,
  Uncertain, Unsupported, WebSocket,
}
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{Header}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int

fn model_registry() -> registry.Registry {
  let assert Ok(value) =
    registry.new([
      registry.Model(
        "synthetic",
        "model",
        ["key", "oauth"],
        ["test"],
        ["generate"],
        [Buffer, Stream, Continuation],
      ),
    ])
  value
}

fn account(
  id: String,
  mode: String,
  policy: credentials.Policy,
) -> runtime.Account {
  runtime.Account(
    "synthetic",
    mode,
    id,
    "http://127.0.0.1:1",
    fleet.LocalLoopback,
    8,
    ["model"],
    policy,
  )
}

fn request() -> contracts.Request {
  Request(
    "synthetic",
    "key",
    "model",
    "test",
    "generate",
    Streaming,
    [],
    "session",
    None,
    "{}",
  )
}

fn store_with_keys() -> storage.Store {
  let assert Ok(store) = storage.new(directory())
  list.each(["a", "b"], fn(id) {
    credentials.save_api_key(
      store,
      credentials.key("synthetic", "key", id),
      "synthetic-" <> id,
    )
    |> should.be_ok
  })
  store
}

fn start(store: storage.Store) -> runtime.Runtime {
  let assert Ok(value) =
    runtime.start(store, model_registry(), [
      account("a", "key", credentials.StaticKey),
      account("b", "key", credentials.StaticKey),
    ])
  value
}

fn mock(
  events: process.Subject(contracts.Context),
) -> contracts.Adapter(List(BitArray)) {
  Adapter(
    open: fn(context, _) {
      process.send(events, context)
      Ok(
        Opened(200, [Header("X-Case", "a"), Header("x-case", "b")], [
          bit_array.from_string("ok"),
        ]),
      )
    },
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

pub fn registry_rejects_unknown_capabilities_before_acquisition_test() {
  let events = process.new_subject()
  let runtime = start(store_with_keys())
  let req = Request(..request(), required: [WebSocket])
  runtime.open(runtime, mock(events), req)
  |> should.equal(Error(Failure(Unsupported, NotSent, None)))
  runtime.open(
    runtime,
    mock(events),
    Request(..request(), auth_mode: "unknown"),
  )
  |> should.be_error
  runtime.open(
    runtime,
    mock(events),
    Request(..request(), required: [Continuation]),
  )
  |> should.be_error
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  process.receive(events, 10) |> should.equal(Error(Nil))
  runtime.stop(runtime) |> should.be_ok
}

pub fn selection_sessions_and_ordered_headers_test() {
  let events = process.new_subject()
  let runtime = start(store_with_keys())
  let assert Ok(first) = runtime.execute(runtime, mock(events), request())
  first.account |> should.equal("a")
  first.headers |> should.equal([Header("X-Case", "a"), Header("x-case", "b")])
  first.body |> should.equal(bit_array.from_string("ok"))
  let assert Ok(a) = process.receive(events, 1000)
  a.credential |> should.equal(ApiKey("synthetic-a"))
  let assert Ok(second) =
    runtime.execute(
      runtime,
      mock(events),
      Request(..request(), session: "other"),
    )
  second.account |> should.equal("b")
  let assert Ok(b) = process.receive(events, 1000)
  b.credential |> should.equal(ApiKey("synthetic-b"))
  should.be_false(a.session_key == b.session_key)
  let assert Ok(again) = runtime.execute(runtime, mock(events), request())
  again.account |> should.equal("a")
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
}

pub fn quota_failover_is_bounded_and_survives_restart_test() {
  let events = process.new_subject()
  let store = store_with_keys()
  let runtime = start(store)
  let base = mock(events)
  let adapter =
    Adapter(
      ..base,
      open: fn(context, request) {
        let assert Ok(opened) = base.open(context, request)
        case context.account {
          "a" ->
            Ok(
              Opened(..opened, status: 429, headers: [
                Header("Retry-After", "120"),
              ]),
            )
          _ -> Ok(opened)
        }
      },
      rejection: fn(status, _) {
        case status {
          429 -> Some(Failure(Quota, Rejected, Some(120_000)))
          _ -> None
        }
      },
    )
  let assert Ok(response) = runtime.execute(runtime, adapter, request())
  response.account |> should.equal("b")
  let assert Ok(a) = process.receive(events, 1000)
  let assert Ok(b) = process.receive(events, 1000)
  a.account |> should.equal("a")
  b.account |> should.equal("b")
  should.be_false(a.session_key == b.session_key)
  runtime.stop(runtime) |> should.be_ok
  let restarted = start(store)
  let assert Ok(response) = runtime.execute(restarted, mock(events), request())
  response.account |> should.equal("b")
  runtime.execute(
    restarted,
    mock(events),
    Request(..request(), pinned_account: Some("a")),
  )
  |> should.equal(Error(Failure(NoAccount, NotSent, None)))
  runtime.stop(restarted) |> should.be_ok
}

pub fn uncertain_send_and_started_stream_never_replay_test() {
  let events = process.new_subject()
  let runtime = start(store_with_keys())
  let base = mock(events)
  let uncertain =
    Adapter(..base, open: fn(context, req) {
      let _ = base.open(context, req)
      Error(Failure(Unavailable, Uncertain, None))
    })
  runtime.open(runtime, uncertain, request())
  |> should.equal(Error(Failure(Unavailable, Uncertain, None)))
  process.receive(events, 1000) |> should.be_ok
  process.receive(events, 10) |> should.equal(Error(Nil))
  let adapter =
    Adapter(..base, next: fn(_) { Error(Failure(Unavailable, NotSent, None)) })
  let assert Ok(response) = runtime.open(runtime, adapter, request())
  runtime.next(response.stream)
  |> should.equal(Error(Failure(Unavailable, Started, None)))
  process.receive(events, 1000) |> should.be_ok
  process.receive(events, 10) |> should.equal(Error(Nil))
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
}

pub fn cancellation_and_callback_panic_release_once_test() {
  let events = process.new_subject()
  let closed = process.new_subject()
  let runtime = start(store_with_keys())
  let base = mock(events)
  let adapter = Adapter(..base, cancel: fn(_) { process.send(closed, Nil) })
  let assert Ok(response) = runtime.open(runtime, adapter, request())
  runtime.active_leases(runtime) |> should.equal(Ok(1))
  runtime.cancel(response.stream)
  runtime.cancel(response.stream)
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  process.receive(closed, 10) |> should.equal(Error(Nil))
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  let panics =
    Adapter(..base, cancel: fn(_) {
      process.send(closed, Nil)
      panic as "synthetic callback exception must not be logged"
    })
  let assert Ok(response) = runtime.open(runtime, panics, request())
  runtime.cancel(response.stream)
  process.receive(closed, 1000) |> should.equal(Ok(Nil))
  // A coordinator barrier follows the worker monitor notification.
  wait_for_cleanup(runtime, 50)
  runtime.stop(runtime) |> should.be_ok
}

fn wait_for_cleanup(runtime: runtime.Runtime, attempts: Int) {
  case runtime.active_leases(runtime), attempts {
    Ok(0), _ -> Nil
    _, 0 -> panic as "lease was not released"
    _, _ -> {
      process.sleep(5)
      wait_for_cleanup(runtime, attempts - 1)
    }
  }
}

pub fn caller_death_releases_lease_test() {
  let events = process.new_subject()
  let ready = process.new_subject()
  let runtime = start(store_with_keys())
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(_) = runtime.open(runtime, mock(events), request())
      process.send(ready, Nil)
      process.sleep_forever()
    })
  process.receive(ready, 1000) |> should.equal(Ok(Nil))
  runtime.active_leases(runtime) |> should.equal(Ok(1))
  process.kill(owner)
  wait_for_cleanup(runtime, 50)
  runtime.stop(runtime) |> should.be_ok
}

pub fn expired_token_request_path_singleflight_and_metadata_restart_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic", "oauth", "a")
  runtime_store.save(
    store,
    key,
    OAuth(
      OAuthData(auth.Credential("expired", "refresh", 0), [
        #("chatgpt_account_id", "synthetic-provider-id"),
      ]),
    ),
  )
  |> should.be_ok
  let refreshed = process.new_subject()
  let events = process.new_subject()
  let refresh =
    Refresh(fn(old, now) {
      process.send(refreshed, Nil)
      old.credential.refresh_token |> should.equal("refresh")
      process.sleep(20)
      Ok(
        OAuthData(
          auth.Credential("new-access", "rotated-refresh", now + 3_600_000),
          [],
        ),
      )
    })
  let accounts = [account("a", "oauth", credentials.Refreshable(refresh))]
  let assert Ok(runtime) = runtime.start(store, model_registry(), accounts)
  let replies = process.new_subject()
  list.each([1, 2, 3, 4], fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(
          replies,
          runtime.execute(
            runtime,
            mock(events),
            Request(..request(), auth_mode: "oauth"),
          ),
        )
      })
  })
  list.each([1, 2, 3, 4], fn(_) {
    let assert Ok(Ok(_)) = process.receive(replies, 2000)
    let assert Ok(Context(credential: OAuth(data), ..)) =
      process.receive(events, 1000)
    data.credential.access_token |> should.equal("new-access")
    data.private_metadata
    |> should.equal([#("chatgpt_account_id", "synthetic-provider-id")])
  })
  process.receive(refreshed, 1000) |> should.equal(Ok(Nil))
  process.receive(refreshed, 10) |> should.equal(Error(Nil))
  let assert Ok(OAuth(saved)) = runtime_store.load(store, key)
  saved.credential.refresh_token |> should.equal("rotated-refresh")
  runtime.stop(runtime) |> should.be_ok
  let assert Ok(restarted) = runtime.start(store, model_registry(), accounts)
  runtime.execute(
    restarted,
    mock(events),
    Request(..request(), auth_mode: "oauth"),
  )
  |> should.be_ok
  process.receive(refreshed, 10) |> should.equal(Error(Nil))
  runtime.stop(restarted) |> should.be_ok
}

pub fn mixed_store_and_material_mismatch_fail_before_adapter_test() {
  let store = store_with_keys()
  auth.save(
    store,
    "legacy",
    auth.Credential("legacy-access", "legacy-refresh", 123),
  )
  |> should.be_ok
  let key = credentials.key("synthetic", "oauth", "c")
  runtime_store.save(
    store,
    key,
    OAuth(
      OAuthData(auth.Credential("oauth", "refresh", now_ms() + 3_600_000), []),
    ),
  )
  |> should.be_ok
  auth.list_metadata(store)
  |> should.equal(Ok([auth.CredentialMetadata("legacy", 123)]))
  let assert Ok(runtime) =
    runtime.start(store, model_registry(), [
      account("c", "oauth", credentials.StaticKey),
      account(
        "a",
        "key",
        credentials.Refreshable(Refresh(fn(_, _) { Error(RefreshUnsupported) })),
      ),
    ])
  let events = process.new_subject()
  runtime.open(runtime, mock(events), Request(..request(), auth_mode: "oauth"))
  |> should.be_error
  runtime.open(runtime, mock(events), request()) |> should.be_error
  process.receive(events, 10) |> should.equal(Error(Nil))
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
}

pub fn duplicate_store_owner_and_egress_defaults_test() {
  let store = store_with_keys()
  let runtime = start(store)
  runtime.start(store, model_registry(), [
    account("a", "key", credentials.StaticKey),
  ])
  |> should.equal(Error(Failure(InvalidConfiguration, NotSent, None)))
  fleet.validate(fleet.Profile(
    "a",
    "https://operator.example",
    fleet.LocalLoopback,
    1,
  ))
  |> should.be_error
  fleet.validate(fleet.Profile(
    "a",
    "https://operator.example",
    fleet.OperatorHttps,
    1,
  ))
  |> should.be_ok
  fleet.validate(fleet.Profile(
    "a",
    "https://operator.example/path",
    fleet.OperatorHttps,
    1,
  ))
  |> should.be_error
  fleet.validate(fleet.Profile(
    "a",
    "http://operator.example",
    fleet.OperatorHttps,
    1,
  ))
  |> should.be_error
  runtime.stop(runtime) |> should.be_ok
}

@external(erlang, "mimic_provider_runtime_test_ffi", "second_vm_rejected")
fn second_vm_rejected(directory: String) -> Bool

@external(erlang, "mimic_provider_runtime_test_ffi", "stale_guard")
fn stale_guard(directory: String) -> Nil

@external(erlang, "mimic_provider_runtime_test_ffi", "chmod")
fn chmod(directory: String, mode: Int) -> Nil

pub fn ownership_rejects_second_vm_alias_and_stale_guard_test() {
  let store = store_with_keys()
  let owner = start(store)
  second_vm_rejected(store.directory) |> should.be_true
  let assert Ok(alias) = storage.new(store.directory <> "/.")
  runtime.start(alias, model_registry(), [
    account("a", "key", credentials.StaticKey),
  ])
  |> should.be_error
  runtime.stop(owner) |> should.be_ok
  second_vm_rejected(store.directory) |> should.be_false
  // No PID guesses or automatic deletion of an abandoned guard.
  stale_guard(store.directory)
  runtime.start(store, model_registry(), [
    account("a", "key", credentials.StaticKey),
  ])
  |> should.be_error
  second_vm_rejected(store.directory) |> should.be_true
}

pub fn changed_private_identity_never_activates_rotated_token_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic", "oauth", "a")
  let original =
    OAuth(
      OAuthData(auth.Credential("old", "refresh", 0), [
        #("chatgpt_account_id", "original"),
      ]),
    )
  runtime_store.save(store, key, original) |> should.be_ok
  let refresh =
    Refresh(fn(_, now) {
      Ok(
        OAuthData(auth.Credential("new", "rotated", now + 3_600_000), [
          #("chatgpt_account_id", "different"),
        ]),
      )
    })
  let assert Ok(worker) =
    credentials.start(store, key, credentials.Refreshable(refresh))
  credentials.get(worker, now_ms()) |> should.be_error
  runtime_store.load(store, key) |> should.equal(Ok(original))
  credentials.stop(worker)
}

pub fn failed_refresh_persistence_never_returns_new_token_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic", "oauth", "a")
  let original = OAuth(OAuthData(auth.Credential("old", "refresh", 0), []))
  runtime_store.save(store, key, original) |> should.be_ok
  let refresh =
    Refresh(fn(_, now) {
      chmod(store.directory, 320)
      Ok(OAuthData(auth.Credential("new", "rotated", now + 3_600_000), []))
    })
  let assert Ok(worker) =
    credentials.start(store, key, credentials.Refreshable(refresh))
  credentials.get(worker, now_ms())
  |> should.equal(Error(Failure(contracts.Persistence, NotSent, None)))
  chmod(store.directory, 448)
  runtime_store.load(store, key) |> should.equal(Ok(original))
  credentials.stop(worker)
}

pub fn stream_adoption_revokes_old_owner_and_survives_its_death_test() {
  let runtime = start(store_with_keys())
  let events = process.new_subject()
  let ready = process.new_subject()
  let checked = process.new_subject()
  let old_owner =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      let assert Ok(response) = runtime.open(runtime, mock(events), request())
      process.send(ready, #(response.stream, commands))
      let _ = process.receive_forever(commands)
      runtime.next(response.stream) |> should.be_error
      runtime.adopt(response.stream) |> should.be_error
      runtime.cancel(response.stream)
      process.send(checked, Nil)
      process.sleep_forever()
    })
  let assert Ok(#(stream, commands)) = process.receive(ready, 1000)
  runtime.adopt(stream) |> should.be_ok
  process.send(commands, Nil)
  process.receive(checked, 1000) |> should.equal(Ok(Nil))
  process.kill(old_owner)
  runtime.next(stream) |> should.equal(Ok(Some(bit_array.from_string("ok"))))
  runtime.cancel(stream)
  wait_for_cleanup(runtime, 50)
  runtime.stop(runtime) |> should.be_ok
}

pub fn adopted_owner_death_releases_stream_test() {
  let runtime = start(store_with_keys())
  let events = process.new_subject()
  let ready = process.new_subject()
  let assert Ok(response) = runtime.open(runtime, mock(events), request())
  let owner =
    process.spawn_unlinked(fn() {
      process.send(ready, runtime.adopt(response.stream))
      process.sleep_forever()
    })
  process.receive(ready, 1000) |> should.equal(Ok(Ok(Nil)))
  runtime.next(response.stream) |> should.be_error
  process.kill(owner)
  wait_for_cleanup(runtime, 50)
  runtime.adopt(response.stream) |> should.be_error
  runtime.stop(runtime) |> should.be_ok
}

pub fn cancelled_and_dead_owner_streams_cannot_be_adopted_test() {
  let runtime = start(store_with_keys())
  let events = process.new_subject()
  let closed = process.new_subject()
  let base = mock(events)
  let adapter = Adapter(..base, cancel: fn(_) { process.send(closed, Nil) })
  list.each([1, 2, 3, 4, 5], fn(_) {
    let assert Ok(response) = runtime.open(runtime, adapter, request())
    let race = process.new_subject()
    let _ =
      process.spawn_unlinked(fn() {
        process.send(race, runtime.adopt(response.stream))
        runtime.cancel(response.stream)
      })
    runtime.cancel(response.stream)
    let _ = process.receive(race, 1000) |> should.be_ok
    wait_for_cleanup(runtime, 50)
  })
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(response) = runtime.open(runtime, adapter, request())
      process.send(ready, response.stream)
      process.sleep_forever()
    })
  let assert Ok(stream) = process.receive(ready, 1000)
  let monitor = process.monitor(owner)
  process.kill(owner)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  runtime.adopt(stream) |> should.be_error
  wait_for_cleanup(runtime, 50)
  // Forced owner death may close via socket ownership rather than callback,
  // but no callback can run more than once for any completed request.
  should.be_true(drain_count(closed, 0) <= 6)
  runtime.stop(runtime) |> should.be_ok
}

fn drain_count(subject: process.Subject(Nil), count: Int) -> Int {
  case process.receive(subject, 0) {
    Ok(_) -> drain_count(subject, count + 1)
    Error(_) -> count
  }
}

pub fn concurrent_admin_replacement_and_deletion_win_over_refresh_test() {
  list.each([False, True], fn(delete) {
    let assert Ok(store) = storage.new(directory())
    let key = credentials.key("synthetic", "oauth", "a")
    let original = OAuth(OAuthData(auth.Credential("old", "refresh", 0), []))
    let replacement =
      OAuth(
        OAuthData(
          auth.Credential("admin-new", "admin-refresh", now_ms() + 3_600_000),
          [#("identity", "new")],
        ),
      )
    runtime_store.save(store, key, original) |> should.be_ok
    let refreshing = process.new_subject()
    let replies = process.new_subject()
    let refresh =
      Refresh(fn(_, now) {
        let resume = process.new_subject()
        process.send(refreshing, resume)
        let _ = process.receive_forever(resume)
        Ok(
          OAuthData(
            auth.Credential("stale-result", "stale-refresh", now + 3_600_000),
            [],
          ),
        )
      })
    let assert Ok(worker) =
      credentials.start(store, key, credentials.Refreshable(refresh))
    let _ =
      process.spawn_unlinked(fn() {
        process.send(replies, credentials.get(worker, now_ms()))
      })
    let assert Ok(resume) = process.receive(refreshing, 1000)
    case delete {
      True -> runtime_store.delete(store, key) |> should.be_ok
      False -> runtime_store.save(store, key, replacement) |> should.be_ok
    }
    process.send(resume, Nil)
    let assert Ok(Error(_)) = process.receive(replies, 1000)
    case delete {
      True -> {
        let _ = runtime_store.load(store, key) |> should.be_error
        Nil
      }
      False -> runtime_store.load(store, key) |> should.equal(Ok(replacement))
    }
    credentials.stop(worker)
  })
}

@external(erlang, "mimic_provider_runtime_test_ffi", "persistence_phase")
fn run_persistence_phase(directory: String, restart: Bool) -> Bool

pub fn fresh_vm_restores_rotated_credentials_identity_and_cooldown_test() {
  let path = directory()
  run_persistence_phase(path, False) |> should.be_true
  run_persistence_phase(path, True) |> should.be_true
}

@external(erlang, "mimic_provider_runtime_test_ffi", "killed_mutator_cleanup")
fn killed_mutator_cleanup(directory: String) -> Bool

pub fn stopping_mutation_caller_cannot_strand_credential_guard_test() {
  killed_mutator_cleanup(directory()) |> should.be_true
}

/// Invoked in two independent BEAM VMs by the test primitive, never reseeded on
/// restart. This proves runtime state restoration, not assembled ingress parity.
pub fn persistence_phase(path: String, restart: Bool) {
  let assert Ok(store) = storage.new(path)
  case restart {
    True -> Nil
    False ->
      list.each(["a", "b"], fn(id) {
        runtime_store.save(
          store,
          credentials.key("synthetic", "oauth", id),
          OAuth(
            OAuthData(auth.Credential("expired", "refresh", 0), [
              #("identity", id),
            ]),
          ),
        )
        |> should.be_ok
      })
  }
  let refreshed = process.new_subject()
  let events = process.new_subject()
  let refresh =
    Refresh(fn(old, now) {
      process.send(refreshed, Nil)
      Ok(OAuthData(
        auth.Credential("rotated", "rotated-refresh", now + 3_600_000),
        old.private_metadata,
      ))
    })
  let assert Ok(runtime) =
    runtime.start(store, model_registry(), [
      account("a", "oauth", credentials.Refreshable(refresh)),
      account("b", "oauth", credentials.Refreshable(refresh)),
    ])
  let base = mock(events)
  let adapter =
    Adapter(
      ..base,
      open: fn(context, req) {
        let assert Ok(opened) = base.open(context, req)
        case context.account {
          "a" ->
            Ok(
              Opened(..opened, status: 429, headers: [
                Header("Retry-After", "120"),
              ]),
            )
          _ -> Ok(opened)
        }
      },
      rejection: fn(status, _) {
        case status {
          429 -> Some(Failure(Quota, Rejected, Some(120_000)))
          _ -> None
        }
      },
    )
  let assert Ok(response) =
    runtime.execute(runtime, adapter, Request(..request(), auth_mode: "oauth"))
  response.account |> should.equal("b")
  let expected = case restart {
    True -> 0
    False -> 2
  }
  drain_count(refreshed, 0) |> should.equal(expected)
  let assert Ok(OAuth(saved)) =
    runtime_store.load(store, credentials.key("synthetic", "oauth", "b"))
  saved.credential.access_token |> should.equal("rotated")
  saved.private_metadata |> should.equal([#("identity", "b")])
  runtime.stop(runtime) |> should.be_ok
}
