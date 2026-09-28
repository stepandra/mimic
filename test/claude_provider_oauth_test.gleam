import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleeunit/should
import mimic/auth
import mimic/auth/crypto
import mimic/ir
import mimic/providers/claude/json_guard
import mimic/providers/claude/oauth
import mimic/types.{Header}
import mist

fn config(port: Int) {
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  auth.claude_config(
    "synthetic-client",
    origin <> "/authorize",
    origin <> "/token",
    "http://127.0.0.1:9222/callback",
  )
}

fn previous() {
  oauth.Tokens(
    auth.Credential("synthetic-old", "synthetic-refresh", 0),
    oauth.Identity(Some("synthetic-account"), Some("synthetic-org")),
  )
}

pub fn pkce_and_callback_validation_test() {
  let cfg = config(19_444)
  let assert Ok(login) = oauth.begin(cfg, "synthetic")
  let assert Ok(uri.Uri(query: Some(query), ..)) = uri.parse(login.url)
  let assert Ok(query) = uri.parse_query(query)
  list.key_find(query, "code") |> should.equal(Ok("true"))
  list.key_find(query, "code_challenge")
  |> should.equal(Ok(crypto.pkce_challenge(login.verifier)))
  list.key_find(query, "code_challenge_method") |> should.equal(Ok("S256"))
  let never = fn(_) { panic as "Invalid callback must not invoke transport" }
  oauth.exchange(cfg, login, "wrong", "synthetic-code", 1000, never)
  |> should.equal(Error(oauth.InvalidCallback))
  oauth.exchange(cfg, login, login.state, "synthetic-code#wrong", 1000, never)
  |> should.equal(Error(oauth.InvalidCallback))
  let assert Ok(req) =
    oauth.exchange_request(
      cfg,
      login,
      login.state,
      "synthetic-code#" <> login.state,
    )
  req.headers
  |> should.equal([
    Header("Content-Type", "application/json"),
    Header("Accept", "application/json"),
  ])
  let assert Ok(body) = ir.parse(req.body)
  ir.string_field(body, "code") |> should.equal(Ok("synthetic-code"))
  ir.string_field(body, "state") |> should.equal(Ok(login.state))
  ir.string_field(body, "code_verifier") |> should.equal(Ok(login.verifier))
  ir.string_field(body, "grant_type") |> should.equal(Ok("authorization_code"))
  string.starts_with(req.body, "{\"grant_type\":") |> should.be_true
}

