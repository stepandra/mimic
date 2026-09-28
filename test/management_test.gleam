import gleam/bit_array
import gleam/http.{Delete, Get, Post, Put}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import mimic/management.{type Backend, Backend, CredentialMetadata}

const key = "synthetic-management-key-123456789012345"

pub fn main() {
  gleeunit.main()
}

fn backend() -> Backend {
  Backend(
    create_persona: fn(_provider, _content) { Ok("synthetic-digest") },
    active_persona: fn(_provider) { Ok("synthetic-active") },
    promote: fn(_run, _sig) { Ok(Nil) },
    credentials: fn() { Ok([CredentialMetadata("credential-a", 1234)]) },
    create_credential: fn(_input) { Ok(Nil) },
    delete_credential: fn(_id) { Ok(Nil) },
    keys: fn() { Ok(["key-a"]) },
    create_key: fn(_id, _secret) { Ok(Nil) },
    delete_key: fn(_id) { Ok(Nil) },
    quotas: fn() { Ok([#("credential-a", 12)]) },
    drift: fn() { Ok([#("synthetic", 3)]) },
  )
}

fn forbidden_backend() -> Backend {
  Backend(
    create_persona: fn(_, _) { panic as "unauthorized persona write" },
    active_persona: fn(_) { panic as "unauthorized read" },
    promote: fn(_, _) { panic as "unauthorized promotion" },
    credentials: fn() { panic as "unauthorized read" },
    create_credential: fn(_) { panic as "unauthorized credential write" },
    delete_credential: fn(_) { panic as "unauthorized credential delete" },
    keys: fn() { panic as "unauthorized read" },
    create_key: fn(_, _) { panic as "unauthorized key write" },
    delete_key: fn(_) { panic as "unauthorized key delete" },
    quotas: fn() { panic as "unauthorized read" },
    drift: fn() { panic as "unauthorized read" },
  )
}

fn req(method, path, body, authorized, content_type) {
  let base = request.new()
  let headers = case authorized {
    True -> [#("authorization", "Bearer " <> key)]
    False -> []
  }
  let headers = case content_type {
    True -> [#("content-type", "application/json"), ..headers]
    False -> headers
  }
  request.Request(
    ..base,
    method:,
    host: "127.0.0.1",
    path:,
    body: bit_array.from_string(body),
    headers:,
  )
}

pub fn unauthorized_writes_never_touch_backend_test() {
  let writes = [
    req(
      Put,
      "/api/personas/anthropic/drafts",
      "{\"content\":\"draft\"}",
      False,
      True,
    ),
    req(
      Post,
      "/api/promotions",
      "{\"run_id\":\"run\",\"signature\":\"synthetic\"}",
      False,
      True,
    ),
    req(
      Post,
      "/api/credentials",
      "{\"id\":\"a\",\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic\",\"expires_at_ms\":1}",
      False,
      True,
    ),
    req(Delete, "/api/credentials/a", "", False, False),
    req(
      Post,
      "/api/keys",
      "{\"id\":\"a\",\"token\":\"synthetic-key-123456789012345678901\"}",
      False,
      True,
    ),
    req(Delete, "/api/keys/a", "", False, False),
  ]
  writes
  |> list.each(fn(write) {
    management.handle(write, key, 4199, forbidden_backend()).status
    |> should.equal(401)
  })
}

pub fn secret_values_never_echo_test() {
  let body =
    "{\"id\":\"a\",\"access_token\":\"synthetic-access-token\",\"refresh_token\":\"synthetic-refresh-token\",\"expires_at_ms\":1}"
  let created =
    management.handle(
      req(Post, "/api/credentials", body, True, True),
      key,
      4199,
      backend(),
    )
  created.status |> should.equal(201)
  string.contains(created.body, "synthetic-access-token") |> should.be_false()
  let listed =
    management.handle(
      req(Get, "/api/credentials", "", True, False),
      key,
      4199,
      backend(),
    )
  string.contains(listed.body, "access_token") |> should.be_false()
  let created_key =
    management.handle(
      req(
        Post,
        "/api/keys",
        "{\"id\":\"a\",\"token\":\"synthetic-secret-12345678901234567890\"}",
        True,
        True,
      ),
      key,
      4199,
      backend(),
    )
  string.contains(created_key.body, "synthetic-secret") |> should.be_false()
}

pub fn content_type_origin_and_path_validation_test() {
  let write =
    req(
      Post,
      "/api/keys",
      "{\"id\":\"a\",\"token\":\"synthetic-secret-12345678901234567890\"}",
      True,
      False,
    )
  management.handle(write, key, 4199, forbidden_backend()).status
  |> should.equal(415)
  let write =
    req(Post, "/api/keys", "{}", True, True)
    |> request.set_header("origin", "https://attacker.example")
  management.handle(write, key, 4199, forbidden_backend()).status
  |> should.equal(403)
  management.handle(
    req(Delete, "/api/keys/%2e%2e", "", True, False),
    key,
    4199,
    forbidden_backend(),
  ).status
  |> should.equal(400)
  management.valid_id("../x") |> should.be_false()
  let extra =
    req(
      Post,
      "/api/keys",
      "{\"id\":\"a\",\"token\":\"synthetic-secret-12345678901234567890\",\"unknown\":true}",
      True,
      True,
    )
  management.handle(extra, key, 4199, forbidden_backend()).status
  |> should.equal(400)
  let bad_host =
    req(Get, "/api/health", "", True, False)
    |> fn(req) { request.Request(..req, host: "attacker.example") }
  management.handle(bad_host, key, 4199, forbidden_backend()).status
  |> should.equal(400)
}

pub fn approved_promotion_and_draft_are_distinct_test() {
  let draft =
    req(
      Put,
      "/api/personas/anthropic/drafts",
      "{\"content\":\"synthetic persona\"}",
      True,
      True,
    )
  let result = management.handle(draft, key, 4199, backend())
  result.status |> should.equal(201)
  string.contains(result.body, "synthetic-digest") |> should.be_true()
  let active =
    management.handle(
      req(Get, "/api/personas/anthropic/active", "", True, False),
      key,
      4199,
      backend(),
    )
  string.contains(active.body, "synthetic-active") |> should.be_true()
  let promotion =
    req(
      Post,
      "/api/promotions",
      "{\"run_id\":\"approved\",\"signature\":\"synthetic-signature\"}",
      True,
      True,
    )
  management.handle(promotion, key, 4199, backend()).status |> should.equal(200)
}

pub fn vendored_panel_has_security_headers_test() {
  let page =
    management.handle(
      req(Get, "/", "", False, False),
      key,
      4199,
      forbidden_backend(),
    )
  page.status |> should.equal(200)
  string.contains(page.body, "/panel.js") |> should.be_true()
  let assert Ok(csp) = response.get_header(page, "content-security-policy")
  string.contains(csp, "default-src 'none'") |> should.be_true()
}
