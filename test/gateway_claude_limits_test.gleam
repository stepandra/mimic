import gleam/list
import gleeunit/should
import mimic/gateway/config

fn settings(extra: String) -> String {
  "{\"version\":1,\"state_dir\":\"/synthetic/f10\",\"listen_port\":0,"
  <> "\"accounts\":[{\"provider\":\"claude\",\"auth_mode\":\"api_key\","
  <> "\"id\":\"synthetic\",\"origin\":\"http://127.0.0.1:12345\","
  <> "\"models\":[\"claude-sonnet-4\"]}]"
  <> extra
  <> "}"
}

pub fn classification_is_explicit_and_defaults_off_test() {
  let assert Ok(defaults) = config.decode(settings(""))
  defaults.claude_quota_classification |> should.be_false
  let assert Ok(disabled) =
    config.decode(settings(",\"claude_quota_classification\":false"))
  disabled.claude_quota_classification |> should.be_false
  let assert Ok(enabled) =
    config.decode(settings(",\"claude_quota_classification\":true"))
  enabled.claude_quota_classification |> should.be_true
}

pub fn classification_rejects_coercion_and_duplicate_options_test() {
  list.each(["null", "\"true\"", "1", "{}", "[]"], fn(raw) {
    config.decode(settings(",\"claude_quota_classification\":" <> raw))
    |> should.be_error
  })
  config.decode(settings(
    ",\"claude_quota_classification\":false,"
    <> "\"claude_quota_classification\":true",
  ))
  |> should.be_error
}