pub fn local_json_exchange_refresh_and_429_test() {
  let started = process.new_subject()
  let observed = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    let assert Ok(body) = bit_array.to_string(req.body)
    let assert Ok(value) = ir.parse(body)
    let assert Ok(grant) = ir.string_field(value, "grant_type")
    process.send(observed, #(grant, req.headers, value))
    let #(status, headers, body) = case grant {
      "authorization_code" -> #(
        200,
        [],
        "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"account\":{\"uuid\":\"synthetic-account\"},\"organization\":{\"uuid\":\"synthetic-org\"}}",
      )
      "refresh_token" ->
        case ir.string_field(value, "refresh_token") {
          Ok("synthetic-limited") -> #(
            429,
            [#("retry-after", "17")],
            "{\"error\":\"synthetic-sensitive-error\"}",
          )
          _ -> #(
            200,
            [],
            "{\"access_token\":\"synthetic-new\",\"expires_in\":7200}",
          )
        }
      _ -> #(400, [], "{}")
    }
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
  let cfg = config(port)
  let assert Ok(login) = oauth.begin(cfg, "synthetic-local")
  let assert Ok(tokens) =
    oauth.exchange(cfg, login, login.state, "synthetic-code", 1000, send_local)
  tokens.credential.expires_at_ms |> should.equal(3_601_000)
  tokens.identity |> should.equal(previous().identity)
  let assert Ok(#("authorization_code", headers, _)) =
    process.receive(observed, 5000)
  list.key_find(headers, "content-type") |> should.equal(Ok("application/json"))
  let assert Ok(new) = oauth.refresh(cfg, tokens, 2000, send_local)
  new.credential
  |> should.equal(auth.Credential(
    "synthetic-new",
    "synthetic-refresh",
    7_202_000,
  ))
  new.identity |> should.equal(tokens.identity)
  let assert Ok(#("refresh_token", _, value)) = process.receive(observed, 5000)
  ir.string_field(value, "scope")
  |> should.equal(Ok(string.join(cfg.scopes, " ")))
  let limited =
    oauth.Tokens(
      auth.Credential("synthetic", "synthetic-limited", 0),
      tokens.identity,
    )
  oauth.refresh(cfg, limited, 3000, send_local)
  |> should.equal(Error(oauth.RateLimited(17_000)))
  let assert Ok(#("refresh_token", _, _)) = process.receive(observed, 5000)
  // The adapter performs exactly one exchange and never retries a 429 itself.
  process.receive(observed, 50) |> should.equal(Error(Nil))
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

fn send_local(req: oauth.TokenRequest) -> Result(oauth.TokenResponse, String) {
  use request <- result.try(
    request.to(req.url) |> result.map_error(fn(_) { "Synthetic URL failure" }),
  )
  let request =
    request
    |> request.set_method(http.Post)
    |> request.set_body(req.body)
  let request =
    list.fold(req.headers, request, fn(req, header) {
      request.set_header(req, header.name, header.value)
    })
  use response <- result.try(
    httpc.send(request)
    |> result.map_error(fn(_) { "Synthetic transport failure" }),
  )
  Ok(oauth.TokenResponse(
    response.status,
    list.map(response.headers, fn(h) { Header(h.0, h.1) }),
    response.body,
  ))
}

pub fn refresh_rotation_identity_and_invalid_response_test() {
  let response =
    oauth.TokenResponse(
      200,
      [],
      "{\"access_token\":\"synthetic-new\",\"refresh_token\":\"synthetic-rotated\",\"expires_in\":1}",
    )
  let assert Ok(rotated) = oauth.parse_tokens(response, previous(), 2000)
  rotated.credential
  |> should.equal(auth.Credential("synthetic-new", "synthetic-rotated", 3000))
  rotated.identity |> should.equal(previous().identity)
  let changed =
    oauth.TokenResponse(
      200,
      [],
      "{\"access_token\":\"synthetic-new\",\"expires_in\":60,\"account\":{\"uuid\":\"different-account\"}}",
    )
  oauth.parse_tokens(changed, previous(), 0)
  |> should.equal(Error(oauth.IdentityChanged))
  list.each(
    [
      "{}", "{\"access_token\":\"\",\"expires_in\":3600}",
      "{\"access_token\":\"synthetic\",\"expires_in\":0}",
      "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"account\":17}",
      "{\"access_token\":\"synthetic\",\"expires_in\":\"3600\"}",
    ],
    fn(body) {
      oauth.parse_tokens(oauth.TokenResponse(200, [], body), previous(), 0)
      |> should.equal(Error(oauth.InvalidResponse))
    },
  )
}

pub fn sanitized_failure_and_cooldown_test() {
  oauth.parse_tokens(
    oauth.TokenResponse(
      400,
      [],
      "{\"error\":\"invalid_grant\",\"description\":\"synthetic-secret\"}",
    ),
    previous(),
    0,
  )
  |> should.equal(Error(oauth.InvalidGrant))
  oauth.parse_tokens(
    oauth.TokenResponse(500, [], "synthetic-secret"),
    previous(),
    0,
  )
  |> should.equal(Error(oauth.InvalidResponse))
  oauth.refresh(config(19_444), previous(), 0, fn(_) {
    Error("synthetic-access synthetic-refresh")
  })
  |> should.equal(Error(oauth.Unavailable))
  oauth.retry_after([Header("Retry-After", "1")]) |> should.equal(5000)
  oauth.retry_after([Header("Retry-After", "9999")]) |> should.equal(300_000)
  oauth.retry_after([Header("Retry-After-Ms", "12345")]) |> should.equal(12_345)
  oauth.retry_after([]) |> should.equal(5000)
  oauth.refresh_request(config(19_444), "")
  |> should.equal(Error(oauth.InvalidGrant))
}

pub fn token_exchange_requires_refresh_token_test() {
  let empty =
    oauth.Tokens(auth.Credential("", "", 0), oauth.Identity(None, None))
  oauth.parse_tokens(
    oauth.TokenResponse(
      200,
      [],
      "{\"access_token\":\"synthetic\",\"expires_in\":10}",
    ),
    empty,
    0,
  )
  |> should.equal(Error(oauth.InvalidResponse))
}

pub fn ambiguous_token_success_is_rejected_test() {
  list.each(
    [
      "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"refresh_token\":\"synthetic-stale\",\"refresh_token\":\"synthetic-new\"}",
      "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"refresh_token\":\"synthetic-stale\",\"\\u0072efresh_token\":\"synthetic-new\"}",
      "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"account\":{\"uuid\":\"synthetic-account\",\"uuid\":\"different-account\"}}",
      "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"extra\":[{\"a/b\":1,\"a\\/b\":2}]}",
      "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"error\":\"rate_limit_error\"}",
    ],
    fn(body) {
      oauth.parse_tokens(oauth.TokenResponse(200, [], body), previous(), 0)
      |> should.equal(Error(oauth.InvalidResponse))
    },
  )
}

pub fn ambiguous_oauth_rejection_is_not_retryable_test() {
  list.each(
    [
      "{\"error\":\"rate_limit_error\",\"error\":\"invalid_grant\"}",
      "{\"error\":\"rate_limit_error\",\"\\u0065rror\":\"invalid_grant\"}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"type\":\"invalid_grant\"}}",
      "{\"error\":\"rate_limit_error\",\"refresh_token\":\"synthetic-maybe-rotated\"}",
    ],
    fn(body) {
      oauth.parse_tokens(
        oauth.TokenResponse(429, [Header("Retry-After", "17")], body),
        previous(),
        0,
      )
      |> should.equal(Error(oauth.InvalidResponse))
    },
  )
}

pub fn oauth_json_guard_unicode_and_object_scopes_test() {
  list.each(
    [
      "{\"é\":1,\"\\u00e9\":2}",
      "{\"😀\":1,\"\\ud83d\\ude00\":2}",
      "{\"\\\"\":1,\"\\u0022\":2}",
      "{\"\\\\\":1,\"\\u005c\":2}",
      "{\"\":1,\"\":2}",
    ],
    fn(body) { json_guard.parse(body) |> should.be_error },
  )
  let string_content =
    ir.stringify(
      ir.Object([
        #("text", ir.String("{\"same\":1,\"same\":2} \\ \" synthetic")),
        #("other", ir.Array([ir.Object([#("same", ir.Integer(3))])])),
      ]),
    )
  list.each(
    [
      "{\"left\":{\"same\":1},\"right\":{\"same\":2}}",
      "[{\"same\":1},{\"same\":2}]",
      "{\"Error\":true,\"error\":null,\"é\":1,\"e\\u0301\":-2.5e-2}",
      string_content,
    ],
    fn(body) { json_guard.parse(body) |> should.equal(ir.parse(body)) },
  )
}

pub fn oauth_json_guard_byte_depth_and_value_bounds_test() {
  let bounded =
    "{\"x\":\"" <> string.repeat("x", json_guard.max_bytes - 8) <> "\"}"
  string.byte_size(bounded) |> should.equal(json_guard.max_bytes)
  json_guard.parse(bounded) |> should.be_ok
  json_guard.parse(bounded <> " ") |> should.be_error
  let nested = fn(depth) {
    string.repeat("[", depth) <> "0" <> string.repeat("]", depth)
  }
  json_guard.parse(nested(json_guard.max_depth)) |> should.be_ok
  json_guard.parse(nested(json_guard.max_depth + 1)) |> should.be_error
  let empty_nested = fn(depth) {
    string.repeat("[", depth) <> string.repeat("]", depth)
  }
  json_guard.parse(empty_nested(json_guard.max_depth)) |> should.be_ok
  json_guard.parse(empty_nested(json_guard.max_depth + 1)) |> should.be_error
  let many = fn(count) {
    "[" <> string.join(list.repeat("0", count), ",") <> "]"
  }
  json_guard.parse(many(json_guard.max_values - 1)) |> should.be_ok
  json_guard.parse(many(json_guard.max_values)) |> should.be_error
}

pub fn oauth_json_guard_malformed_and_exchange_boundaries_test() {
  list.each(
    [
      "", "{}", "{\"x\":1,}", "[1,]", "{\"x\" 1}", "{\"x\":\"unterminated}",
      "{\"x\":\"\\q\"}", "{\"x\":NaN}", "{\"x\":01}", "{\"x\":true} trailing",
      "{\"x\":\"a\nb\"}", "[true]", "null",
    ],
    fn(body) {
      // Even a status-429 response must have a valid object before it can
      // become retryable. An empty object is valid, so test it only at 200.
      let status = case body {
        "{}" -> 200
        _ -> 429
      }
      oauth.parse_tokens(oauth.TokenResponse(status, [], body), previous(), 0)
      |> should.equal(Error(oauth.InvalidResponse))
    },
  )
  let cfg = config(19_444)
  let assert Ok(login) = oauth.begin(cfg, "synthetic")
  let ambiguous =
    "{\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic-stale\",\"refresh_token\":\"synthetic-new\",\"expires_in\":3600}"
  oauth.exchange(cfg, login, login.state, "synthetic-code", 0, fn(_) {
    Ok(oauth.TokenResponse(200, [], ambiguous))
  })
  |> should.equal(Error(oauth.InvalidResponse))
}
