/// These tests run actual Mist sockets with synthetic provider callbacks.
/// The source CLI/provider socket workflow is a separate Python smoke.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/account_ui
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store as records
import mimic/auth/storage
import mimic/gateway/config
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/oauth

@external(erlang, "mimic_account_ui_test_ffi", "focused")
fn focused() -> Bool

pub fn main() {
  let assert True = focused()
}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_test_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "mimic_auth_test_ffi", "mode")
fn mode(path: String) -> Int

@external(erlang, "mimic_auth_test_ffi", "make_symlink")
fn symlink(target: String, path: String) -> Nil

@external(erlang, "mimic_provider_runtime_test_ffi", "chmod")
fn chmod(path: String, mode: Int) -> Nil

@external(erlang, "mimic_account_ui_test_ffi", "write_private")
fn write_private(path: String, contents: String) -> Nil

@external(erlang, "mimic_gateway_ffi", "private_read")
fn read_private(path: String) -> Result(BitArray, String)

@external(erlang, "mimic_account_ui_test_ffi", "request")
fn request(
  port: Int,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> #(Int, List(#(String, String)), String)

@external(erlang, "mimic_account_ui_test_ffi", "mkdir")
fn mkdir(path: String) -> Nil

@external(erlang, "mimic_account_ui_test_ffi", "rmdir")
fn rmdir(path: String) -> Nil

@external(erlang, "mimic_account_ui_test_ffi", "clean")
fn clean(directory: String) -> Bool

type Fixture {
  Fixture(server: account_ui.Server, store: storage.Store, port: Int)
}

type Operator {
  Operator(cookie: String, csrf: String)
}

pub fn stop_joins_bootstrap_cleanup_and_is_idempotent_test() {
  list.each(list.repeat(Nil, 5), fn(_) {
    let fixture = fixture(fn(_) { Error("must not send") })
    read_private(account_ui.bootstrap_path(fixture.server)) |> should.be_ok
    account_ui.stop(fixture.server) |> should.be_ok
    clean(fixture.store.directory) |> should.be_true
    account_ui.stop(fixture.server) |> should.be_ok
    clean(fixture.store.directory) |> should.be_true
  })
}

pub fn typed_server_api_bounds_its_account_roster_test() {
  let state = directory()
  let base = settings(state)
  let assert Ok(account) = list.first(base.accounts)
  let start = fn(accounts) {
    account_ui.start_with_transport(
      config.Config(..base, accounts:),
      "unused-private-identity",
      free_port(),
      fn(_) { panic as "invalid roster must not reach provider I/O" },
    )
    |> should.be_error
  }
  start(list.repeat(account, account_ui.max_accounts + 1))
  start([account, account])
  start([config.Account(..account, id: string.repeat("a", 257))])
}

const device_id = "synthetic-private-kimi-device-id"

fn settings(state: String) -> config.Config {
  let account = fn(id) {
    json.object([
      #("provider", json.string("kimi")),
      #("auth_mode", json.string("oauth")),
      #("id", json.string(id)),
      #("origin", json.string("http://127.0.0.1:43210")),
      #("models", json.array(["kimi-k2.7-code"], json.string)),
      #(
        "oauth",
        json.object([
          #("domain", json.string("kimi.com")),
          #(
            "device_url",
            json.string("http://127.0.0.1:43210/api/oauth/device_authorization"),
          ),
          #("token_url", json.string("http://127.0.0.1:43210/api/oauth/token")),
        ]),
      ),
    ])
  }
  let assert Ok(config) =
    json.object([
      #("version", json.int(1)),
      #("state_dir", json.string(state)),
      #("listen_port", json.int(0)),
      #("accounts", json.array(["kimi-one", "kimi-two"], account)),
    ])
    |> json.to_string
    |> config.decode
  config
}

fn fixture(send: oauth.Send) -> Fixture {
  let state = directory()
  let identity = state <> "/identity.json"
  write_private(identity, "{\"device_id\":\"" <> device_id <> "\"}")
  let port = free_port()
  let assert Ok(server) =
    account_ui.start_with_transport(settings(state), identity, port, send)
  let assert Ok(store) = storage.new(state)
  Fixture(server, store, port)
}

