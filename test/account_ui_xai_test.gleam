/// F07 synthetic-only: configured selection, monotonic lifecycle, exact S5
/// generations and the existing refresh worker. Actual root HTTP is separate.
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleeunit/should
import mimic/account_ui/coordinator
import mimic/account_ui/enrollment_adapters as adapters
import mimic/account_ui/primitives as os
import mimic/auth
import mimic/auth/crypto
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store as records
import mimic/auth/storage
import mimic/gateway/config
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/xai/adapter
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/providers/xai/enrollment
import mimic/providers/xai/oauth
import mimic/providers/xai/operations

@external(erlang, "mimic_account_ui_xai_test_ffi", "focused")
fn focused() -> Bool

pub fn main() {
  let assert True = focused()
}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

type Clock

@external(erlang, "mimic_account_ui_test_ffi", "clock_new")
fn clock_new(now: Int) -> Clock

@external(erlang, "mimic_account_ui_test_ffi", "clock_get")
fn clock_get(clock: Clock) -> Int

@external(erlang, "mimic_account_ui_test_ffi", "clock_set")
fn clock_set(clock: Clock, now: Int) -> Nil

const origin = "http://127.0.0.1:43210"

const api_origin = "http://127.0.0.1:43211"

fn oauth_config() {
  oauth.Config(origin <> "/discovery", endpoint.LocalMock)
}

fn bindings(id: String) -> List(operations.Binding) {
  let assert Ok(proxy) =
    operations.new(
      id,
      "oauth",
      "responses",
      "responses",
      origin <> "/v1",
      False,
    )
  let assert Ok(api) =
    operations.new(
      id,
      "oauth",
      "responses",
      "responses/compact",
      api_origin <> "/v1",
      True,
    )
  [proxy, api]
}

fn settings(state: String) -> config.Config {
  let accounts =
    list.map(["one", "two"], fn(id) {
      json.object([
        #("provider", json.string("xai")),
        #("auth_mode", json.string("oauth")),
        #("id", json.string(id)),
        #("origin", json.string(origin)),
        #("models", json.array(["grok-4.7"], json.string)),
        #(
          "oauth",
          json.object([#("discovery_url", json.string(origin <> "/discovery"))]),
        ),
        #(
          "xai_operations",
          json.array(["responses", "responses/compact"], fn(op) {
            json.object([
              #("protocol", json.string("responses")),
              #("operation", json.string(op)),
              #(
                "base",
                json.string(case op {
                  "responses" -> origin <> "/v1"
                  _ -> api_origin <> "/v1"
                }),
              ),
              #("using_api", json.bool(op != "responses")),
            ])
          }),
        ),
      ])
    })
  let assert Ok(config) =
    config.decode(
      json.to_string(
        json.object([
          #("version", json.int(1)),
          #("state_dir", json.string(state)),
          #("listen_port", json.int(0)),
          #("accounts", json.array(accounts, fn(a) { a })),
        ]),
      ),
    )
  config
}

type Fixture {
  Fixture(
    engine: coordinator.Coordinator,
    store: storage.Store,
    auth: coordinator.Authorization,
    clock: Clock,
  )
}

fn fixture(send: oauth.Send, limits: coordinator.Limits) -> Fixture {
  let assert Ok(store) = storage.new(directory())
  let clock = clock_new(-100_000)
  start(store, clock, send, limits)
}

fn start(
  store: storage.Store,
  clock: Clock,
  send: oauth.Send,
  limits: coordinator.Limits,
) -> Fixture {
  let bootstrap = crypto.random_url_token()
  os.create_private(store.directory, "bootstrap-f07.txt", bootstrap)
  |> should.be_ok
  let transports =
    adapters.with_xai(
      adapters.Transports(fn(_) { Error("unused") }, fn(_) {
        Error(c.RefreshUnsupported)
      }),
      send,
    )
  let assert Ok(engine) =
    coordinator.start_with_transports_clock(
      store,
      settings(store.directory).accounts,
      "",
      transports,
      "bootstrap-f07.txt",
      bootstrap,
      limits,
      fn() { clock_get(clock) },
    )
  let exchanged = coordinator.exchange(engine, bootstrap)
  let assert Some(token) = exchanged.session_cookie
  let assert Ok(value) = ir.parse(json.to_string(exchanged.body))
  let assert Ok(csrf) = ir.string_field(value, "csrf")
  Fixture(engine, store, coordinator.Authorization(token, csrf), clock)
}

