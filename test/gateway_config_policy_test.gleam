import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit/should
import mimic/gateway/config

fn settings(provider: String, mode: String, model: String, origin: String) {
  json.object([
    #("version", json.int(1)),
    #("state_dir", json.string("/synthetic/private/state")),
    #("listen_port", json.int(0)),
    #(
      "accounts",
      json.array(
        [
          json.object([
            #("provider", json.string(provider)),
            #("auth_mode", json.string(mode)),
            #("id", json.string("synthetic-account")),
            #("origin", json.string(origin)),
            #("models", json.array([model], json.string)),
          ]),
        ],
        fn(value) { value },
      ),
    ),
  ])
  |> json.to_string
}

pub fn root_slash_is_canonical_before_runtime_and_provider_selection_test() {
  list.each(
    [
      #("xai", "api_key", "grok-4.7"),
      #("devin", "session_token", "devin/swe-1-7"),
      #("claude", "api_key", "synthetic-claude"),
      #("kimi", "api_key", "kimi-k2.7-code"),
    ],
    fn(provider) {
      let assert Ok(value) =
        config.decode(settings(
          provider.0,
          provider.1,
          provider.2,
          "http://127.0.0.1:12345/",
        ))
      let assert Ok(account) = list.first(value.accounts)
      account.origin |> should.equal("http://127.0.0.1:12345")
      let assert Ok(runtime_account) =
        list.first(config.runtime_accounts(value))
      runtime_account.origin |> should.equal(account.origin)
      value.codex_http_continuation |> should.be_false
      value.codex_catalog |> should.equal(None)
    },
  )
}

pub fn canonicalization_does_not_admit_paths_or_untrusted_authorities_test() {
  list.each(
    [
      "http://127.0.0.1:12345//",
      "http://127.0.0.1:12345/v1",
      "http://127.0.0.1:12345/?query=value",
      "http://127.0.0.1:12345/#fragment",
      "http://user@127.0.0.1:12345/",
      "http://synthetic-provider.invalid/",
    ],
    fn(origin) {
      config.decode(settings("xai", "api_key", "grok-4.7", origin))
      |> should.be_error
    },
  )
}

pub fn canonicalization_preserves_numeric_loopback_devin_gate_test() {
  config.decode(settings(
    "devin",
    "session_token",
    "devin/swe-1-7",
    "http://localhost:12345/",
  ))
  |> should.be_error
  let assert Ok(value) =
    config.decode(settings(
      "xai",
      "api_key",
      "grok-4.7",
      "http://localhost:12345/",
    ))
  let assert Ok(account) = list.first(value.accounts)
  account.origin |> should.equal("http://localhost:12345")
}

pub fn continuation_opt_in_is_typed_and_requires_codex_configuration_test() {
  let source =
    "{\"version\":1,\"state_dir\":\"/synthetic/private/state\","
    <> "\"listen_port\":0,\"accounts\":[{\"provider\":\"claude\","
    <> "\"auth_mode\":\"api_key\",\"id\":\"synthetic-account\","
    <> "\"origin\":\"http://127.0.0.1:12345\","
    <> "\"models\":[\"synthetic-claude\"]}],\"codex_http_continuation\":"
  let assert Ok(value) = config.decode(source <> "false}")
  value.codex_http_continuation |> should.be_false
  list.each(["true", "null", "\"true\"", "1", "{}"], fn(flag) {
    config.decode(source <> flag <> "}") |> should.be_error
  })
}
