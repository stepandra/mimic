import gleam/list
import gleam/option.{Some}
import gleeunit/should
import mimic/gateway/config

fn settings(provider: String, mode: String, extra: String) -> String {
  "{\"version\":1,\"state_dir\":\"/synthetic/f08\",\"listen_port\":0,"
  <> "\"accounts\":[{\"provider\":\""
  <> provider
  <> "\",\"auth_mode\":\""
  <> mode
  <> "\",\"id\":\"synthetic\",\"origin\":\"http://127.0.0.1:12345\","
  <> "\"models\":[\"synthetic-claude\"],\"oauth\":{"
  <> "\"client_id\":\"synthetic-client\","
  <> "\"authorize_url\":\"http://127.0.0.1:12345/authorize\","
  <> "\"token_url\":\"http://127.0.0.1:12345/token\","
  <> "\"redirect_uri\":\"http://127.0.0.1:12346/callback\""
  <> extra
  <> "}}]}"
}

const approved = "{\"profile_url\":\"http://127.0.0.1:12345/profile\","
  <> "\"roles_url\":\"http://127.0.0.1:12345/roles\",\"approved\":true}"

pub fn companion_requires_explicit_typed_approval_test() {
  let assert Ok(default) = config.decode(settings("claude", "oauth", ""))
  let assert [account] = default.accounts
  let assert Some(config.ClaudeOAuth(_)) = account.oauth
  let assert Ok(enabled) =
    config.decode(settings("claude", "oauth", ",\"companion\":" <> approved))
  let assert [account] = enabled.accounts
  let assert Some(config.ClaudeCompanionOAuth(_, _)) = account.oauth
  list.each(
    [
      "null",
      "false",
      "\"true\"",
      "{}",
      "{\"approved\":true}",
      "{\"profile_url\":\"http://127.0.0.1:12345/profile\","
        <> "\"roles_url\":\"http://127.0.0.1:12345/roles\",\"approved\":false}",
      "{\"profile_url\":\"http://127.0.0.1:12345/profile\","
        <> "\"roles_url\":\"http://127.0.0.1:12345/roles\",\"approved\":\"true\"}",
    ],
    fn(raw) {
      config.decode(settings("claude", "oauth", ",\"companion\":" <> raw))
      |> should.be_error
    },
  )
}

pub fn companion_cannot_be_silently_ignored_for_other_auth_modes_test() {
  config.decode(settings("claude", "api_key", ",\"companion\":" <> approved))
  |> should.be_error
  list.each(["codex", "kimi", "xai"], fn(provider) {
    config.decode(settings(provider, "oauth", ",\"companion\":" <> approved))
    |> should.be_error
  })
}
