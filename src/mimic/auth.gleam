import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri
import mimic/auth/crypto
import mimic/auth/storage.{type Store}
import mist
import mist/internal/http as mist_http

pub type Config {
  Config(
    client_id: String,
    authorize_url: String,
    token_url: String,
    redirect_uri: String,
    scopes: List(String),
  )
}

pub type Login {
  Login(url: String, state: String, verifier: String, credential_id: String)
}

pub type Credential {
  Credential(access_token: String, refresh_token: String, expires_at_ms: Int)
}

pub type CredentialMetadata {
  CredentialMetadata(id: String, expires_at_ms: Int)
}

/// The caller must supply an explicitly approved endpoint and redirect URI.
/// No default live network endpoint is selected.
pub fn claude_config(
  client_id: String,
  authorize_url: String,
  token_url: String,
  redirect_uri: String,
) -> Config {
  Config(client_id:, authorize_url:, token_url:, redirect_uri:, scopes: [
    "user:profile",
    "user:inference",
    "user:sessions:claude_code",
    "user:mcp_servers",
    "user:file_upload",
  ])
}

pub fn begin_login(
  config: Config,
  credential_id: String,
) -> Result(Login, String) {
  use _ <- try(validate_config(config))
  case credential_id {
    "" -> Error("Credential id must not be empty")
    _ -> {
      let state = crypto.random_url_token()
      let verifier = crypto.random_url_token()
      let query =
        uri.query_to_string([
          #("client_id", config.client_id),
          #("response_type", "code"),
          #("redirect_uri", config.redirect_uri),
          #("scope", string_join(config.scopes, " ")),
          #("state", state),
          #("code_challenge", crypto.pkce_challenge(verifier)),
          #("code_challenge_method", "S256"),
        ])
      let separator = case uri.parse(config.authorize_url) {
        Ok(uri.Uri(query: Some(_), ..)) -> "&"
        _ -> "?"
      }
      Ok(Login(
        config.authorize_url <> separator <> query,
        state,
        verifier,
        credential_id,
      ))
    }
  }
}

/// Pass the state from the redirect independently of the pending login. A
/// mismatch fails before any network request is made. Discard Login after use.
pub fn complete_login(
  config: Config,
  store: Store,
  login: Login,
  callback_state: String,
  code: String,
  now_ms: Int,
) -> Result(Credential, String) {
  case callback_state == login.state && code != "" {
    False -> Error("OAuth state mismatch or missing code")
    True -> {
      use _ <- try(validate_config(config))
      let body =
        uri.query_to_string([
          #("grant_type", "authorization_code"),
          #("code", code),
          #("client_id", config.client_id),
          #("redirect_uri", config.redirect_uri),
          #("code_verifier", login.verifier),
        ])
      use credential <- try(exchange(config.token_url, body, now_ms, None))
      use _ <- try(save(store, login.credential_id, credential))
      Ok(credential)
    }
  }
}

pub fn refresh(
  config: Config,
  store: Store,
  id: String,
  current: Credential,
  now_ms: Int,
) -> Result(Credential, String) {
  use _ <- try(validate_config(config))
  let body =
    uri.query_to_string([
      #("grant_type", "refresh_token"),
      #("refresh_token", current.refresh_token),
      #("client_id", config.client_id),
    ])
  use credential <- try(exchange(
    config.token_url,
    body,
    now_ms,
    Some(current.refresh_token),
  ))
  use _ <- try(save(store, id, credential))
  Ok(credential)
}

fn exchange(
  url: String,
  body: String,
  now_ms: Int,
  previous_refresh_token: Option(String),
) -> Result(Credential, String) {
  use req <- try(request.to(url) |> map_error("Invalid token URL"))
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body)
  // No redirects, no TLS downgrade, and no request/response logging.
  case httpc.dispatch(httpc.configure() |> httpc.timeout(10_000), req) {
    Ok(response) if response.status >= 200 && response.status < 300 ->
      decode_token(response.body, now_ms, previous_refresh_token)
    Ok(response) if response.status >= 400 && response.status < 500 ->
      Error("OAuth token endpoint rejected the grant")
    Ok(_) -> Error("OAuth token endpoint unavailable")
    Error(_) -> Error("OAuth token exchange failed")
  }
}