fn limits() {
  coordinator.Limits(10_000, 10_000, 5000, 10)
}

fn reply(status, body) {
  Ok(response.new(status) |> response.set_body(body))
}

fn synthetic(req: request.Request(String)) {
  case req.path {
    "/discovery" ->
      reply(
        200,
        "{\"device_authorization_endpoint\":\""
          <> origin
          <> "/device\","
          <> "\"token_endpoint\":\""
          <> origin
          <> "/token\"}",
      )
    "/device" ->
      reply(
        200,
        "{\"device_code\":\"synthetic-private-xai-device\","
          <> "\"user_code\":\"SYNTHETIC-F07\",\"verification_uri\":\""
          <> origin
          <> "/verify\",\"expires_in\":60,\"interval\":1}",
      )
    "/token" ->
      reply(
        200,
        "{\"access_token\":\"synthetic-private-xai-access\","
          <> "\"refresh_token\":\"synthetic-private-xai-refresh\",\"expires_in\":1}",
      )
    _ -> Error("unexpected synthetic path")
  }
}

fn key(id: String) {
  credentials.key("xai", "oauth", id)
}

fn material(expires: Int) -> c.AuthMaterial {
  let assert Ok(value) =
    bridge.oauth_material(
      oauth_config(),
      oauth.Discovery(origin <> "/device", origin <> "/token"),
      auth.Credential(
        "synthetic-admin-access",
        "synthetic-admin-refresh",
        expires,
      ),
    )
  value
}

fn row(f: Fixture, id: String) -> ir.Value {
  let reply = coordinator.status(f.engine, f.auth)
  reply.status |> should.equal(200)
  let text = json.to_string(reply.body)
  list.each(
    ["synthetic-private", "synthetic-admin", "device_code", "token_endpoint"],
    fn(secret) { string.contains(text, secret) |> should.be_false },
  )
  let assert Ok(value) = ir.parse(text)
  let assert Ok(rows) =
    ir.required(value, "accounts") |> result.try(ir.as_array)
  let assert Ok(value) =
    list.find(rows, fn(a) { ir.string_field(a, "id") == Ok(id) })
  value
}

fn phase(f: Fixture, id: String, expected: String, tries: Int) -> ir.Value {
  let value = row(f, id)
  case ir.string_field(value, "login") == Ok(expected) {
    True -> value
    False -> {
      { tries > 0 } |> should.be_true
      process.sleep(10)
      phase(f, id, expected, tries - 1)
    }
  }
}

fn req(operation: String) -> c.Request {
  c.Request(
    "xai",
    "oauth",
    "grok-4.7",
    "responses",
    operation,
    c.Buffered,
    [c.Buffer],
    "synthetic-operator-client",
    Some("one"),
    "{\"model\":\"grok-4.7\",\"input\":[]}",
  )
}

fn context(origin: String) -> c.Context {
  c.Context(
    "xai",
    "oauth",
    "one",
    origin,
    "synthetic-session",
    material(9_999_999_999_999),
  )
}