fn headers(fixture: Fixture, operator: Operator) -> List(#(String, String)) {
  [
    #("Origin", "http://127.0.0.1:" <> int.to_string(fixture.port)),
    #("Content-Type", "application/json"),
    #("X-Mimic-UI", "1"),
    #("Cookie", operator.cookie),
    #("X-CSRF-Token", operator.csrf),
  ]
}

fn unlock(fixture: Fixture) -> Operator {
  let path = account_ui.bootstrap_path(fixture.server)
  mode(fixture.store.directory) |> should.equal(448)
  mode(path) |> should.equal(384)
  let assert Ok(bytes) = read_private(path)
  let assert Ok(code) = bit_array.to_string(bytes)
  let reply =
    request(
      fixture.port,
      "POST",
      "/api/session",
      headers(fixture, Operator("", "")),
      "{\"code\":\"" <> code <> "\"}",
    )
  reply.0 |> should.equal(200)
  let assert Ok(cookie) = list.key_find(reply.1, "set-cookie")
  string.contains(cookie, "HttpOnly") |> should.be_true
  string.contains(cookie, "SameSite=Strict") |> should.be_true
  let assert Ok(body) = ir.parse(reply.2)
  let assert Ok(csrf) = ir.string_field(body, "csrf")
  read_private(path) |> should.be_error
  let cookie = string.split(cookie, ";") |> list.first |> result.unwrap("")
  Operator(cookie, csrf)
}

fn action(
  fixture: Fixture,
  operator: Operator,
  path: String,
  body: String,
) -> #(Int, List(#(String, String)), String) {
  let reply =
    request(fixture.port, "POST", path, headers(fixture, operator), body)
  list.each(
    [
      device_id,
      "synthetic-device-secret",
      "synthetic-access-secret",
      "synthetic-refresh-secret",
    ],
    fn(secret) { string.contains(reply.2, secret) |> should.be_false },
  )
  reply
}

fn phase(body: String) -> String {
  let assert Ok(value) = ir.parse(body)
  let assert Ok(accounts) =
    ir.required(value, "accounts") |> result.try(ir.as_array)
  let assert Ok(account) = list.first(accounts)
  let assert Ok(value) = ir.string_field(account, "login")
  value
}

fn await_phase(
  fixture: Fixture,
  operator: Operator,
  expected: String,
  remaining: Int,
) -> String {
  let reply = action(fixture, operator, "/api/status", "{}")
  reply.0 |> should.equal(200)
  case phase(reply.2) == expected {
    True -> reply.2
    False -> {
      let assert True = remaining > 0
      process.sleep(50)
      await_phase(fixture, operator, expected, remaining - 1)
    }
  }
}

fn key() -> String {
  credentials.key("kimi", "oauth", "kimi-one")
}

fn oauth_config() -> oauth.Config {
  oauth.Config(
    "kimi.com",
    "http://127.0.0.1:43210/api/oauth/device_authorization",
    "http://127.0.0.1:43210/api/oauth/token",
    device_id,
  )
}

fn device_reply(seconds: Int) -> oauth.TokenReply {
  oauth.TokenReply(
    200,
    [],
    json.to_string(
      json.object([
        #("device_code", json.string("synthetic-device-secret")),
        #("user_code", json.string("SYNTHETIC-CODE")),
        #("verification_uri", json.string("http://127.0.0.1:43210/verify")),
        #("expires_in", json.int(seconds)),
        #("interval", json.int(5)),
      ]),
    ),
  )
}

fn token_reply() -> oauth.TokenReply {
  oauth.TokenReply(
    200,
    [],
    "{\"access_token\":\"synthetic-access-secret\",\"refresh_token\":\"synthetic-refresh-secret\",\"expires_in\":3600}",
  )
}

fn admin_material() -> contracts.AuthMaterial {
  let assert Ok(material) =
    oauth.material(
      oauth_config(),
      auth.Credential(
        "synthetic-admin-access",
        "synthetic-admin-refresh",
        9_999_999_999_000,
      ),
    )
  material
}

