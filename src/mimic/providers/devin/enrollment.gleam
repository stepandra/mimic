/// Private Devin enrollment. No endpoint is selected or contacted implicitly.
/// Pending PKCE values and token exchange plans must never be logged or captured.
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/auth/runtime_store
import mimic/auth/storage.{type Store}
import mimic/providers/contracts.{SessionToken}
import mimic/providers/devin/auth as devin_auth

pub type Config {
  Config(app_origin: String, api_origin: String, redirect_uri: String)
}

pub opaque type Pending {
  Pending(
    url: String,
    codes: devin_auth.Pkce,
    token_endpoint: String,
    redirect_uri: String,
  )
}

/// Both fields are secrets: the body contains the authorization code and PKCE
/// verifier. Only a trusted, explicitly configured sender may receive this.
pub type TokenRequest {
  TokenRequest(endpoint: String, body: String)
}

pub fn begin_manual(config: Config) -> Result(Pending, String) {
  begin(config, "")
}

/// Callback mode requires a fixed, operator-selected loopback port and path.
/// The shared callback listener cannot safely announce an ephemeral port.
pub fn begin_callback(config: Config) -> Result(Pending, String) {
  use _ <- result.try(validate_redirect(config.redirect_uri))
  begin(config, config.redirect_uri)
}

fn begin(config: Config, redirect: String) -> Result(Pending, String) {
  use _ <- result.try(valid_origin(config.api_origin))
  let codes = devin_auth.pkce()
  use url <- result.try(devin_auth.authorization_url(
    config.app_origin,
    redirect,
    codes,
  ))
  Ok(Pending(url, codes, config.api_origin <> "/auth/cli/token", redirect))
}

/// This URL is private to the operator: it includes the pending state.
pub fn authorization_url(pending: Pending) -> String {
  pending.url
}

