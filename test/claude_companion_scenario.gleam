/// Actual local sockets and root Messages route, with synthetic credentials and
/// source-derived control-plane fixtures. NOT a root CLI companion-config smoke
/// (coordinator wiring is still required), native test or live qualification.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credential
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/gateway
import mimic/gateway/config
import mimic/gateway/refresh
import mimic/ir
import mimic/providers/claude/companion
import mimic/providers/claude/json_guard
import mimic/providers/claude/login
import mimic/providers/contracts
import mist

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_test_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "mimic_gateway_test_ffi", "private_file")
fn private_file(directory: String, name: String, contents: String) -> String

type Case {
  Reconciled
  AdvisoryProfile
  AdvisoryRoles
  AdvisoryBoth
  MissingAccount
  Conflict
  WrongMedia
  EncodedProfile
  DuplicateProfile
  OversizedProfile
  ReplaceAtProfile
  ReplaceAtRoles
  TokenWrongMedia
  TokenEncoding
  TokenDuplicate
  TokenOversized
  RolesWrongMedia
  RolesEncoding
  RolesDuplicate
  RolesOversized
}

const profile = "{\"account\":{\"uuid\":\"synthetic-account\",\"email\":\"synthetic-private-email\"},\"organization\":{\"uuid\":\"synthetic-org\",\"name\":\"synthetic-private-name\"},\"device_id\":\"synthetic-not-a-device\"}"

const roles = "[{\"opaque\":\"synthetic-private-role\",\"account_uuid\":\"synthetic-not-an-account\",\"device_id\":\"synthetic-not-a-device\"}]"

const token = "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"device_id\":\"synthetic-not-a-device\"}"

const client = "synthetic-f08-client-123456789"

const model = "synthetic-claude"

pub fn main() {
  local_workflow()
  local_guarded_workflow()
  io.println(
    "PASS: F08 synthetic loopback exchange/profile/roles and root Messages route; root CLI companion configuration remains outstanding",
  )
}

pub fn local_workflow() {
  list.each(
    [
      Reconciled, AdvisoryProfile, AdvisoryRoles, AdvisoryBoth, MissingAccount,
      Conflict, WrongMedia, EncodedProfile, DuplicateProfile, OversizedProfile,
      ReplaceAtProfile, ReplaceAtRoles,
    ],
    run_case,
  )
}

pub fn local_guarded_workflow() {
  list.each(
    [
      TokenWrongMedia, TokenEncoding, TokenDuplicate, TokenOversized,
      RolesWrongMedia, RolesEncoding, RolesDuplicate, RolesOversized,
    ],
    run_case,
  )
}

fn token_failure(case_: Case) {
  case case_ {
    TokenWrongMedia | TokenEncoding | TokenDuplicate | TokenOversized -> True
    _ -> False
  }
}

fn admin() {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(
        "synthetic-admin",
        "synthetic-admin-refresh",
        9_000_000_000_000,
      ),
      [
        #("device_id", string.repeat("a", 64)),
        #("account_uuid", "synthetic-account"),
      ],
    ),
  )
}

