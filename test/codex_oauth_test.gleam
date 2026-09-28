import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleeunit/should
import mimic/auth/crypto
import mimic/ir
import mimic/providers/codex/oauth

fn config() {
  oauth.Config(
    "http://127.0.0.1:1455/authorize",
    "http://127.0.0.1:1455/token",
    "http://localhost:1455/auth/callback",
  )
}

fn query(url: String) {
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(query) = parsed.query
  let assert Ok(fields) = uri.parse_query(query)
  fields
}

fn get(fields: List(#(String, String)), key: String) {
  let assert Ok(#(_, value)) = list.find(fields, fn(pair) { pair.0 == key })
  value
}

fn id_token(account: String) {
  let payload =
    ir.Object([
      #(
        "https://api.openai.com/auth",
        ir.Object([#("chatgpt_account_id", ir.String(account))]),
      ),
    ])
  "synthetic."
  <> {
    ir.stringify(payload)
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  }
  <> ".not-a-signature"
}

fn token_body(account: String) {
  ir.stringify(
    ir.Object([
      #("access_token", ir.String("synthetic-access")),
      #("refresh_token", ir.String("synthetic-refresh")),
      #("expires_in", ir.Integer(3600)),
      #("id_token", ir.String(id_token(account))),
    ]),
  )
}

pub fn codex_oauth_pkce_and_mock_exchange_test() {
  let assert Ok(login) = oauth.begin_login(config(), 1000)
  let fields = query(oauth.authorization_url(login))
  get(fields, "client_id") |> should.equal(oauth.client_id)
  get(fields, "scope") |> should.equal("openid email profile offline_access")
  get(fields, "codex_cli_simplified_flow") |> should.equal("true")
  get(fields, "id_token_add_organizations") |> should.equal("true")
  get(fields, "prompt") |> should.equal("login")
  get(fields, "code_challenge_method") |> should.equal("S256")
  let callback =
    uri.query_to_string([
      #("state", get(fields, "state")),
      #("code", "synthetic+code&"),
    ])
  let assert Ok(request) =
    oauth.exchange_request(config(), login, callback, 1001)
  let assert Ok(form) = uri.parse_query(request.body)
  get(form, "code") |> should.equal("synthetic+code&")
  get(form, "grant_type") |> should.equal("authorization_code")
  get(form, "code_verifier")
  |> crypto.pkce_challenge
  |> should.equal(get(fields, "code_challenge"))
  // Mock token endpoint: no real provider traffic.
  let assert Ok(tokens) =
    oauth.decode_tokens(200, token_body("synthetic-account"), None, 1001)
  tokens.account_id |> should.equal("synthetic-account")
  tokens.credential.expires_at_ms |> should.equal(3_601_001)
}

pub fn codex_callback_rejects_state_expiry_duplicates_and_config_swap_test() {
  let assert Ok(login) = oauth.begin_login(config(), 1000)
  let state = query(oauth.authorization_url(login)) |> get("state")
  oauth.exchange_request(config(), login, "code=synthetic&state=wrong", 1001)
  |> should.be_error
  let callback = "code=synthetic&state=" <> state
  oauth.exchange_request(config(), login, callback, 301_000) |> should.be_error
  oauth.exchange_request(config(), login, callback, 999) |> should.be_error
  oauth.exchange_request(config(), login, callback <> "&state=" <> state, 1001)
  |> should.be_error
  oauth.exchange_request(
    config(),
    login,
    callback <> "&error=access_denied",
    1001,
  )
  |> should.be_error
  oauth.exchange_request(
    oauth.Config(..config(), token_url: "https://different.invalid/token"),
    login,
    callback,
    1001,
  )
  |> should.be_error
}

pub fn codex_oauth_rejects_non_loopback_callback_and_insecure_endpoint_test() {
  oauth.begin_login(
    oauth.Config(..config(), token_url: "http://provider.invalid/token"),
    0,
  )
  |> should.be_error
  oauth.begin_login(
    oauth.Config(..config(), redirect_uri: "https://provider.invalid/callback"),
    0,
  )
  |> should.be_error
  oauth.begin_login(
    oauth.Config(
      ..config(),
      token_url: "https://user:secret@provider.invalid/token",
    ),
    0,
  )
  |> should.be_error
}

pub fn codex_mock_refresh_rotation_omission_and_account_binding_test() {
  let assert Ok(old) =
    oauth.decode_tokens(200, token_body("synthetic-account"), None, 0)
  let assert Ok(request) =
    oauth.refresh_request(config(), old.credential.refresh_token)
  let assert Ok(form) = uri.parse_query(request.body)
  get(form, "grant_type") |> should.equal("refresh_token")
  get(form, "scope") |> should.equal("openid profile email")
  let assert Ok(rotated) =
    oauth.decode_tokens(
      200,
      "{\"access_token\":\"synthetic-next\",\"refresh_token\":\"synthetic-rotated\",\"expires_in\":120}",
      Some(old),
      1000,
    )
  rotated.credential.refresh_token |> should.equal("synthetic-rotated")
  rotated.account_id |> should.equal(old.account_id)
  let assert Ok(retained) =
    oauth.decode_tokens(
      200,
      "{\"access_token\":\"synthetic-third\",\"expires_in\":60}",
      Some(rotated),
      2000,
    )
  retained.credential.refresh_token |> should.equal("synthetic-rotated")
  oauth.decode_tokens(200, token_body("other-account"), Some(old), 1000)
  |> should.equal(Error(oauth.InvalidResponse))
}

pub fn codex_mock_revoked_refresh_is_terminal_and_sanitized_test() {
  list.each(
    [
      "invalid_grant",
      "refresh_token_reused",
      "refresh_token_revoked",
      "refresh_token_expired",
    ],
    fn(code) {
      let body =
        "{\"error\":{\"code\":\""
        <> code
        <> "\",\"message\":\"synthetic-secret-must-not-escape\"}}"
      oauth.decode_tokens(400, body, None, 0)
      |> should.equal(Error(oauth.InvalidGrant))
    },
  )
  oauth.decode_tokens(
    400,
    "{\"error\":\"invalid_grant\",\"code\":\"refresh_token_reused\"}",
    None,
    0,
  )
  |> should.equal(Error(oauth.InvalidGrant))
  oauth.decode_tokens(503, "synthetic-secret", None, 0)
  |> should.equal(Error(oauth.Unavailable))
}

pub fn codex_malformed_refresh_fields_fail_closed_test() {
  let assert Ok(old) =
    oauth.decode_tokens(200, token_body("synthetic-account"), None, 0)
  list.each(
    [
      "{\"access_token\":\"\",\"expires_in\":60}",
      "{\"access_token\":\"synthetic\",\"expires_in\":0}",
      "{\"access_token\":\"synthetic\",\"expires_in\":60,\"refresh_token\":\"\"}",
      "{\"access_token\":\"synthetic\",\"expires_in\":60,\"refresh_token\":null}",
      "{\"access_token\":\"synthetic\",\"expires_in\":60,\"id_token\":\"bad\"}",
      "{\"access_token\":\"synthetic\",\"expires_in\":60,\"token_type\":\"MAC\"}",
      "{\"access_token\":\"synthetic\\r\\nHeader: bad\",\"expires_in\":60}",
    ],
    fn(body) {
      oauth.decode_tokens(200, body, Some(old), 1000)
      |> should.equal(Error(oauth.InvalidResponse))
    },
  )
  oauth.refresh_request(config(), "") |> should.be_error
  oauth.account_id("synthetic." <> string.repeat("!", 10) <> ".signature")
  |> should.be_error
}