fn decode_token(
  body: String,
  now_ms: Int,
  previous: Option(String),
) -> Result(Credential, String) {
  let decoder = {
    use access <- decode.field("access_token", decode.string)
    use refresh <- decode.optional_field(
      "refresh_token",
      None,
      decode.optional(decode.string),
    )
    use seconds <- decode.field("expires_in", decode.int)
    decode.success(#(access, refresh, seconds))
  }
  case json.parse(body, decoder) {
    Ok(#(access, refresh, seconds)) if access != "" && seconds > 0 ->
      case refresh, previous {
        Some(value), _ if value != "" ->
          Ok(Credential(access, value, now_ms + seconds * 1000))
        None, Some(value) ->
          Ok(Credential(access, value, now_ms + seconds * 1000))
        _, _ -> Error("OAuth response is missing refresh token")
      }
    _ -> Error("Invalid OAuth token response")
  }
}

pub fn save(
  store: Store,
  id: String,
  credential: Credential,
) -> Result(Nil, String) {
  let contents =
    json.object([
      #("access_token", json.string(credential.access_token)),
      #("refresh_token", json.string(credential.refresh_token)),
      #("expires_at_ms", json.int(credential.expires_at_ms)),
    ])
    |> json.to_string
  storage.write(store, id, contents)
}

pub fn load(store: Store, id: String) -> Result(Credential, String) {
  use contents <- try(storage.read(store, id))
  let decoder = {
    use access <- decode.field("access_token", decode.string)
    use refresh <- decode.field("refresh_token", decode.string)
    use expires <- decode.field("expires_at_ms", decode.int)
    decode.success(Credential(access, refresh, expires))
  }
  json.parse(contents, decoder) |> map_error("Invalid credential file")
}

pub fn list_metadata(store: Store) -> Result(List(CredentialMetadata), String) {
  use ids <- try(storage.list_ids(store))
  list.try_map(ids, fn(id) {
    use credential <- try(load(store, id))
    Ok(CredentialMetadata(id, credential.expires_at_ms))
  })
}

pub fn delete(store: Store, id: String) -> Result(Nil, String) {
  storage.delete(store, id)
}

fn validate_config(config: Config) -> Result(Nil, String) {
  case config.client_id == "" || config.scopes == [] {
    True -> Error("OAuth client id and scopes must be configured")
    False -> {
      use _ <- try(validate_url(config.authorize_url))
      use _ <- try(validate_url(config.token_url))
      use parsed <- try(
        uri.parse(config.redirect_uri) |> map_error("Invalid redirect URI"),
      )
      case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
        Some("http"), Some("127.0.0.1"), None, None -> Ok(Nil)
        Some("http"), Some("localhost"), None, None -> Ok(Nil)
        _, _, _, _ -> Error("OAuth redirect must be loopback HTTP")
      }
    }
  }
}

fn validate_url(url: String) -> Result(Nil, String) {
  use parsed <- try(uri.parse(url) |> map_error("Invalid OAuth endpoint"))
  case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
    Some("https"), Some(host), None, None if host != "" -> Ok(Nil)
    Some("http"), Some("127.0.0.1"), None, None -> Ok(Nil)
    Some("http"), Some("localhost"), None, None -> Ok(Nil)
    _, _, _, _ -> Error("OAuth endpoint must use HTTPS or loopback HTTP")
  }
}

fn string_join(items: List(String), separator: String) -> String {
  case items {
    [] -> ""
    [first, ..rest] -> first <> string_join_rest(rest, separator)
  }
}

fn string_join_rest(items: List(String), separator: String) -> String {
  case items {
    [] -> ""
    [first, ..rest] -> separator <> first <> string_join_rest(rest, separator)
  }
}

