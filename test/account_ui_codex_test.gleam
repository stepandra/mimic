/// F06 synthetic policy, real loopback callback sockets and exact S5 CAS.
/// The separate source CLI smoke proves the actual gateway consumption path.
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleeunit/should
import mimic/account_ui/codex
import mimic/account_ui/coordinator.{Authorization}
import mimic/account_ui/enrollment_adapters as adapters
import mimic/account_ui/primitives as os
import mimic/auth/crypto
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store as records
import mimic/auth/storage
import mimic/fleet
import mimic/gateway/config
import mimic/ir
import mimic/providers/claude/policy
import mimic/providers/codex/adapter as provider
import mimic/providers/codex/fixtures
import mimic/providers/codex/oauth
import mimic/providers/contracts
import mimic/types

@external(erlang, "mimic_account_ui_codex_test_ffi", "focused")
fn focused() -> Bool

pub fn main() {
  let assert True = focused()
}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_test_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "mimic_account_ui_codex_test_ffi", "request")
fn request(
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> #(Int, List(#(String, String)), String)

@external(erlang, "mimic_account_ui_codex_test_ffi", "port_closed")
fn port_closed(port: Int) -> Bool

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
    auth: coordinator.Authorization,
    callback_port: Int,
    clock: Clock,
  )
}

fn settings(port: Int) -> oauth.Config {
  oauth.Config(
    "http://127.0.0.1:43210/oauth/authorize",
    "http://127.0.0.1:43210/oauth/token",
    "http://127.0.0.1:" <> int.to_string(port) <> "/auth/callback",
  )
}

fn fixture(send: codex.Send, limits: coordinator.Limits) -> Fixture {
  let assert Ok(store) = storage.new(directory())
  let callback_port = free_port()
  let bootstrap = crypto.random_url_token()
  os.create_private(store.directory, "bootstrap-f06.txt", bootstrap)
  |> should.be_ok
  let accounts =
    list.map(["one", "two"], fn(id) {
      config.Account(
        "codex",
        "oauth",
        id,
        "http://127.0.0.1:43210",
        ["gpt-5.5"],
        fleet.LocalLoopback,
        Some(config.CodexOAuth(settings(callback_port))),
        "",
        policy.native(),
        [],
        xai_operations: [],
      )
    })
  let clock = clock_new(-100_000)
  let assert Ok(engine) =
    coordinator.start_with_transports_clock(
      store,
      accounts,
      "",
      adapters.Transports(fn(_) { Error("unused") }, send),
      "bootstrap-f06.txt",
      bootstrap,
      limits,
      fn() { clock_get(clock) },
    )
  let exchanged = coordinator.exchange(engine, bootstrap)
  let assert Some(token) = exchanged.session_cookie
  let assert Ok(value) = ir.parse(json.to_string(exchanged.body))
  let assert Ok(csrf) = ir.string_field(value, "csrf")
  Fixture(engine, store, Authorization(token, csrf), callback_port, clock)
}

fn limits() -> coordinator.Limits {
  coordinator.Limits(10_000, 10_000, 5000, 10)
}

fn token_response() -> types.WireResponse {
  types.WireResponse(200, [], fixtures.tokens(), 0)
}

fn material() -> contracts.AuthMaterial {
  let assert Ok(tokens) =
    oauth.decode_tokens(200, fixtures.tokens(), None, os.epoch_ms())
  contracts.OAuth(provider.material(tokens))
}

fn key(id: String) -> String {
  credentials.key("codex", "oauth", id)
}

fn account(fixture: Fixture, id: String) -> ir.Value {
  let reply = coordinator.status(fixture.engine, fixture.auth)
  reply.status |> should.equal(200)
  let assert Ok(value) = ir.parse(json.to_string(reply.body))
  let assert Ok(accounts) = ir.required(value, "accounts")
  let assert Ok(accounts) = ir.as_array(accounts)
  let assert Ok(account) =
    list.find(accounts, fn(a) { ir.string_field(a, "id") == Ok(id) })
  account
}

fn wait_phase(
  fixture: Fixture,
  id: String,
  phase: String,
  tries: Int,
) -> ir.Value {
  let value = account(fixture, id)
  case ir.string_field(value, "login") == Ok(phase) {
    True -> value
    False -> {
      { tries > 0 } |> should.be_true
      process.sleep(10)
      wait_phase(fixture, id, phase, tries - 1)
    }
  }
}