pub fn strict_discovery_and_explicit_operation_forms_test() {
  enrollment.decode_config(
    ir.Object([#("discovery_url", ir.String(oauth.discovery_url))]),
  )
  |> should.be_ok
  list.each(
    [
      "http://localhost:43210/discovery", "http://example.invalid/discovery",
      "https://evil.example/discovery",
      "http://127.0.0.1:43210/discovery?token=private",
    ],
    fn(url) {
      enrollment.decode_config(ir.Object([#("discovery_url", ir.String(url))]))
      |> should.be_error
    },
  )
  enrollment.decode_config(
    ir.Object([
      #("discovery_url", ir.String(origin <> "/discovery")),
      #("client_id", ir.String("other")),
    ]),
  )
  |> should.be_error
  list.each(
    ["chat", "responses/websocket", "images/generations", "video", ""],
    fn(op) {
      operations.new("one", "oauth", "responses", op, origin <> "/v1", True)
      |> should.be_error
    },
  )
  operations.new(
    "one",
    "oauth",
    "responses",
    "responses/compact",
    origin <> "/v1",
    False,
  )
  |> should.be_error
  operations.new(
    "one",
    "oauth",
    "responses",
    "responses",
    endpoint.api_base,
    False,
  )
  |> should.be_error
  operations.new(
    "one",
    "oauth",
    "responses",
    "responses",
    origin <> "/v1/",
    False,
  )
  |> should.be_error
  operations.validate_account("one", "oauth", []) |> should.be_error
  operations.validate_account(
    "one",
    "oauth",
    list.append(bindings("one"), bindings("one")),
  )
  |> should.be_error
  operations.validate_account("other", "oauth", bindings("one"))
  |> should.be_error
  let assert Ok(raw) =
    ir.parse(
      "[{\"protocol\":\"responses\",\"operation\":\"responses\",\"base\":\""
      <> origin
      <> "/v1\",\"using_api\":false,\"ambient\":true}]",
    )
  operations.decode("one", "oauth", raw) |> should.be_error
}

pub fn selection_is_account_auth_operation_and_origin_bound_test() {
  let selected = bindings("one")
  let assert Ok(proxy) =
    operations.select(selected, context(origin), req("responses"))
  let assert Ok(plan) = endpoint.select(proxy, endpoint.Responses)
  plan.url |> should.equal(origin <> "/v1/responses")
  let assert Ok(api) =
    operations.select(selected, context(api_origin), req("responses/compact"))
  let assert Ok(plan) = endpoint.select(api, endpoint.Compact)
  plan.url |> should.equal(api_origin <> "/v1/responses/compact")
  list.each(
    [
      context(api_origin),
      c.Context(..context(origin), account: "two"),
      c.Context(..context(origin), provider: "codex"),
      c.Context(..context(origin), auth_mode: "api_key"),
    ],
    fn(ctx) {
      operations.select(selected, ctx, req("responses")) |> should.be_error
    },
  )
  operations.select(
    selected,
    context(origin),
    c.Request(..req("responses"), pinned_account: Some("two")),
  )
  |> should.be_error
  let denied = c.Failure(c.Unsupported, c.NotSent, None)
  adapter.configured_http(fn(_, _) { Error(denied) }, None).open(
    context(origin),
    req("responses"),
  )
  |> should.equal(Error(denied))
}

pub fn registration_contains_only_model_qualified_bound_operations_test() {
  let selected = bindings("one")
  let assert Ok(normal) =
    operations.registration("one", "oauth", selected, "grok-4.7")
  normal.auth_modes |> should.equal(["oauth"])
  normal.operations |> should.equal(["responses", "responses/compact"])
  normal.capabilities |> should.equal([c.Buffer, c.Stream, c.Tools])
  let assert Ok(build) =
    operations.registration("one", "oauth", selected, "grok-4.7-build-fast")
  build.operations |> should.equal(["responses"])
  let assert Ok(compact) =
    operations.new(
      "one",
      "oauth",
      "responses",
      "responses/compact",
      api_origin <> "/v1",
      True,
    )
  let assert Ok(compact_only) =
    operations.registration("one", "oauth", [compact], "grok-4.7")
  compact_only.operations |> should.equal(["responses/compact"])
  compact_only.capabilities |> should.equal([c.Buffer])
  operations.registration("one", "oauth", [compact], "grok-4.7-build-fast")
  |> should.be_error
  operations.registration("one", "oauth", selected, "synthetic-unknown-model")
  |> should.be_error
  operations.registration("other", "oauth", selected, "grok-4.7")
  |> should.be_error
  operations.registration("one", "oauth", [], "grok-4.7") |> should.be_error
  let assert Ok(legacy) =
    operations.registration("one", "api_key", [], "grok-4.7")
  legacy.auth_modes |> should.equal(["api_key"])
  legacy.operations |> should.equal(["responses", "responses/compact"])
  legacy.capabilities |> should.equal([c.Buffer, c.Stream, c.Tools])
}

pub fn private_device_code_cannot_be_relabelled_or_embedded_in_browser_prompt_test() {
  let discovery = oauth.Discovery(origin <> "/device", origin <> "/token")
  list.each(
    [
      #("synthetic-private-code", origin <> "/verify"),
      #("PREFIXsynthetic-private-codeSUFFIX", origin <> "/verify"),
      #("PREFIXsynthetic%2Dprivate%2DcodeSUFFIX", origin <> "/verify"),
      #("PUBLIC", origin <> "/verify/synthetic-private-code"),
      #("PUBLIC", origin <> "/verify/synthetic%2dprivate%2dcode"),
    ],
    fn(prompt) {
      oauth.start(
        oauth_config(),
        discovery,
        fn(_) {
          reply(
            200,
            json.to_string(
              json.object([
                #("device_code", json.string("synthetic-private-code")),
                #("user_code", json.string(prompt.0)),
                #("verification_uri", json.string(prompt.1)),
                #("expires_in", json.int(60)),
              ]),
            ),
          )
        },
        1000,
      )
      |> should.be_error
    },
  )
}

pub fn imported_and_discovered_refresh_endpoints_follow_sender_rules_test() {
  list.each(
    [
      origin,
      origin <> "/",
      "http://[::1]:43210/token",
    ],
    fn(url) {
      enrollment.import_material(
        oauth_config(),
        ir.Object([
          #("access_token", ir.String("synthetic-access")),
          #("refresh_token", ir.String("synthetic-refresh")),
          #("expires_at_ms", ir.Integer(9_000_000_000_000)),
          #("token_endpoint", ir.String(url)),
        ]),
      )
      |> should.be_error
      let assert Ok(plan) = request.to(url)
      enrollment.send(plan) |> should.be_error
      let called = process.new_subject()
      let f =
        fixture(
          fn(plan) {
            process.send(called, plan.path)
            reply(
              200,
              "{\"device_authorization_endpoint\":\""
                <> origin
                <> "/device\",\"token_endpoint\":\""
                <> url
                <> "\"}",
            )
          },
          limits(),
        )
      coordinator.login(f.engine, f.auth, "one").status |> should.equal(202)
      phase(f, "one", "failed", 500)
      process.receive(called, 0) |> should.equal(Ok("/discovery"))
      process.receive(called, 0) |> should.be_error
      records.load(f.store, key("one")) |> should.be_error
      coordinator.stop(f.engine) |> should.be_ok
    },
  )
}

pub fn device_enrollment_s5_persists_epoch_expiry_only_selected_account_test() {
  let f =
    fixture(
      fn(plan) {
        let assert Ok(fields) = case plan.path {
          "/token" | "/device" -> uri.parse_query(plan.body)
          _ -> Ok([])
        }
        case plan.path {
          "/device" -> {
            list.key_find(fields, "client_id")
            |> should.equal(Ok(oauth.client_id))
            list.key_find(fields, "scope") |> should.equal(Ok(oauth.scope))
          }
          "/token" ->
            list.key_find(fields, "grant_type")
            |> should.equal(Ok(oauth.device_grant))
          _ -> Nil
        }
        synthetic(plan)
      },
      limits(),
    )
  coordinator.login(f.engine, f.auth, "two").status |> should.equal(202)
  let final = phase(f, "two", "stored", 500)
  ir.field(final, "user_code") |> should.equal(None)
  let assert Ok(c.OAuth(data)) = records.load(f.store, key("two"))
  { data.credential.expires_at_ms > 1_000_000_000_000 } |> should.be_true
  data.private_metadata
  |> should.equal([#("token_endpoint", origin <> "/token")])
  records.load(f.store, key("one")) |> should.be_error
  coordinator.stop(f.engine) |> should.be_ok
}

fn blocked(failure: String, path: String) {
  let entered = process.new_subject()
  let f =
    fixture(
      fn(plan) {
        case plan.path == path {
          True -> {
            let release = process.new_subject()
            process.send(entered, release)
            let _ = process.receive(release, 5000)
            case failure {
              "pending" -> reply(400, "{\"error\":\"authorization_pending\"}")
              _ -> synthetic(plan)
            }
          }
          False -> synthetic(plan)
        }
      },
      limits(),
    )
  #(f, entered)
}

fn cancel_blocked(path: String, failure: String) {
  let #(f, entered) = blocked(failure, path)
  let previous = material(os.epoch_ms() + 3_600_000)
  records.save(f.store, key("one"), previous) |> should.be_ok
  let assert Ok(before) = records.load_record(f.store, key("one"))
  coordinator.login(f.engine, f.auth, "one").status |> should.equal(202)
  let assert Ok(release) = process.receive(entered, 5000)
  let assert Ok(worker) = process.subject_owner(release)
  let monitor = process.monitor(worker)
  coordinator.cancel(f.engine, f.auth, "one").status |> should.equal(200)
  let final = phase(f, "one", "cancelled", 500)
  ir.field(final, "user_code") |> should.equal(None)
  let assert Ok(after) = records.load_record(f.store, key("one"))
  { records.revision(before) != records.revision(after) } |> should.be_true
  records.record_material(after) |> should.equal(previous)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(5000)
  |> should.be_ok
  process.send(release, Nil)
  records.load(f.store, key("one")) |> should.equal(Ok(previous))
  coordinator.stop(f.engine) |> should.be_ok
}

pub fn cancel_discovery_and_start_test() {
  cancel_blocked("/discovery", "success")
  cancel_blocked("/device", "success")
}

pub fn cancel_pending_poll_and_authorized_exchange_test() {
  cancel_blocked("/token", "pending")
  cancel_blocked("/token", "success")
}

pub fn same_token_admin_replacement_and_delete_defeat_late_grant_test() {
  list.each(["same", "replace", "delete"], fn(action) {
    let #(f, entered) = blocked("success", "/token")
    let previous = material(os.epoch_ms() + 3_600_000)
    records.save(f.store, key("one"), previous) |> should.be_ok
    coordinator.login(f.engine, f.auth, "one").status |> should.equal(202)
    let assert Ok(release) = process.receive(entered, 5000)
    let winner = case action {
      "replace" -> {
        let assert c.OAuth(data) = material(os.epoch_ms() + 7_200_000)
        c.OAuth(
          c.OAuthData(
            ..data,
            credential: auth.Credential(
              "synthetic-new-admin-access",
              "synthetic-new-admin-refresh",
              data.credential.expires_at_ms,
            ),
          ),
        )
      }
      _ -> previous
    }
    case action {
      "delete" -> records.delete(f.store, key("one")) |> should.be_ok
      _ -> records.save(f.store, key("one"), winner) |> should.be_ok
    }
    process.send(release, Nil)
    phase(f, "one", "installation_unconfirmed", 500)
    case action {
      "delete" -> {
        let _ = records.load(f.store, key("one")) |> should.be_error
        Nil
      }
      _ -> records.load(f.store, key("one")) |> should.equal(Ok(winner))
    }
    records.load(f.store, key("two")) |> should.be_error
    coordinator.stop(f.engine) |> should.be_ok
  })
}

pub fn expiry_during_start_and_exchange_never_installs_test() {
  list.each(["/device", "/token"], fn(path) {
    let #(f, entered) = blocked("success", path)
    coordinator.login(f.engine, f.auth, "one").status |> should.equal(202)
    let assert Ok(release) = process.receive(entered, 5000)
    clock_set(f.clock, -94_999)
    process.send(release, Nil)
    phase(f, "one", "expired", 500)
    records.load(f.store, key("one")) |> should.be_error
    coordinator.stop(f.engine) |> should.be_ok
  })
}

pub fn session_expiry_logout_and_restart_cancel_pending_and_reject_old_session_test() {
  list.each(["expiry", "logout", "restart"], fn(action) {
    let #(f, entered) = blocked("pending", "/token")
    coordinator.login(f.engine, f.auth, "one").status |> should.equal(202)
    let assert Ok(release) = process.receive(entered, 5000)
    case action {
      "expiry" -> {
        clock_set(f.clock, -89_999)
        coordinator.status(f.engine, f.auth).status |> should.equal(401)
        coordinator.stop(f.engine) |> should.be_ok
      }
      "logout" -> {
        coordinator.logout(f.engine, f.auth).status |> should.equal(200)
        coordinator.status(f.engine, f.auth).status |> should.equal(401)
        coordinator.stop(f.engine) |> should.be_ok
      }
      _ -> {
        coordinator.stop(f.engine) |> should.be_ok
        let next = start(f.store, f.clock, synthetic, limits())
        coordinator.status(next.engine, f.auth).status |> should.equal(401)
        coordinator.stop(next.engine) |> should.be_ok
      }
    }
    process.send(release, Nil)
    records.load(f.store, key("one")) |> should.be_error
  })
}

pub fn occupied_s5_slot_prevents_discovery_or_device_io_test() {
  let called = process.new_subject()
  let f =
    fixture(
      fn(plan) {
        process.send(called, Nil)
        synthetic(plan)
      },
      limits(),
    )
  let assert Ok(ticket) = records.begin_enrollment(f.store, key("one"))
  coordinator.login(f.engine, f.auth, "one").status |> should.equal(409)
  process.receive(called, 0) |> should.be_error
  records.cancel_enrollment(ticket) |> should.be_ok
  coordinator.stop(f.engine) |> should.be_ok
}

pub fn existing_manager_rotates_and_observes_same_token_admin_save_and_delete_test() {
  let f = fixture(synthetic, limits())
  coordinator.login(f.engine, f.auth, "one").status |> should.equal(202)
  phase(f, "one", "stored", 500)
  let calls = process.new_subject()
  let policy =
    bridge.oauth_policy(oauth_config(), fn(plan) {
      let assert Ok(fields) = uri.parse_query(plan.body)
      list.key_find(fields, "grant_type") |> should.equal(Ok("refresh_token"))
      process.send(calls, Nil)
      reply(
        200,
        "{\"access_token\":\"synthetic-rotated-access\",\"refresh_token\":\"synthetic-rotated-refresh\",\"expires_in\":3600}",
      )
    })
  let assert Ok(manager) = credentials.start(f.store, key("one"), policy)
  let assert Ok(#(rotated, revision)) = credentials.acquire_versioned(manager)
  process.receive(calls, 0) |> should.equal(Ok(Nil))
  credentials.acquire(manager) |> should.equal(Ok(rotated))
  process.receive(calls, 0) |> should.be_error
  records.save(f.store, key("one"), rotated) |> should.be_ok
  let assert Ok(#(same, replacement)) = credentials.acquire_versioned(manager)
  same |> should.equal(rotated)
  { replacement != revision } |> should.be_true
  records.delete(f.store, key("one")) |> should.be_ok
  credentials.acquire(manager) |> should.be_error
  records.load(f.store, key("two")) |> should.be_error
  credentials.stop(manager)
  coordinator.stop(f.engine) |> should.be_ok
}

pub fn unknown_refresh_outcome_is_durably_fenced_without_retry_test() {
  let assert Ok(store) = storage.new(directory())
  records.save(store, key("one"), material(1)) |> should.be_ok
  let calls = process.new_subject()
  let policy =
    bridge.oauth_policy(oauth_config(), fn(_) {
      process.send(calls, Nil)
      Error("synthetic transport lost after possible rotation")
    })
  let assert Ok(manager) = credentials.start(store, key("one"), policy)
  credentials.acquire(manager) |> should.be_error
  process.receive(calls, 0) |> should.equal(Ok(Nil))
  let assert Ok(record) = records.load_record(store, key("one"))
  records.record_status(record) |> should.equal(records.NeedsReauthorization)
  credentials.acquire(manager) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  credentials.stop(manager)
  let assert Ok(restarted) = credentials.start(store, key("one"), policy)
  credentials.acquire(restarted) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  credentials.stop(restarted)
}

pub fn provider_revocation_invalid_grant_requires_explicit_reauthorization_test() {
  let assert Ok(store) = storage.new(directory())
  records.save(store, key("one"), material(1)) |> should.be_ok
  let called = process.new_subject()
  let policy =
    bridge.oauth_policy(oauth_config(), fn(_) {
      process.send(called, Nil)
      reply(
        400,
        "{\"error\":\"invalid_grant\",\"error_description\":\"private synthetic detail\"}",
      )
    })
  let assert Ok(manager) = credentials.start(store, key("one"), policy)
  credentials.acquire(manager)
  |> should.equal(Error(c.Failure(c.ReauthorizationRequired, c.NotSent, None)))
  process.receive(called, 0) |> should.equal(Ok(Nil))
  credentials.acquire(manager) |> should.be_error
  process.receive(called, 0) |> should.be_error
  let assert Ok(record) = records.load_record(store, key("one"))
  records.record_status(record) |> should.equal(records.NeedsReauthorization)
  credentials.stop(manager)
}