fn try(
  value: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case value {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}

fn map_error(value: Result(a, e), message: String) -> Result(a, String) {
  case value {
    Ok(v) -> Ok(v)
    Error(_) -> Error(message)
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["login", "claude"] -> {
      use client_id <- try(env("MIMIC_CLAUDE_CLIENT_ID"))
      use authorize_url <- try(env("MIMIC_CLAUDE_AUTHORIZE_URL"))
      use token_url <- try(env("MIMIC_CLAUDE_TOKEN_URL"))
      use redirect_uri <- try(env("MIMIC_CLAUDE_REDIRECT_URI"))
      use state_dir <- try(env("MIMIC_STATE_DIR"))
      use store <- try(storage.new(state_dir))
      let config =
        claude_config(client_id, authorize_url, token_url, redirect_uri)
      use credential <- try(login_with_callback(
        config,
        store,
        "claude",
        120_000,
        io.println,
      ))
      Ok(
        "Stored credential claude; expires_at_ms="
        <> int.to_string(credential.expires_at_ms),
      )
    }
    [] ->
      Ok(
        "auth: login claude requires explicit MIMIC_CLAUDE_CLIENT_ID, MIMIC_CLAUDE_AUTHORIZE_URL, MIMIC_CLAUDE_TOKEN_URL, MIMIC_CLAUDE_REDIRECT_URI and MIMIC_STATE_DIR",
      )
    _ -> Error("Usage: mimic auth [login claude]")
  }
}

/// CLI-compatible interactive flow. The pending verifier never leaves this
/// process; the callback listener binds only 127.0.0.1 and is shut down after
/// one valid callback or timeout. `announce` only receives the authorize URL.
pub fn login_with_callback(
  config: Config,
  store: Store,
  credential_id: String,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
) -> Result(Credential, String) {
  use login <- try(begin_login(config, credential_id))
  use callback <- try(await_callback(config, login, timeout_ms, announce))
  complete_login(config, store, login, callback.0, callback.1, now_ms())
}

/// Single-use loopback callback seam. Does not exchange or persist credentials.
/// The caller owns the pending PKCE Login and consumes this result once.
pub fn await_callback(
  config: Config,
  login: Login,
  timeout_ms: Int,
  announce: fn(String) -> Nil,
) -> Result(#(String, String), String) {
  use _ <- try(validate_config(config))
  use _ <- try(case timeout_ms > 0 && timeout_ms <= 300_000 {
    True -> Ok(Nil)
    False -> Error("Invalid OAuth callback deadline")
  })
  let deadline = monotonic_ms(Millisecond) + timeout_ms
  use redirect <- try(
    uri.parse(config.redirect_uri) |> map_error("Invalid redirect URI"),
  )
  case
    redirect.scheme,
    redirect.host,
    redirect.port,
    redirect.query,
    redirect.fragment
  {
    Some("http"), Some(host), Some(port), None, None
      if { host == "localhost" || host == "127.0.0.1" }
      && port > 0
      && port < 65_536
      && redirect.path != ""
    -> {
      let callback = process.new_subject()
      let started = process.new_subject()
      let handler = fn(req: request.Request(mist.Connection)) {
        let valid = case req.query {
          Some(query) ->
            case uri.parse_query(query) {
              Ok(pairs) ->
                case
                  list.filter(pairs, fn(pair) { pair.0 == "state" }),
                  list.filter(pairs, fn(pair) { pair.0 == "code" })
                {
                  [#(_, state)], [#(_, code)]
                    if state == login.state && code != ""
                  -> Some(#(state, code))
                  _, _ -> None
                }
              Error(_) -> None
            }
          None -> None
        }
        // Pinned Mist gives this direct handler Initial for HTTP/1.x and
        // Stream for HTTP/2. Recheck this invariant on a Mist/pipeline change:
        // the connection-process completion wait below is HTTP/1.x only.
        case
          req.body.body,
          req.method == http.Get && req.path == redirect.path,
          valid
        {
          mist_http.Initial(_), True, Some(value) -> {
            process.send(callback, #(value, process.self()))
            response.new(200)
            |> response.set_header("connection", "close")
            |> response.set_header("cache-control", "no-store")
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string(
                "Callback received. You may close this window.",
              )),
            )
          }
          mist_http.Stream(..), _, _ ->
            response.new(505)
            |> response.set_header("cache-control", "no-store")
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string(
                "OAuth callback requires HTTP/1.x",
              )),
            )
          _, _, _ ->
            response.new(400)
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string("Invalid OAuth callback")),
            )
        }
      }
      let builder =
        mist.new(handler)
        |> mist.port(port)
        |> mist.bind("127.0.0.1")
        |> mist.after_start(fn(actual_port, _, _) {
          process.send(started, actual_port)
        })
      case mist.start(builder) {
        Error(_) -> Error("Unable to start loopback OAuth callback listener")
        Ok(server) -> {
          let result = case process.receive(started, remaining_ms(deadline)) {
            Ok(actual_port) if actual_port == port -> {
              announce(login.url)
              case process.receive(callback, remaining_ms(deadline)) {
                Ok(#(value, connection)) -> {
                  // The handler publishes before Mist writes the response.
                  // Its explicit Connection: close makes process termination
                  // the bounded response-attempt boundary, not a sleep.
                  let monitor = process.monitor(connection)
                  let finished =
                    process.new_selector()
                    |> process.select_specific_monitor(monitor, fn(_) { Nil })
                    |> process.selector_receive(remaining_ms(deadline))
                  process.demonitor_process(monitor)
                  case finished {
                    Ok(_) -> Ok(value)
                    Error(_) -> Error("OAuth callback response did not finish")
                  }
                }
                Error(_) -> Error("OAuth callback timed out")
              }
            }
            _ -> Error("OAuth callback listener did not become ready")
          }
          process.unlink(server.pid)
          process.send_exit(server.pid)
          result
        }
      }
    }
    _, _, _, _, _ ->
      Error("OAuth CLI redirect must specify a loopback HTTP port and path")
  }
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_ms(unit: TimeUnit) -> Int

fn remaining_ms(deadline: Int) -> Int {
  int.max(0, deadline - monotonic_ms(Millisecond))
}

fn env(name: String) -> Result(String, String) {
  case get_env(name) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("Missing or empty " <> name)
  }
}

@external(erlang, "mimic_auth_ffi", "get_env")
fn get_env(name: String) -> Result(String, String)

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
