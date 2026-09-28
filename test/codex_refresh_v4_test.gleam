import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/providers/codex/adapter
import mimic/providers/codex/json_guard
import mimic/providers/codex/oauth
import mimic/providers/contracts
import mimic/types.{Header, WireResponse}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

fn old() {
  contracts.OAuthData(auth.Credential("synthetic-old", "synthetic-refresh", 1), [
    #("chatgpt_account_id", "synthetic-account"),
  ])
}

fn config() {
  oauth.Config(
    "http://127.0.0.1:1455/authorize",
    "http://127.0.0.1:1455/token",
    "http://127.0.0.1:1455/callback",
  )
}

pub fn codex_v4_refresh_classification_requires_structured_rejection_test() {
  let rate =
    "{\"error\":{\"code\":\"rate_limit_exceeded\",\"type\":\"rate_limit_error\"}}"
  list.each(
    [
      #(
        WireResponse(429, [Header("Retry-After", "3600")], rate, 0),
        contracts.RefreshRateLimited(3_600_000),
      ),
      #(WireResponse(429, [], rate, 0), contracts.RefreshRateLimited(0)),
      #(
        WireResponse(429, [Header("Retry-After", "-1")], rate, 0),
        contracts.RefreshUnavailable,
      ),
      #(
        WireResponse(
          429,
          [Header("Retry-After", "5"), Header("retry-after", "7")],
          rate,
          0,
        ),
        contracts.RefreshUnavailable,
      ),
      #(
        WireResponse(429, [], "unrecognized body", 0),
        contracts.RefreshUnavailable,
      ),
      #(WireResponse(503, [], rate, 0), contracts.RefreshUnavailable),
      #(WireResponse(200, [], rate, 0), contracts.RefreshUnavailable),
      #(
        WireResponse(
          200,
          [],
          "{\"access_token\":\"synthetic-maybe-rotated\"}",
          0,
        ),
        contracts.RefreshUnavailable,
      ),
      #(
        WireResponse(400, [], "{\"error\":\"invalid_grant\"}", 0),
        contracts.InvalidGrant,
      ),
    ],
    fn(example) {
      let contracts.Refresh(refresh) =
        adapter.refresh(config(), fn(_) { Ok(example.0) })
      refresh(old(), 100_000) |> should.equal(Error(example.1))
    },
  )
  let contracts.Refresh(safe) =
    adapter.refresh(config(), fn(_) {
      // Mock transport affirmatively reports it sent zero bytes.
      Error(contracts.RefreshRetryable)
    })
  safe(old(), 100_000) |> should.equal(Error(contracts.RefreshRetryable))
}

pub fn codex_v4_unknown_rotation_fence_survives_worker_restart_and_reads_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("codex", "oauth", "synthetic-account")
  runtime_store.save(store, key, contracts.OAuth(old())) |> should.be_ok
  let calls = process.new_subject()
  let refresh =
    adapter.refresh(config(), fn(_) {
      process.send(calls, Nil)
      // Could conceal upstream rotation: never proven safe to repeat.
      Ok(WireResponse(
        200,
        [],
        "{\"access_token\":\"synthetic-new\",\"refresh_token\":\"synthetic-stale\",\"refresh_token\":\"synthetic-rotated\",\"expires_in\":3600}",
        0,
      ))
    })
  let assert Ok(worker) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { #(100_000, 0) },
    )
  credentials.acquire(worker) |> should.be_error
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  runtime_store.metadata(store, key) |> should.be_ok
  runtime_store.load(store, key) |> should.equal(Ok(contracts.OAuth(old())))
  credentials.acquire(worker) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  credentials.stop(worker)
  let assert Ok(restarted) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { #(200_000, 100_000) },
    )
  credentials.acquire(restarted) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  // Explicit operator save, even same bytes, is the recovery action.
  runtime_store.save(store, key, contracts.OAuth(old())) |> should.be_ok
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Ready))
  credentials.acquire(restarted) |> should.be_error
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  credentials.stop(restarted)
}

pub fn codex_v4_contradictory_rate_limit_bodies_cannot_authorize_retry_test() {
  list.each(
    [
      "{\"error\":{\"code\":\"rate_limit_exceeded\",\"type\":\"server_error\"}}",
      "{\"error\":{\"code\":\"unknown\",\"type\":\"rate_limit_error\"}}",
      "{\"error\":{\"type\":\"rate_limit_error\"},\"access_token\":\"synthetic-maybe-rotated\"}",
      "{\"error\":{\"code\":\"rate_limit_exceeded\"},\"refresh_token\":\"synthetic-maybe-rotated\"}",
      "{\"error\":{\"code\":\"rate_limit_exceeded\"},\"id_token\":\"synthetic-maybe-rotated\"}",
      "{\"error\":{\"code\":\"rate_limit_exceeded\"},\"expires_in\":3600}",
    ],
    fn(body) {
      let contracts.Refresh(refresh) =
        adapter.refresh(config(), fn(_) {
          Ok(WireResponse(429, [Header("Retry-After", "60")], body, 0))
        })
      refresh(old(), 100_000)
      |> should.equal(Error(contracts.RefreshUnavailable))
    },
  )
}

