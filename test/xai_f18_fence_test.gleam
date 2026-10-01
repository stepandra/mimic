/// Actual selected-store revision tests with synthetic credentials only.
import gleam/list
import gleam/option.{None}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/providers/contracts as c
import mimic/providers/xai_websocket/fence

type Switch

type Clock

@external(erlang, "mimic_xai_f18_test_ffi", "new_switch")
fn new_switch() -> Switch

@external(erlang, "mimic_xai_f18_test_ffi", "allowed")
fn allowed(switch: Switch) -> Bool

@external(erlang, "mimic_xai_f18_test_ffi", "revoke")
fn revoke(switch: Switch) -> Nil

@external(erlang, "mimic_xai_f18_test_ffi", "new_clock")
fn new_clock(value: Int) -> Clock

@external(erlang, "mimic_xai_f18_test_ffi", "clock_now")
fn clock_now(clock: Clock) -> Int

@external(erlang, "mimic_xai_f18_test_ffi", "set_clock")
fn set_clock(clock: Clock, value: Int) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int

fn context(mode: String) {
  c.Context(
    "xai",
    mode,
    "synthetic-account",
    "https://api.x.ai",
    "synthetic-opaque-session",
    case mode {
      "api_key" -> c.ApiKey("synthetic-f18-key")
      _ ->
        c.OAuth(
          c.OAuthData(
            auth.Credential(
              "synthetic-f18-access",
              "synthetic-f18-refresh",
              now_ms() + 60_000,
            ),
            [#("token_endpoint", "https://auth.x.ai/token")],
          ),
        )
    },
  )
}

pub fn same_value_replacement_is_not_the_same_authoritative_revision_test() {
  list.each(["api_key", "oauth"], fn(mode) {
    let assert Ok(store) = storage.new(directory())
    let ctx = context(mode)
    let key = credentials.key("xai", mode, ctx.account)
    runtime_store.save(store, key, ctx.credential) |> should.be_ok
    let assert Ok(bound) = fence.bind(store, ctx, fn() { True })
    fence.check(bound) |> should.be_ok
    runtime_store.save(store, key, ctx.credential) |> should.be_ok
    fence.check(bound)
    |> should.equal(Error(c.Failure(c.CredentialUnavailable, c.Started, None)))
  })
}

pub fn selected_material_race_delete_and_blocked_refresh_status_fail_closed_test() {
  let ctx = context("oauth")
  list.each(["replace", "delete", "unknown"], fn(mutation) {
    let assert Ok(store) = storage.new(directory())
    let key = credentials.key("xai", ctx.auth_mode, ctx.account)
    runtime_store.save(store, key, ctx.credential) |> should.be_ok
    let assert Ok(bound) = fence.bind(store, ctx, fn() { True })
    case mutation {
      "delete" -> runtime_store.delete(store, key) |> should.be_ok
      "unknown" -> {
        let assert Ok(record) = runtime_store.load_record(store, key)
        runtime_store.transition(
          store,
          key,
          record,
          ctx.credential,
          runtime_store.NeedsReauthorization,
        )
        |> should.be_ok
        Nil
      }
      _ -> {
        let assert c.OAuth(data) = ctx.credential
        runtime_store.save(
          store,
          key,
          c.OAuth(
            c.OAuthData(
              ..data,
              credential: auth.Credential(
                ..data.credential,
                access_token: "synthetic-replaced",
              ),
            ),
          ),
        )
        |> should.be_ok
      }
    }
    fence.check(bound) |> should.be_error
    fence.bind(store, ctx, fn() { True }) |> should.be_error
  })
}

pub fn client_authorization_is_a_current_server_capability_test() {
  let assert Ok(store) = storage.new(directory())
  let ctx = context("api_key")
  let key = credentials.key("xai", ctx.auth_mode, ctx.account)
  runtime_store.save(store, key, ctx.credential) |> should.be_ok
  let switch = new_switch()
  let assert Ok(bound) = fence.bind(store, ctx, fn() { allowed(switch) })
  revoke(switch)
  fence.check(bound)
  |> should.equal(Error(c.Failure(c.Cancelled, c.Started, None)))
  fence.bind(store, ctx, fn() { allowed(switch) })
  |> should.equal(Error(c.Failure(c.Cancelled, c.NotSent, None)))
}

pub fn codex_metadata_or_another_store_partition_cannot_authorize_xai_test() {
  let assert Ok(store) = storage.new(directory())
  let ctx = context("oauth")
  let codex = c.Context(..ctx, provider: "codex")
  runtime_store.save(
    store,
    credentials.key("codex", "oauth", ctx.account),
    ctx.credential,
  )
  |> should.be_ok
  fence.bind(store, ctx, fn() { True }) |> should.be_error
  fence.bind(store, codex, fn() { True }) |> should.be_error
}

pub fn expiry_of_unchanged_record_invalidates_existing_fence_test() {
  let assert Ok(store) = storage.new(directory())
  let ctx = context("oauth")
  let assert c.OAuth(data) = ctx.credential
  let ctx =
    c.Context(
      ..ctx,
      credential: c.OAuth(
        c.OAuthData(
          ..data,
          credential: auth.Credential(..data.credential, expires_at_ms: 2000),
        ),
      ),
    )
  let key = credentials.key("xai", ctx.auth_mode, ctx.account)
  runtime_store.save(store, key, ctx.credential) |> should.be_ok
  let assert Ok(before) = runtime_store.load_record(store, key)
  let clock = new_clock(1999)
  let assert Ok(bound) =
    fence.bind_with_clock(store, ctx, fn() { True }, fn() { clock_now(clock) })
  fence.check(bound) |> should.be_ok
  set_clock(clock, 2000)
  fence.check(bound)
  |> should.equal(Error(c.Failure(c.CredentialUnavailable, c.Started, None)))
  let assert Ok(after) = runtime_store.load_record(store, key)
  runtime_store.revision(after) |> should.equal(runtime_store.revision(before))
  runtime_store.record_material(after) |> should.equal(ctx.credential)
  // Production admission still uses real time, never this injected test clock.
  fence.bind(store, ctx, fn() { True })
  |> should.equal(Error(c.Failure(c.CredentialUnavailable, c.NotSent, None)))
}

pub fn acquired_revision_also_requires_exact_material_ready_expiry_and_current_client_test() {
  let assert Ok(store) = storage.new(directory())
  let ctx = context("oauth")
  let key = credentials.key("xai", ctx.auth_mode, ctx.account)
  runtime_store.save(store, key, ctx.credential) |> should.be_ok
  let assert Ok(record) = runtime_store.load_record(store, key)
  let acquired = runtime_store.revision(record)
  let assert Ok(bound) =
    fence.bind_acquired(store, ctx, acquired, fn() { True })
  fence.check(bound) |> should.be_ok
  fence.bind_acquired(store, ctx, acquired, fn() { False })
  |> should.equal(Error(c.Failure(c.Cancelled, c.NotSent, None)))
  let assert c.OAuth(data) = ctx.credential
  let wrong_material =
    c.OAuth(
      c.OAuthData(
        ..data,
        credential: auth.Credential(
          ..data.credential,
          access_token: "synthetic-wrong-acquisition",
        ),
      ),
    )
  // The persisted revision still matches R1; material mismatch alone denies.
  fence.bind_acquired(
    store,
    c.Context(..ctx, credential: wrong_material),
    acquired,
    fn() { True },
  )
  |> should.equal(Error(c.Failure(c.CredentialUnavailable, c.NotSent, None)))
  let assert Ok(blocked) =
    runtime_store.transition(
      store,
      key,
      record,
      ctx.credential,
      runtime_store.NeedsReauthorization,
    )
  fence.bind_acquired(store, ctx, runtime_store.revision(blocked), fn() { True })
  |> should.equal(Error(c.Failure(c.CredentialUnavailable, c.NotSent, None)))
  let expired =
    c.OAuth(
      c.OAuthData(
        ..data,
        credential: auth.Credential(..data.credential, expires_at_ms: 1),
      ),
    )
  runtime_store.save(store, key, expired) |> should.be_ok
  let assert Ok(expired_record) = runtime_store.load_record(store, key)
  fence.bind_acquired(
    store,
    c.Context(..ctx, credential: expired),
    runtime_store.revision(expired_record),
    fn() { True },
  )
  |> should.equal(Error(c.Failure(c.CredentialUnavailable, c.NotSent, None)))
}
