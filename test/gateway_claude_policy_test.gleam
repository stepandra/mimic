import gleam/list
import gleam/option.{None}
import gleeunit/should
import mimic/gateway/config
import mimic/providers/claude/policy
import mimic/providers/contracts as c
import mimic/types.{Header}

fn settings(provider: String, extra: String) -> String {
  let #(auth_mode, model) = case provider {
    "kimi" -> #("api_key", "kimi-k2.5")
    "xai" -> #("api_key", "grok-4.7")
    "devin" -> #("session_token", "devin/swe-1-7")
    _ -> #("api_key", "claude-sonnet-4")
  }
  settings_for(provider, auth_mode, model, extra)
}

fn settings_for(
  provider: String,
  auth_mode: String,
  model: String,
  extra: String,
) -> String {
  "{\"version\":1,\"state_dir\":\"/synthetic/f09\",\"listen_port\":0,"
  <> "\"accounts\":[{\"provider\":\""
  <> provider
  <> "\",\"auth_mode\":\""
  <> auth_mode
  <> "\",\"id\":\"synthetic\","
  <> "\"origin\":\"http://127.0.0.1:12345\","
  <> "\"models\":[\""
  <> model
  <> "\"]"
  <> extra
  <> "}]}"
}

pub fn defaults_preserve_native_policy_test() {
  let assert Ok(settings) = config.decode(settings("claude", ""))
  let assert [account] = settings.accounts
  account.claude_policy |> should.equal(policy.native())
  account.claude_client_headers |> should.equal([])
}

pub fn operator_policy_and_headers_decode_test() {
  let assert Ok(settings) =
    config.decode(settings(
      "claude",
      ",\"claude_policy\":{\"input\":\"translated\",\"turn\":\"conversation\","
        <> "\"cache\":\"5m\"},\"claude_client_headers\":["
        <> "[\"User-Agent\",\"synthetic-approved-client\"]]",
    ))
  let assert [account] = settings.accounts
  account.claude_policy
  |> should.equal(policy.Policy(
    policy.TranslatedMessages,
    policy.Conversation,
    policy.DefaultFiveMinutes,
  ))
  account.claude_client_headers
  |> should.equal([Header("User-Agent", "synthetic-approved-client")])
}

pub fn policy_rejects_unknown_missing_or_unauthorized_choices_test() {
  list.each(
    [
      "null",
      "{}",
      "{\"input\":\"native\",\"turn\":\"conversation\",\"cache\":\"preserve\",\"extra\":true}",
      "{\"input\":\"native\",\"turn\":\"caller-controlled\",\"cache\":\"preserve\"}",
      "{\"input\":\"translated\",\"turn\":\"conversation\",\"cache\":\"1h\"}",
      "{\"input\":\"native\",\"turn\":\"conversation\",\"cache\":\"5m\"}",
      "{\"input\":\"translated\",\"turn\":\"conversation\"}",
    ],
    fn(raw) {
      config.decode(settings("claude", ",\"claude_policy\":" <> raw))
      |> should.be_error
    },
  )
}

pub fn client_headers_reject_secret_duplicate_control_or_malformed_values_test() {
  list.each(
    [
      "null",
      "{}",
      "[[\"User-Agent\"]]",
      "[[\"User-Agent\",\"synthetic\",true]]",
      "[[\"Authorization\",\"synthetic-secret\"]]",
      "[[\"X-Api-Key\",\"synthetic-secret\"]]",
      "[[\"User-Agent\",\"synthetic\"],[\"user-agent\",\"other\"]]",
      "[[\"User-Agent\",\"synthetic\\u000bvalue\"]]",
    ],
    fn(raw) {
      config.decode(settings("claude", ",\"claude_client_headers\":" <> raw))
      |> should.be_error
    },
  )
}

pub fn non_claude_options_cannot_be_silently_ignored_test() {
  list.each(["kimi", "xai", "devin"], fn(provider) {
    // Prove each baseline is valid before testing the additional forbidden option.
    config.decode(settings(provider, "")) |> should.be_ok
    config.decode(settings(provider, ",\"claude_client_headers\":[]"))
    |> should.be_error
    config.decode(settings(
      provider,
      ",\"claude_policy\":{\"input\":\"native\",\"turn\":\"conversation\",\"cache\":\"preserve\"}",
    ))
    |> should.be_error
  })
}

pub fn oauth_translated_conversation_can_use_approved_one_hour_cache_test() {
  let assert Ok(settings) =
    config.decode(settings_for(
      "claude",
      "oauth",
      "claude-sonnet-4",
      ",\"oauth\":{\"client_id\":\"synthetic-client\","
        <> "\"authorize_url\":\"http://127.0.0.1:12345/authorize\","
        <> "\"token_url\":\"http://127.0.0.1:12345/token\","
        <> "\"redirect_uri\":\"http://127.0.0.1:12346/callback\"},"
        <> "\"claude_policy\":{\"input\":\"translated\","
        <> "\"turn\":\"conversation\",\"cache\":\"1h\"}",
    ))
  let assert [account] = settings.accounts
  account.claude_policy
  |> should.equal(policy.Policy(
    policy.TranslatedMessages,
    policy.Conversation,
    policy.ApprovedOneHour,
  ))
}

fn context() -> c.Context {
  c.Context(
    "claude",
    "api_key",
    "synthetic",
    "http://127.0.0.1:12345",
    "synthetic-session",
    c.ApiKey("synthetic-key"),
  )
}

fn request() -> c.Request {
  c.Request(
    "claude",
    "api_key",
    "claude-sonnet-4",
    "anthropic-messages",
    "messages",
    c.Buffered,
    [c.Buffer],
    "synthetic-session",
    None,
    "{\"model\":\"claude-sonnet-4\",\"max_tokens\":8,\"messages\":["
      <> "{\"role\":\"user\",\"content\":\"synthetic\"}]}",
  )
}

pub fn trusted_policy_requires_actual_selected_account_and_origin_test() {
  let assert Ok(settings) = config.decode(settings("claude", ""))
  config.prepare_claude(settings, context(), request()) |> should.be_ok
  list.each(
    [
      c.Context(..context(), account: "different"),
      c.Context(..context(), origin: "http://127.0.0.1:12346"),
      c.Context(..context(), provider: "xai"),
      c.Context(..context(), auth_mode: "oauth"),
    ],
    fn(context) {
      config.prepare_claude(settings, context, request())
      |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
    },
  )
  config.prepare_claude(
    settings,
    context(),
    c.Request(..request(), model: "unconfigured"),
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
}
