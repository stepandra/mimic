import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/ir
import mimic/providers/devin/identity
import mimic/providers/devin/tokens

pub type Pkce {
  Pkce(verifier: String, challenge: String, state: String)
}

pub fn pkce() -> Pkce {
  let verifier = bit_array.base64_url_encode(identity.random_bytes(64), False)
  Pkce(
    verifier,
    identity.sha256(bit_array.from_string(verifier))
      |> bit_array.base64_url_encode(False),
    identity.hex(identity.random_bytes(32)),
  )
}

/// Pure URL construction only. The caller must approve the origin; no login is
/// launched here. Query ordering follows CPA BuildAuthorizationURL.
pub fn authorization_url(
  approved_app_origin: String,
  redirect: String,
  codes: Pkce,
) -> Result(String, String) {
  use parsed <- result.try(
    uri.parse(approved_app_origin)
    |> result.replace_error("invalid devin authorization origin"),
  )
  use origin <- result.try(
    uri.origin(parsed)
    |> result.replace_error("invalid devin authorization origin"),
  )
  use _ <- result.try(case parsed {
    uri.Uri(
      scheme: Some("https"),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    uri.Uri(
      scheme: Some("http"),
      host: Some("127.0.0.1"),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error("unsupported devin authorization origin")
  })
  let redirect = string.trim(redirect)
  let prefix = case redirect {
    "" -> []
    _ -> [#("redirect_uri", redirect)]
  }
  let query = [
    #("state", codes.state),
    #("prompt", "select_account"),
    #("code_challenge", codes.challenge),
    #("code_challenge_method", "S256"),
  ]
  let suffix = case redirect {
    "" -> [#("cli_pkce_marker", "1")]
    _ -> []
  }
  Ok(
    origin
    <> "/auth/cli/continue?"
    <> uri.query_to_string(list.append(prefix, list.append(query, suffix))),
  )
}

/// A callback is not trusted until state is checked. Manual raw-code imports
/// use exchange_body directly; callback URLs must not bypass this check.
pub fn callback_code(
  query: String,
  expected_state: String,
) -> Result(String, String) {
  use fields <- result.try(
    uri.parse_query(query) |> result.replace_error("invalid devin callback"),
  )
  case list.key_find(fields, "error") {
    Ok(_) -> Error("devin authorization failed")
    Error(_) -> {
      let codes = list.filter(fields, fn(pair) { pair.0 == "code" })
      let states = list.filter(fields, fn(pair) { pair.0 == "state" })
      case codes, states {
        [#(_, code)], [#(_, state)]
          if state == expected_state && state != "" && code != ""
        -> Ok(code)
        _, _ -> Error("invalid devin callback code or state")
      }
    }
  }
}

/// CPA only prefixes JWT-shaped tokens, leaving other opaque tokens unchanged.
/// This is formatting, NOT verification or proof that the token is valid.
pub fn format_session_token(raw: String) -> Result(String, String) {
  let token = string.trim(raw)
  case
    token == ""
    || string.contains(token, "\r")
    || string.contains(token, "\n")
    || string.contains(token, "\u{0000}")
  {
    True -> Error("invalid devin session token")
    False ->
      case string.starts_with(token, "eyJ") {
        True -> Ok("devin-session-token$" <> token)
        False -> Ok(token)
      }
  }
}

/// Pure token-exchange serialization. No browser, socket, or persistence.
pub fn exchange_body(code: String, verifier: String) -> Result(String, String) {
  let code = string.trim(code)
  let verifier = string.trim(verifier)
  case code == "" || verifier == "" {
    True -> Error("devin authorization code and verifier required")
    False ->
      Ok(
        ir.stringify(
          ir.Object([
            #("code", ir.String(code)),
            #("code_verifier", ir.String(verifier)),
          ]),
        ),
      )
  }
}

pub fn exchange_token(body: String) -> Result(String, String) {
  use value <- result.try(
    ir.parse(body) |> result.replace_error("invalid devin token response"),
  )
  use token <- result.try(
    ir.string_field(value, "token")
    |> result.replace_error("invalid devin token response"),
  )
  format_session_token(token)
}

/// CPA CountTokens is a byte-length heuristic, not a measured tokenizer.
pub fn estimated_tokens(payload: String) -> Int {
  tokens.estimate(payload).input_tokens
}