/// Headless manual code entry. A raw code has no state to validate; PKCE binds
/// it to this pending attempt. Pasted callback queries must use complete_query.
/// This updates an existing record with generation CAS. For first enrollment,
/// use exchange_code then an explicit operator import under the setup guard;
/// the shared store does not yet expose atomic create-if-absent.
pub fn complete_code(
  pending: Pending,
  code: String,
  store: Store,
  key: String,
  send: fn(TokenRequest) -> Result(#(Int, String), String),
) -> Result(Nil, String) {
  use _ <- result.try(valid_key(key))
  use previous <- result.try(
    runtime_store.load_record(store, key)
    |> result.replace_error(
      "Devin enrollment requires an existing credential record",
    ),
  )
  use token <- result.try(exchange_code(pending, code, send))
  runtime_store.transition(
    store,
    key,
    previous,
    SessionToken(token, []),
    runtime_store.Ready,
  )
  |> result.map(fn(_) { Nil })
  |> result.replace_error("Devin credential changed during enrollment")
}

/// Secret result. A trusted integration owner must commit first enrollment
/// under its setup guard; no async unconditional write occurs here.
pub fn exchange_code(
  pending: Pending,
  code: String,
  send: fn(TokenRequest) -> Result(#(Int, String), String),
) -> Result(String, String) {
  use body <- result.try(exchange_plan(pending, code))
  use response <- result.try(
    send(TokenRequest(pending.token_endpoint, body))
    |> result.replace_error("Devin token exchange failed"),
  )
  use _ <- result.try(
    case
      response.0 >= 200
      && response.0 < 300
      && bit_array.byte_size(bit_array.from_string(response.1)) <= 1_048_576
    {
      True -> Ok(Nil)
      False -> Error("Devin token exchange failed")
    },
  )
  use token <- result.try(
    devin_auth.exchange_token(response.1)
    |> result.replace_error("Invalid Devin token response"),
  )
  use _ <- result.try(valid_token(token))
  Ok(token)
}

pub fn complete_query(
  pending: Pending,
  query: String,
  store: Store,
  key: String,
  send: fn(TokenRequest) -> Result(#(Int, String), String),
) -> Result(Nil, String) {
  use _ <- result.try(
    case bit_array.byte_size(bit_array.from_string(query)) <= 8192 {
      True -> Ok(Nil)
      False -> Error("Invalid Devin callback")
    },
  )
  use code <- result.try(devin_auth.callback_code(query, pending.codes.state))
  complete_code(pending, code, store, key, send)
}

/// The existing auth.await_callback owns the single-use loopback listener and
/// checks state before yielding a code. It does not exchange or persist.
pub fn await_and_complete(
  config: Config,
  pending: Pending,
  store: Store,
  key: String,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
  send: fn(TokenRequest) -> Result(#(Int, String), String),
) -> Result(Nil, String) {
  use _ <- result.try(validate_redirect(config.redirect_uri))
  use _ <- result.try(
    case
      pending.redirect_uri == config.redirect_uri
      && pending.redirect_uri != ""
      && pending.token_endpoint == config.api_origin <> "/auth/cli/token"
    {
      True -> Ok(Nil)
      False -> Error("Devin enrollment configuration changed")
    },
  )
  use _ <- result.try(valid_origin(config.api_origin))
  use expected_url <- result.try(devin_auth.authorization_url(
    config.app_origin,
    config.redirect_uri,
    pending.codes,
  ))
  use _ <- result.try(case expected_url == pending.url {
    True -> Ok(Nil)
    False -> Error("Devin enrollment configuration changed")
  })
  let seam =
    auth.Config(
      "devin",
      config.app_origin <> "/auth/cli/continue",
      pending.token_endpoint,
      config.redirect_uri,
      ["cli"],
    )
  let login =
    auth.Login(pending.url, pending.codes.state, pending.codes.verifier, key)
  use callback <- result.try(auth.await_callback(
    seam,
    login,
    timeout_ms,
    announce,
  ))
  complete_code(pending, callback.1, store, key, send)
}

/// Explicit manual token import bypasses PKCE. Never infer this from a pasted
/// authorization code; operator consent and provenance belong to the caller.
pub fn import_session_token(
  store: Store,
  key: String,
  raw: String,
) -> Result(Nil, String) {
  use token <- result.try(devin_auth.format_session_token(raw))
  persist(store, key, token)
}

fn persist(store: Store, key: String, token: String) -> Result(Nil, String) {
  use _ <- result.try(valid_key(key))
  use _ <- result.try(valid_token(token))
  runtime_store.save(store, key, SessionToken(token, []))
  |> result.replace_error("Devin credential persistence failed")
}

fn valid_token(token: String) -> Result(Nil, String) {
  case
    string.byte_size(token) <= 16_384
    && !string.contains(token, " ")
    && !string.contains(token, "\t")
  {
    True -> Ok(Nil)
    False -> Error("Invalid Devin session token")
  }
}

fn valid_key(key: String) -> Result(Nil, String) {
  case
    key != ""
    && string.length(key) <= 256
    && !string.contains(key, "\r")
    && !string.contains(key, "\n")
  {
    True -> Ok(Nil)
    False -> Error("Invalid Devin credential key")
  }
}

fn exchange_plan(pending: Pending, raw_code: String) -> Result(String, String) {
  let code = string.trim(raw_code)
  use _ <- result.try(
    case
      code != ""
      && string.length(code) <= 4096
      && !string.contains(raw_code, "\r")
      && !string.contains(raw_code, "\n")
      && !string.contains(code, " ")
      && !string.contains(code, "\t")
    {
      True -> Ok(Nil)
      False -> Error("Invalid Devin authorization code")
    },
  )
  devin_auth.exchange_body(code, pending.codes.verifier)
}

fn valid_origin(origin: String) -> Result(Nil, String) {
  use parsed <- result.try(
    uri.parse(origin) |> result.replace_error("Invalid Devin API origin"),
  )
  case parsed {
    uri.Uri(
      scheme: Some("https"),
      host: Some(host),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    )
      if host != ""
    -> Ok(Nil)
    uri.Uri(
      scheme: Some("http"),
      host: Some("127.0.0.1"),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error("Invalid Devin API origin")
  }
}

fn validate_redirect(value: String) -> Result(Nil, String) {
  use parsed <- result.try(
    uri.parse(value) |> result.replace_error("Invalid Devin callback URI"),
  )
  case parsed {
    uri.Uri(
      scheme: Some("http"),
      host: Some("127.0.0.1"),
      port: Some(port),
      path: "/callback",
      userinfo: None,
      query: None,
      fragment: None,
    )
      if port > 0 && port < 65_536
    -> Ok(Nil)
    _ -> Error("Invalid Devin callback URI")
  }
}