pub fn codex_v4_duplicate_keys_never_authorize_safe_refresh_retry_test() {
  list.each(
    [
      "{\"error\":{\"code\":\"rate_limit_exceeded\"},\"error\":{\"code\":\"server_error\"}}",
      "{\"error\":{\"code\":\"rate_limit_exceeded\",\"code\":\"server_error\"}}",
      "{\"\\u0065rror\":{\"code\":\"rate_limit_exceeded\"},\"error\":{\"code\":\"server_error\"}}",
      "{\"error\":{\"\\u0063ode\":\"rate_limit_exceeded\",\"code\":\"server_error\"}}",
      "{\"error\":{\"code\":\"rate_limit_exceeded\"},\"extension\":[{\"a\":1,\"a\":2}]}",
    ],
    fn(body) {
      let contracts.Refresh(refresh) =
        adapter.refresh(config(), fn(_) {
          Ok(WireResponse(429, [Header("Retry-After", "60")], body, 0))
        })
      refresh(old(), 100_000)
      |> should.equal(Error(contracts.RefreshUnavailable))
    },
  )
  json_guard.parse(
    "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"brace } and quote \\\" : are not keys\"},\"extension\":[{\"a\":1},{\"a\":2}]}",
  )
  |> should.be_ok
  let contracts.Refresh(duplicate_token) =
    adapter.refresh(config(), fn(_) {
      Ok(WireResponse(
        200,
        [],
        "{\"access_token\":\"synthetic-first\",\"access_token\":\"synthetic-second\",\"expires_in\":3600}",
        0,
      ))
    })
  duplicate_token(old(), 100_000)
  |> should.equal(Error(contracts.RefreshUnavailable))
  let contracts.Refresh(duplicate_rotation) =
    adapter.refresh(config(), fn(_) {
      Ok(WireResponse(
        200,
        [],
        "{\"access_token\":\"synthetic-new\",\"refresh_token\":\"synthetic-stale\",\"refresh_token\":\"synthetic-rotated\",\"expires_in\":3600}",
        0,
      ))
    })
  duplicate_rotation(old(), 100_000)
  |> should.equal(Error(contracts.RefreshUnavailable))
}

pub fn codex_v4_recognized_rate_limit_persists_large_delay_without_repeat_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("codex", "oauth", "synthetic-rate-account")
  runtime_store.save(store, key, contracts.OAuth(old())) |> should.be_ok
  let calls = process.new_subject()
  let refresh =
    adapter.refresh(config(), fn(_) {
      process.send(calls, Nil)
      Ok(WireResponse(
        429,
        [Header("Retry-After", "3600")],
        "{\"error\":{\"code\":\"rate_limit_exceeded\"}}",
        0,
      ))
    })
  let assert Ok(worker) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { #(100_000, 0) },
    )
  credentials.acquire(worker) |> should.be_error
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Deferred(3_700_000)))
  credentials.acquire(worker) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  credentials.stop(worker)
  let assert Ok(restarted) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { #(200_000, 0) },
    )
  credentials.acquire(restarted) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Deferred(3_700_000)))
  credentials.stop(restarted)
}

pub fn codex_v4_rotated_refresh_commits_minimal_identity_and_ready_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("codex", "oauth", "synthetic-rotated-account")
  runtime_store.save(store, key, contracts.OAuth(old())) |> should.be_ok
  let refresh =
    adapter.refresh(config(), fn(_) {
      Ok(WireResponse(
        200,
        [],
        "{\"access_token\":\"synthetic-new\",\"refresh_token\":\"synthetic-rotated\",\"expires_in\":3600}",
        0,
      ))
    })
  let assert Ok(worker) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { #(100_000, 0) },
    )
  let assert Ok(contracts.OAuth(updated)) = credentials.acquire(worker)
  updated.credential.refresh_token |> should.equal("synthetic-rotated")
  updated.private_metadata |> should.equal(old().private_metadata)
  runtime_store.load(store, key) |> should.equal(Ok(contracts.OAuth(updated)))
  runtime_store.refresh_status(store, key)
  |> should.equal(Ok(runtime_store.Ready))
  let assert Ok(metadata) = runtime_store.metadata(store, key)
  metadata.expires_at_ms |> should.equal(Some(3_700_000))
  credentials.stop(worker)
}