pub fn actual_page_bootstrap_and_security_negatives_test() {
  let called = process.new_subject()
  let fixture =
    fixture(fn(_) {
      process.send(called, Nil)
      Error("synthetic-should-not-send")
    })
  let page = request(fixture.port, "GET", "/", [], "")
  page.0 |> should.equal(200)
  string.contains(page.2, "Account enrollment") |> should.be_true
  list.key_find(page.1, "cache-control")
  |> should.equal(Ok("no-store, max-age=0"))
  list.key_find(page.1, "referrer-policy") |> should.equal(Ok("no-referrer"))
  list.key_find(page.1, "x-frame-options") |> should.equal(Ok("DENY"))
  request(
    fixture.port,
    "GET",
    "/",
    [#("Host", "localhost:" <> int.to_string(fixture.port))],
    "",
  ).0
  |> should.equal(403)
  let unauth = Operator("", "")
  action(fixture, unauth, "/api/status", "{}").0 |> should.equal(401)
  let assert Ok(bytes) = read_private(account_ui.bootstrap_path(fixture.server))
  let assert Ok(code) = bit_array.to_string(bytes)
  let operator = unlock(fixture)
  action(fixture, unauth, "/api/session", "{\"code\":\"" <> code <> "\"}").0
  |> should.equal(401)
  action(fixture, operator, "/api/status", "{}").0 |> should.equal(200)
  action(fixture, Operator(operator.cookie, "invalid"), "/api/status", "{}").0
  |> should.equal(401)
  action(
    fixture,
    Operator(
      "mimic_operator_" <> int.to_string(fixture.port) <> "=invalid",
      operator.csrf,
    ),
    "/api/status",
    "{}",
  ).0
  |> should.equal(401)
  let good = headers(fixture, operator)
  let replace = fn(name, value) {
    [#(name, value), ..list.filter(good, fn(h) { h.0 != name })]
  }
  request(
    fixture.port,
    "POST",
    "/api/login",
    replace("Origin", "https://attacker.invalid"),
    "{\"account\":\"kimi-one\"}",
  ).0
  |> should.equal(403)
  request(
    fixture.port,
    "POST",
    "/api/login",
    list.filter(good, fn(h) { h.0 != "Origin" }),
    "{\"account\":\"kimi-one\"}",
  ).0
  |> should.equal(403)
  request(
    fixture.port,
    "POST",
    "/api/status",
    replace("Content-Type", "text/plain"),
    "{}",
  ).0
  |> should.equal(403)
  request(
    fixture.port,
    "POST",
    "/api/status",
    [#("Content-Length", "1025"), ..good],
    "{}",
  ).0
  |> should.equal(413)
  action(fixture, operator, "/api/status", "{\"unknown\":true}").0
  |> should.equal(400)
  action(fixture, operator, "/api/status", "[]").0 |> should.equal(400)
  action(fixture, operator, "/api/status", "{").0 |> should.equal(400)
  action(
    fixture,
    operator,
    "/api/login",
    "{\"account\":\"kimi-one\",\"account\":\"kimi-two\"}",
  ).0
  |> should.equal(400)
  action(
    fixture,
    operator,
    "/api/login",
    "{\"account\":\"kimi-one\",\"token\":\"not-accepted\"}",
  ).0
  |> should.equal(400)
  action(fixture, operator, "/api/login", "{\"account\":\"codex\"}").0
  |> should.equal(404)
  action(fixture, operator, "/api/logout", "{}").0 |> should.equal(200)
  action(fixture, operator, "/api/status", "{}").0 |> should.equal(401)
  process.receive(called, 0) |> should.equal(Error(Nil))
  account_ui.stop(fixture.server) |> should.be_ok
}

pub fn raw_header_ambiguity_must_close_before_operator_actions_test() {
  let called = process.new_subject()
  let fixture =
    fixture(fn(_) {
      process.send(called, Nil)
      Error("raw security probe must not send")
    })
  let operator = unlock(fixture)
  let good = [
    #("Host", "127.0.0.1:" <> int.to_string(fixture.port)),
    #("Content-Length", "2"),
    ..headers(fixture, operator)
  ]
  // This is an explicit dependency on the parent-owned F44 raw parser rule,
  // not a handler-side workaround after Mist has collapsed duplicate fields.
  // Kept separate so its known-red baseline does not hide other UI negatives.
  list.each(
    [
      #("Origin", "null"),
      #("X-CSRF-Token", "wrong"),
      #("Cookie", "wrong=1"),
      #("Host", "attacker.invalid"),
      #("Content-Length", "3"),
      #("Transfer-Encoding", "chunked"),
    ],
    fn(extra) {
      request(fixture.port, "POST", "/api/status", [extra, ..good], "{}").0
      |> should.equal(0)
    },
  )
  process.receive(called, 0) |> should.equal(Error(Nil))
  storage.read_runtime_slot(fixture.store, key()) |> should.equal(Ok(None))
  account_ui.stop(fixture.server) |> should.be_ok
}

pub fn begin_is_before_start_io_and_cancel_kills_blocked_work_test() {
  let entered = process.new_subject()
  let fixture =
    fixture(fn(_) {
      let release = process.new_subject()
      process.send(entered, release)
      let _ = process.receive(release, 20_000)
      Ok(device_reply(60))
    })
  let operator = unlock(fixture)
  action(fixture, operator, "/api/login", "{\"account\":\"kimi-one\"}").0
  |> should.equal(202)
  let assert Ok(release) = process.receive(entered, 2000)
  records.load(fixture.store, key()) |> should.be_error
  let assert Ok(Some(marker)) = storage.read_runtime_slot(fixture.store, key())
  string.contains(marker, "enrollment_pending") |> should.be_true
  action(fixture, operator, "/api/login", "{\"account\":\"kimi-two\"}").0
  |> should.equal(409)
  action(fixture, operator, "/api/cancel", "{\"account\":\"kimi-one\"}").0
  |> should.equal(200)
  let assert Ok(worker) = process.subject_owner(release)
  process.sleep(50)
  process.is_alive(worker) |> should.be_false
  storage.read_runtime_slot(fixture.store, key()) |> should.equal(Ok(None))
  process.send(release, Nil)
  await_phase(fixture, operator, "cancelled", 20) |> should.not_equal("")
  account_ui.stop(fixture.server) |> should.be_ok
}

pub fn actual_device_expiry_clears_prompt_without_poll_or_install_test() {
  let polls = process.new_subject()
  let fixture =
    fixture(fn(plan) {
      case string.ends_with(plan.url, "device_authorization") {
        True -> Ok(device_reply(1))
        False -> {
          process.send(polls, Nil)
          Ok(token_reply())
        }
      }
    })
  let operator = unlock(fixture)
  action(fixture, operator, "/api/login", "{\"account\":\"kimi-one\"}").0
  |> should.equal(202)
  let waiting = await_phase(fixture, operator, "waiting", 20)
  string.contains(waiting, "SYNTHETIC-CODE") |> should.be_true
  let expired = await_phase(fixture, operator, "expired", 40)
  string.contains(expired, "SYNTHETIC-CODE") |> should.be_false
  string.contains(expired, "/verify") |> should.be_false
  process.receive(polls, 0) |> should.equal(Error(Nil))
  storage.read_runtime_slot(fixture.store, key()) |> should.equal(Ok(None))
  account_ui.stop(fixture.server) |> should.be_ok
}

pub fn actual_authorized_device_installs_gateway_grant_test() {
  let fixture =
    fixture(fn(plan) {
      case string.ends_with(plan.url, "device_authorization") {
        True -> Ok(device_reply(60))
        False -> Ok(token_reply())
      }
    })
  let operator = unlock(fixture)
  action(fixture, operator, "/api/login", "{\"account\":\"kimi-one\"}").0
  |> should.equal(202)
  let stored = await_phase(fixture, operator, "stored", 140)
  string.contains(stored, "SYNTHETIC-CODE") |> should.be_false
  let assert Ok(contracts.OAuth(data)) = records.load(fixture.store, key())
  data.credential.access_token |> should.equal("synthetic-access-secret")
  data.credential.refresh_token |> should.equal("synthetic-refresh-secret")
  list.key_find(data.private_metadata, "device_id")
  |> should.equal(Ok(device_id))
  list.key_find(data.private_metadata, "domain") |> should.equal(Ok("kimi.com"))
  list.key_find(data.private_metadata, "token_url")
  |> should.equal(Ok(oauth_config().token_url))
  records.refresh_status(fixture.store, key())
  |> should.equal(Ok(records.Ready))
  account_ui.stop(fixture.server) |> should.be_ok
}

pub fn cancel_admin_replacement_deletion_and_store_failure_during_poll_test() {
  list.each(["cancel", "replace", "delete", "store-failure"], fn(kind) {
    let entered = process.new_subject()
    let fixture =
      fixture(fn(plan) {
        case string.ends_with(plan.url, "device_authorization") {
          True -> Ok(device_reply(60))
          False -> {
            let release = process.new_subject()
            process.send(entered, release)
            let _ = process.receive(release, 20_000)
            Ok(token_reply())
          }
        }
      })
    // Re-enrollment retains the exact prior runtime material on cancellation.
    records.save(fixture.store, key(), admin_material()) |> should.be_ok
    let operator = unlock(fixture)
    action(fixture, operator, "/api/login", "{\"account\":\"kimi-one\"}").0
    |> should.equal(202)
    let assert Ok(release) = process.receive(entered, 7000)
    let guard =
      fixture.store.directory
      <> "/.mutation-runtime-"
      <> bit_array.base64_url_encode(bit_array.from_string(key()), False)
      <> ".json"
    case kind {
      "cancel" -> {
        action(fixture, operator, "/api/cancel", "{\"account\":\"kimi-one\"}").0
        |> should.equal(200)
        process.send(release, Nil)
        await_phase(fixture, operator, "cancelled", 20) |> should.not_equal("")
      }
      "replace" -> {
        // Even an identical-token admin save is a different exact generation.
        records.save(fixture.store, key(), admin_material()) |> should.be_ok
        process.send(release, Nil)
        await_phase(fixture, operator, "installation_unconfirmed", 40)
        |> should.not_equal("")
      }
      "delete" -> {
        records.delete(fixture.store, key()) |> should.be_ok
        process.send(release, Nil)
        await_phase(fixture, operator, "installation_unconfirmed", 40)
        |> should.not_equal("")
      }
      _ -> {
        mkdir(guard)
        process.send(release, Nil)
        let body =
          await_phase(fixture, operator, "installation_unconfirmed", 40)
        string.contains(body, "mutation") |> should.be_false
        rmdir(guard)
      }
    }
    case kind {
      "delete" ->
        storage.read_runtime_slot(fixture.store, key())
        |> should.equal(Ok(None))
      _ ->
        records.load(fixture.store, key()) |> should.equal(Ok(admin_material()))
    }
    account_ui.stop(fixture.server) |> should.be_ok
  })
}

pub fn stop_fences_inflight_start_and_private_identity_policy_test() {
  let entered = process.new_subject()
  let fixture =
    fixture(fn(_) {
      let release = process.new_subject()
      process.send(entered, release)
      let _ = process.receive(release, 20_000)
      Ok(device_reply(60))
    })
  let operator = unlock(fixture)
  action(fixture, operator, "/api/login", "{\"account\":\"kimi-one\"}").0
  |> should.equal(202)
  let assert Ok(release) = process.receive(entered, 2000)
  account_ui.stop(fixture.server) |> should.be_ok
  storage.read_runtime_slot(fixture.store, key()) |> should.equal(Ok(None))
  let assert Ok(worker) = process.subject_owner(release)
  process.sleep(50)
  process.is_alive(worker) |> should.be_false
  let settings = settings(fixture.store.directory)
  let path = fixture.store.directory <> "/identity.json"
  account_ui.start(settings, "relative.json", free_port()) |> should.be_error
  chmod(path, 420)
  account_ui.start(settings, path, free_port()) |> should.be_error
  chmod(path, 384)
  let link = fixture.store.directory <> "/identity-link.json"
  symlink(path, link)
  account_ui.start(settings, link, free_port()) |> should.be_error
  write_private(
    path,
    "{\"device_id\":\"synthetic\",\"access_token\":\"not-accepted\"}",
  )
  account_ui.start(settings, path, free_port()) |> should.be_error
  account_ui.cli(["serve", "unused", "unused", "0"]) |> should.be_error
  account_ui.cli(["serve", "unused", "unused", "9091x"]) |> should.be_error
}