fn wait_closed(port: Int, tries: Int) -> Nil {
  case port_closed(port) {
    True -> Nil
    False -> {
      { tries > 0 } |> should.be_true
      process.sleep(10)
      wait_closed(port, tries - 1)
    }
  }
}

fn login(fixture: Fixture, id: String) -> String {
  coordinator.login(fixture.engine, fixture.auth, id).status
  |> should.equal(202)
  let value = wait_phase(fixture, id, "waiting", 500)
  let assert Ok(url) = ir.string_field(value, "authorization_url")
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(query) = parsed.query
  let assert Ok(fields) = uri.parse_query(query)
  list.key_find(fields, "client_id") |> should.equal(Ok(oauth.client_id))
  list.key_find(fields, "code_challenge_method") |> should.equal(Ok("S256"))
  list.key_find(fields, "scope")
  |> should.equal(Ok("openid email profile offline_access"))
  list.key_find(fields, "code_verifier") |> should.be_error
  url
}

fn query(url: String, code: String) -> String {
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(query) = parsed.query
  let assert Ok(fields) = uri.parse_query(query)
  let assert Ok(state) = list.key_find(fields, "state")
  uri.query_to_string([#("state", state), #("code", code)])
}

fn callback(fixture: Fixture, query: String) -> Int {
  let response =
    request(fixture.callback_port, "GET", "/auth/callback?" <> query, [], "")
  string.contains(response.2, query) |> should.be_false
  response.0
}

pub fn source_config_and_callback_port_are_explicit_test() {
  codex.validate(oauth.published_config(), 9999) |> should.be_ok
  codex.validate(settings(1455), 1455) |> should.be_error
  list.each(
    [
      "https://127.0.0.1:1455/auth/callback",
      "http://example.invalid:1455/auth/callback",
      "http://127.0.0.1/auth/callback",
      "http://127.0.0.1:1455/auth/callback?code=secret",
      "http://127.0.0.1:1455/auth%2Fcallback",
    ],
    fn(redirect) {
      codex.validate(
        oauth.Config(..settings(1455), redirect_uri: redirect),
        9999,
      )
      |> should.be_error
    },
  )
}

pub fn real_callback_exchanges_pkce_installs_only_selected_account_once_test() {
  let called = process.new_subject()
  let fixture =
    fixture(
      fn(plan) {
        process.send(called, plan)
        Ok(token_response())
      },
      limits(),
    )
  let url = login(fixture, "two")
  coordinator.login(fixture.engine, fixture.auth, "one").status
  |> should.equal(409)
  records.load(fixture.store, key("two")) |> should.be_error
  callback(fixture, query(url, "synthetic-code")) |> should.equal(200)
  let assert Ok(plan) = process.receive(called, 5000)
  let assert Ok(fields) = uri.parse_query(plan.body)
  list.key_find(fields, "code") |> should.equal(Ok("synthetic-code"))
  list.key_find(fields, "grant_type") |> should.equal(Ok("authorization_code"))
  let assert Ok(verifier) = list.key_find(fields, "code_verifier")
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(raw) = parsed.query
  let assert Ok(auth) = uri.parse_query(raw)
  list.key_find(auth, "code_challenge")
  |> should.equal(Ok(crypto.pkce_challenge(verifier)))
  let value = wait_phase(fixture, "two", "stored", 500)
  ir.field(value, "authorization_url") |> should.equal(None)
  ir.string_field(value, "provider") |> should.equal(Ok("codex"))
  records.load(fixture.store, key("one")) |> should.be_error
  let assert Ok(contracts.OAuth(data)) = records.load(fixture.store, key("two"))
  data.credential.access_token |> should.equal("synthetic-access-not-a-secret")
  data.private_metadata
  |> should.equal([#("chatgpt_account_id", "synthetic-chatgpt-account")])
  wait_closed(fixture.callback_port, 500)
  callback(fixture, query(url, "synthetic-code")) |> should.equal(0)
  process.receive(called, 0) |> should.equal(Error(Nil))
  coordinator.stop(fixture.engine) |> should.be_ok
}

pub fn mismatch_duplicate_state_and_provider_error_consume_without_exchange_test() {
  list.each(["mismatch", "duplicate", "error"], fn(kind) {
    let called = process.new_subject()
    let fixture =
      fixture(
        fn(_) {
          process.send(called, Nil)
          Ok(token_response())
        },
        limits(),
      )
    let url = login(fixture, "one")
    let valid = query(url, "synthetic-code")
    let invalid = case kind {
      "mismatch" -> "state=wrong&code=synthetic-code"
      "duplicate" -> valid <> "&state=wrong"
      _ -> valid <> "&error=access_denied"
    }
    callback(fixture, invalid) |> should.equal(400)
    let value = wait_phase(fixture, "one", "callback_rejected", 500)
    ir.field(value, "authorization_url") |> should.equal(None)
    storage.read_runtime_slot(fixture.store, key("one"))
    |> should.equal(Ok(None))
    wait_closed(fixture.callback_port, 500)
    callback(fixture, valid) |> should.equal(0)
    process.receive(called, 0) |> should.equal(Error(Nil))
    coordinator.stop(fixture.engine) |> should.be_ok
  })
}

pub fn callback_http_boundary_does_not_accept_host_path_post_or_large_query_test() {
  let fixture = fixture(fn(_) { Ok(token_response()) }, limits())
  let url = login(fixture, "one")
  let path = "/auth/callback?" <> query(url, "synthetic-code")
  request(
    fixture.callback_port,
    "GET",
    path,
    [#("Host", "example.invalid")],
    "",
  ).0
  |> should.equal(400)
  request(fixture.callback_port, "POST", path, [], "").0 |> should.equal(400)
  request(
    fixture.callback_port,
    "GET",
    "/other?" <> query(url, "synthetic-code"),
    [],
    "",
  ).0
  |> should.equal(400)
  request(
    fixture.callback_port,
    "GET",
    "/auth/callback?code=" <> string.repeat("x", 4100),
    [],
    "",
  ).0
  |> should.equal(400)
  callback(fixture, query(url, "synthetic-code")) |> should.equal(200)
  wait_phase(fixture, "one", "stored", 500)
  coordinator.stop(fixture.engine) |> should.be_ok
}

pub fn cancel_closes_waiting_callback_and_preserves_existing_grant_generation_test() {
  let called = process.new_subject()
  let fixture =
    fixture(
      fn(_) {
        process.send(called, Nil)
        Ok(token_response())
      },
      limits(),
    )
  let original = material()
  records.save(fixture.store, key("one"), original) |> should.be_ok
  let assert Ok(before) = records.load_record(fixture.store, key("one"))
  let url = login(fixture, "one")
  coordinator.cancel(fixture.engine, fixture.auth, "two").status
  |> should.equal(409)
  coordinator.cancel(fixture.engine, fixture.auth, "one").status
  |> should.equal(200)
  wait_closed(fixture.callback_port, 500)
  callback(fixture, query(url, "synthetic-code")) |> should.equal(0)
  let assert Ok(after) = records.load_record(fixture.store, key("one"))
  records.record_material(after) |> should.equal(original)
  { records.revision(after) != records.revision(before) } |> should.be_true
  process.receive(called, 0) |> should.equal(Error(Nil))
  coordinator.stop(fixture.engine) |> should.be_ok
}

pub fn session_attempt_and_exchange_expiry_are_bounded_test() {
  list.each(["session", "attempt", "exchange"], fn(kind) {
    let entered = process.new_subject()
    let limits = case kind {
      "session" -> coordinator.Limits(10_000, 1000, 5000, 10)
      _ -> coordinator.Limits(10_000, 10_000, 1000, 10)
    }
    let fixture =
      fixture(
        fn(_) {
          let release = process.new_subject()
          process.send(entered, release)
          let _ = process.receive(release, 10_000)
          Ok(token_response())
        },
        limits,
      )
    let url = login(fixture, "one")
    case kind {
      "exchange" -> {
        callback(fixture, query(url, "synthetic-code")) |> should.equal(200)
        let assert Ok(release) = process.receive(entered, 5000)
        let value = wait_phase(fixture, "one", "exchanging", 500)
        ir.field(value, "authorization_url") |> should.equal(None)
        clock_set(fixture.clock, -98_000)
        wait_phase(fixture, "one", "expired", 500)
        let assert Ok(worker) = process.subject_owner(release)
        process.is_alive(worker) |> should.be_false
      }
      _ -> {
        clock_set(fixture.clock, -98_000)
        coordinator.status(fixture.engine, fixture.auth).status
        |> should.equal(case kind {
          "session" -> 401
          _ -> 200
        })
        wait_closed(fixture.callback_port, 500)
        callback(fixture, query(url, "synthetic-code")) |> should.equal(0)
      }
    }
    storage.read_runtime_slot(fixture.store, key("one"))
    |> should.equal(Ok(None))
    coordinator.stop(fixture.engine) |> should.be_ok
  })
}

pub fn admin_same_token_replace_and_delete_win_over_blocked_exchange_test() {
  list.each(["same", "replace", "delete"], fn(kind) {
    let entered = process.new_subject()
    let fixture =
      fixture(
        fn(_) {
          let release = process.new_subject()
          process.send(entered, release)
          let _ = process.receive(release, 10_000)
          Ok(token_response())
        },
        limits(),
      )
    let original = material()
    records.save(fixture.store, key("one"), original) |> should.be_ok
    let url = login(fixture, "one")
    callback(fixture, query(url, "synthetic-code")) |> should.equal(200)
    let assert Ok(release) = process.receive(entered, 5000)
    case kind {
      "delete" -> records.delete(fixture.store, key("one")) |> should.be_ok
      "replace" ->
        records.save(
          fixture.store,
          key("one"),
          contracts.ApiKey("synthetic-admin"),
        )
        |> should.be_ok
      _ -> records.save(fixture.store, key("one"), original) |> should.be_ok
    }
    let expected = storage.read_runtime_slot(fixture.store, key("one"))
    process.send(release, Nil)
    wait_phase(fixture, "one", "installation_unconfirmed", 500)
    storage.read_runtime_slot(fixture.store, key("one"))
    |> should.equal(expected)
    records.load(fixture.store, key("two")) |> should.be_error
    coordinator.stop(fixture.engine) |> should.be_ok
  })
}

pub fn cancellation_of_blocked_exchange_cannot_install_late_tokens_test() {
  let entered = process.new_subject()
  let fixture =
    fixture(
      fn(_) {
        let release = process.new_subject()
        process.send(entered, release)
        let _ = process.receive(release, 10_000)
        Ok(token_response())
      },
      limits(),
    )
  let url = login(fixture, "one")
  callback(fixture, query(url, "synthetic-code")) |> should.equal(200)
  let assert Ok(release) = process.receive(entered, 5000)
  coordinator.cancel(fixture.engine, fixture.auth, "one").status
  |> should.equal(200)
  process.send(release, Nil)
  process.sleep(20)
  storage.read_runtime_slot(fixture.store, key("one")) |> should.equal(Ok(None))
  wait_phase(fixture, "one", "cancelled", 500)
  coordinator.stop(fixture.engine) |> should.be_ok
}

pub fn occupied_s5_slot_blocks_callback_publication_and_token_io_test() {
  let called = process.new_subject()
  let fixture =
    fixture(
      fn(_) {
        process.send(called, Nil)
        Ok(token_response())
      },
      limits(),
    )
  let assert Ok(ticket) = records.begin_enrollment(fixture.store, key("one"))
  coordinator.login(fixture.engine, fixture.auth, "one").status
  |> should.equal(409)
  port_closed(fixture.callback_port) |> should.be_true
  ir.field(account(fixture, "one"), "authorization_url") |> should.equal(None)
  process.receive(called, 0) |> should.equal(Error(Nil))
  records.cancel_enrollment(ticket) |> should.be_ok
  coordinator.stop(fixture.engine) |> should.be_ok
}

pub fn unknown_token_delivery_is_not_retried_or_persisted_test() {
  let called = process.new_subject()
  let fixture =
    fixture(
      fn(_) {
        process.send(called, Nil)
        Error(contracts.RefreshUnavailable)
      },
      limits(),
    )
  let url = login(fixture, "one")
  callback(fixture, query(url, "synthetic-code")) |> should.equal(200)
  wait_phase(fixture, "one", "failed", 500)
  process.receive(called, 0) |> should.equal(Ok(Nil))
  process.receive(called, 0) |> should.equal(Error(Nil))
  storage.read_runtime_slot(fixture.store, key("one")) |> should.equal(Ok(None))
  coordinator.stop(fixture.engine) |> should.be_ok
}