fn run_case(case_: Case) {
  let dir = directory()
  let assert Ok(store) = storage.new(dir)
  let key = credential.key("claude", "oauth", "synthetic-slot")
  let started = process.new_subject()
  let observed = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    let valid = case req.path {
      "/token" -> {
        let parsed = {
          use body <- result.try(
            bit_array.to_string(req.body)
            |> result.replace_error("Synthetic invalid UTF-8"),
          )
          use value <- result.try(json_guard.parse(body))
          Ok(
            req.method == http.Post
            && string.starts_with(
              body,
              "{\"grant_type\":\"authorization_code\",\"code\":",
            )
            && ir.string_field(value, "code") == Ok("synthetic-code")
            && ir.string_field(value, "client_id") == Ok("synthetic-client")
            && ir.string_field(value, "grant_type") == Ok("authorization_code"),
          )
        }
        parsed |> result.unwrap(False)
      }
      "/profile" | "/roles" ->
        req.method == http.Get
        && req.body == <<>>
        && list.key_find(req.headers, "authorization")
        == Ok("Bearer synthetic-access")
        && list.key_find(req.headers, "cache-control") == Ok("no-cache")
        && list.key_find(req.headers, "accept") == Ok("application/json")
        && list.key_find(req.headers, "content-type") == Ok("application/json")
        && list.key_find(req.headers, "accept-encoding") == Ok("identity")
        && list.key_find(req.headers, "connection") == Ok("close")
        && list.key_find(req.headers, "user-agent") == Error(Nil)
      "/v1/messages" -> {
        let parsed = {
          use body <- result.try(
            bit_array.to_string(req.body)
            |> result.replace_error("Synthetic invalid UTF-8"),
          )
          use body <- result.try(json_guard.parse_native(body, 8_388_608))
          use metadata <- result.try(ir.required(body, "metadata"))
          use user_id <- result.try(ir.string_field(metadata, "user_id"))
          use user_id <- result.try(json_guard.parse(user_id))
          Ok(
            req.method == http.Post
            && ir.string_field(user_id, "account_uuid")
            == Ok("synthetic-account")
            && ir.string_field(user_id, "device_id")
            == Ok(string.repeat("a", 64))
            && list.key_find(req.headers, "authorization")
            == Ok("Bearer synthetic-access"),
          )
        }
        parsed |> result.unwrap(False)
      }
      _ -> False
    }
    // No credentials, profile/roles data, PKCE verifier or callback state in
    // observations or failure output. Only path and boolean request conformance.
    process.send(observed, #(req.path, valid))
    case case_, req.path {
      ReplaceAtProfile, "/profile" | ReplaceAtRoles, "/roles" ->
        runtime_store.save(store, key, admin()) |> should.be_ok
      _, _ -> Nil
    }
    let #(status, headers, body) = reply(case_, req.path)
    response.Response(status, headers, mist.Bytes(bytes_tree.from_string(body)))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
    |> mist.read_request_body(
      bytes_limit: 8192,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(started, 5000)
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let callback_origin = "http://127.0.0.1:" <> int.to_string(free_port())
  let oauth =
    auth.claude_config(
      "synthetic-client",
      origin <> "/authorize",
      origin <> "/token",
      callback_origin <> "/callback",
    )
  let assert Ok(approved) =
    companion.approve(origin <> "/profile", origin <> "/roles", True)
  let identity =
    ir.Object([
      #("device_id", ir.String(string.repeat("a", 64))),
      ..case case_ {
        AdvisoryProfile
        | AdvisoryBoth
        | WrongMedia
        | EncodedProfile
        | DuplicateProfile
        | OversizedProfile -> [
          #("account_uuid", ir.String("synthetic-account")),
        ]
        Conflict -> [#("account_uuid", ir.String("synthetic-conflict"))]
        _ -> []
      }
    ])
  let outcome =
    login.run_with_companion(
      oauth,
      store,
      key,
      identity,
      5000,
      fn(url) { callback(oauth, url) },
      approved,
      login.Transports(refresh.claude, companion.send),
    )
  process.receive(observed, 5000) |> should.equal(Ok(#("/token", True)))
  case token_failure(case_) {
    True -> Nil
    False -> {
      process.receive(observed, 5000) |> should.equal(Ok(#("/profile", True)))
      process.receive(observed, 5000) |> should.equal(Ok(#("/roles", True)))
    }
  }
  case case_ {
    TokenWrongMedia | TokenEncoding | TokenDuplicate | TokenOversized -> {
      outcome |> should.equal(Error("Claude OAuth exchange failed"))
      storage.read_runtime_slot(store, key) |> should.equal(Ok(None))
    }
    MissingAccount -> {
      outcome |> should.equal(Error("Claude OAuth account identity required"))
      storage.read_runtime_slot(store, key) |> should.equal(Ok(None))
    }
    Conflict -> {
      outcome |> should.equal(Error("Claude OAuth identity mismatch"))
      storage.read_runtime_slot(store, key) |> should.equal(Ok(None))
    }
    ReplaceAtProfile | ReplaceAtRoles -> {
      outcome |> should.be_error
      { runtime_store.load(store, key) == Ok(admin()) } |> should.be_true
    }
    _ -> {
      outcome |> should.be_ok
      let assert Ok(contracts.OAuth(grant)) = runtime_store.load(store, key)
      { grant.credential.access_token == "synthetic-access" } |> should.be_true
      {
        grant.private_metadata
        == case case_ {
          Reconciled
          | AdvisoryRoles
          | RolesWrongMedia
          | RolesEncoding
          | RolesDuplicate
          | RolesOversized -> [
            #("device_id", string.repeat("a", 64)),
            #("account_uuid", "synthetic-account"),
            #("organization_uuid", "synthetic-org"),
          ]
          _ -> [
            #("device_id", string.repeat("a", 64)),
            #("account_uuid", "synthetic-account"),
          ]
        }
      }
      |> should.be_true
      root_route(dir, origin, oauth)
      process.receive(observed, 5000)
      |> should.equal(Ok(#("/v1/messages", True)))
    }
  }
  process.receive(observed, 0) |> should.be_error
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

fn reply(case_: Case, path: String) {
  let json = [#("content-type", "application/json")]
  case path, case_ {
    "/token", TokenWrongMedia -> #(200, [#("content-type", "text/html")], token)
    "/token", TokenEncoding -> #(
      200,
      [#("content-type", "application/json"), #("content-encoding", "gzip")],
      token,
    )
    "/token", TokenDuplicate -> #(
      200,
      json,
      "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"\\u0072efresh_token\":\"synthetic-conflict\",\"expires_in\":3600}",
    )
    "/token", TokenOversized -> #(
      200,
      json,
      "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"padding\":\""
        <> string.repeat("x", 65_536)
        <> "\"}",
    )
    "/token", _ -> #(200, json, token)
    "/profile", AdvisoryProfile | "/profile", AdvisoryBoth -> #(
      500,
      json,
      "{\"error\":\"synthetic-private-error\"}",
    )
    "/profile", WrongMedia -> #(200, [#("content-type", "text/html")], profile)
    "/profile", EncodedProfile -> #(
      200,
      [#("content-type", "application/json"), #("content-encoding", "gzip")],
      profile,
    )
    "/profile", DuplicateProfile -> #(
      200,
      json,
      "{\"account\":{\"uuid\":\"synthetic-account\",\"\\u0075uid\":\"synthetic-conflict\"}}",
    )
    "/profile", OversizedProfile -> #(
      200,
      json,
      "{\"account\":{\"uuid\":\"synthetic-account\"},\"padding\":\""
        <> string.repeat("x", 65_536)
        <> "\"}",
    )
    "/profile", MissingAccount -> #(200, json, "{}")
    "/profile", _ -> #(200, json, profile)
    "/roles", AdvisoryRoles | "/roles", AdvisoryBoth -> #(
      403,
      json,
      "{\"error\":\"synthetic-private-roles-error\"}",
    )
    "/roles", RolesWrongMedia -> #(200, [#("content-type", "text/html")], roles)
    "/roles", RolesEncoding -> #(
      200,
      [#("content-type", "application/json"), #("content-encoding", "gzip")],
      roles,
    )
    "/roles", RolesDuplicate -> #(
      200,
      json,
      "{\"opaque\":1,\"\\u006fpaque\":2}",
    )
    "/roles", RolesOversized -> #(
      200,
      json,
      "\"" <> string.repeat("x", 65_536) <> "\"",
    )
    "/roles", _ -> #(200, json, roles)
    "/v1/messages", _ -> #(
      200,
      json,
      "{\"id\":\"synthetic-message\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"synthetic-claude\",\"content\":[{\"type\":\"text\",\"text\":\"synthetic-ok\"}],\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
    )
    _, _ -> #(404, json, "{}")
  }
}

fn callback(config: auth.Config, url: String) {
  let assert Ok(uri.Uri(query: Some(query), ..)) = uri.parse(url)
  let assert Ok(pairs) = uri.parse_query(query)
  let assert Ok(state) = list.key_find(pairs, "state")
  let assert Ok(req) =
    request.to(
      config.redirect_uri <> "?state=" <> state <> "&code=synthetic-code",
    )
  let assert Ok(reply) = httpc.send(req)
  reply.status |> should.equal(200)
}

fn root_route(dir: String, origin: String, oauth: auth.Config) {
  let settings =
    ir.Object([
      #("version", ir.Integer(1)),
      #("state_dir", ir.String(dir)),
      #("listen_port", ir.Integer(0)),
      #(
        "accounts",
        ir.Array([
          ir.Object([
            #("provider", ir.String("claude")),
            #("auth_mode", ir.String("oauth")),
            #("id", ir.String("synthetic-slot")),
            #("origin", ir.String(origin)),
            #("models", ir.Array([ir.String(model)])),
            #(
              "oauth",
              ir.Object([
                #("client_id", ir.String(oauth.client_id)),
                #("authorize_url", ir.String(oauth.authorize_url)),
                #("token_url", ir.String(oauth.token_url)),
                #("redirect_uri", ir.String(oauth.redirect_uri)),
              ]),
            ),
          ]),
        ]),
      ),
    ])
    |> ir.stringify
  let path = private_file(dir, "synthetic-config.json", settings)
  let private_key = private_file(dir, "synthetic-client-key", client)
  gateway.cli(["key", "import", path, "synthetic-client", private_key])
  |> should.be_ok
  let assert Ok(settings) = config.decode(settings)
  let assert Ok(server) = gateway.start(settings)
  let body =
    "{\"model\":\"synthetic-claude\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":10,\"stream\":false}"
  // Complete on HTTP framing, not the raw helper's 5-second close/idle wait.
  let assert Ok(req) =
    request.to(
      "http://127.0.0.1:"
      <> int.to_string(gateway.port(server))
      <> "/v1/messages",
    )
  let assert Ok(reply) =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> client)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
    |> httpc.send
  reply.status |> should.equal(200)
  string.contains(reply.body, "synthetic-ok") |> should.be_true
  let public_response = reply.body <> string.inspect(reply.headers)
  list.each(
    [
      "synthetic-access",
      "synthetic-refresh",
      "synthetic-account",
      "synthetic-org",
      "synthetic-private",
      "synthetic-not-a-device",
    ],
    fn(private) { string.contains(public_response, private) |> should.be_false },
  )
  gateway.stop(server) |> should.be_ok
}
