import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/providers/claude/cache
import mimic/providers/claude/identity
import mimic/providers/claude/request
import mimic/types.{type Capture, Header}
import simplifile

const body = "{\"model\":\"claude-synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}]}"

fn account() {
  identity.Account(
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "synthetic-account",
  )
}

fn session() {
  Some(request.Identity(
    "synthetic-session",
    "synthetic-request",
    Some(account()),
  ))
}

fn header(capture: Capture, name: String) -> List(String) {
  capture.headers
  |> list.filter(fn(h) { string.lowercase(h.name) == name })
  |> list.map(fn(h) { h.value })
}

pub fn separate_auth_headers_and_framing_test() {
  let incoming = [
    Header("Authorization", "synthetic-client-secret"),
    Header("x-api-key", "synthetic-client-key"),
    Header("Host", "untrusted.invalid"),
    Header("Content-Length", "1"),
    Header("Cookie", "synthetic-client-cookie"),
    Header("User-Agent", "synthetic-native-client"),
  ]
  let assert Ok(api) =
    request.prepare(
      "http://127.0.0.1:19444",
      request.ApiKey("synthetic-key"),
      request.Messages(False),
      incoming,
      None,
      body,
    )
  header(api, "x-api-key") |> should.equal(["synthetic-key"])
  header(api, "authorization") |> should.equal([])
  header(api, "cookie") |> should.equal([])
  header(api, "host") |> should.equal(["127.0.0.1:19444"])
  header(api, "content-length")
  |> should.equal([int.to_string(string.byte_size(api.body))])
  header(api, "user-agent") |> should.equal(["synthetic-native-client"])
  api.body |> should.equal(body)
  let assert Ok(oauth) =
    request.prepare(
      "http://127.0.0.1:19444",
      request.OAuth("synthetic-access"),
      request.Messages(False),
      incoming,
      session(),
      body,
    )
  header(oauth, "authorization") |> should.equal(["Bearer synthetic-access"])
  header(oauth, "x-api-key") |> should.equal([])
  header(oauth, "x-claude-code-session-id")
  |> should.equal(["synthetic-session"])
  header(oauth, "x-client-request-id") |> should.equal(["synthetic-request"])
}

pub fn count_tokens_has_separate_profile_test() {
  let input =
    "{\"model\":\"claude-synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5,\"stream\":false,\"metadata\":{\"synthetic\":true},\"context_management\":{},\"diagnostics\":{}}"
  let assert Ok(count) =
    request.prepare(
      "http://localhost:19444",
      request.OAuth("synthetic"),
      request.CountTokens,
      [],
      session(),
      input,
    )
  count.target |> should.equal("/v1/messages/count_tokens?beta=true")
  header(count, "accept") |> should.equal(["application/json"])
  header(count, "anthropic-beta")
  |> should.equal([
    "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01",
  ])
  let assert Ok(value) = ir.parse(count.body)
  ir.extras(value, ["model", "messages"]) |> should.equal([])
  let assert Ok(api) =
    request.prepare(
      "http://localhost:19444",
      request.ApiKey("synthetic"),
      request.CountTokens,
      [],
      None,
      body,
    )
  header(api, "anthropic-beta")
  |> should.equal([
    "claude-code-20250219,interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01",
  ])
}

pub fn native_tool_thinking_and_cache_preservation_test() {
  let assert Ok(input) =
    simplifile.read("test/fixtures/claude/native_messages.json")
  let assert Ok(prepared) =
    request.prepare(
      "http://localhost:19444",
      request.ApiKey("synthetic"),
      request.Messages(False),
      [],
      None,
      input,
    )
  prepared.body |> should.equal(input)
  header(prepared, "anthropic-beta")
  |> should.equal(["extended-cache-ttl-2025-04-11"])
  let assert Ok(value) = ir.parse(input)
  cache.validate(value) |> should.equal(Ok(cache.Summary(2, True)))
}

pub fn oauth_identity_replaces_selected_fields_only_test() {
  let input =
    "{\"model\":\"claude-synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"metadata\":{\"synthetic\":true,\"user_id\":\"{\\\"device_id\\\":\\\"other\\\",\\\"account_uuid\\\":\\\"other\\\",\\\"session_id\\\":\\\"other\\\",\\\"future\\\":true}\"}}"
  let assert Ok(prepared) =
    request.prepare(
      "http://localhost:19444",
      request.OAuth("synthetic"),
      request.Messages(False),
      [],
      session(),
      input,
    )
  let assert Ok(value) = ir.parse(prepared.body)
  let assert Ok(metadata) = ir.required(value, "metadata")
  ir.field(metadata, "synthetic") |> should.equal(Some(ir.Boolean(True)))
  let assert Ok(user) = ir.string_field(metadata, "user_id")
  let assert Ok(user) = ir.parse(user)
  ir.string_field(user, "device_id") |> should.equal(Ok(account().device_id))
  ir.string_field(user, "account_uuid") |> should.equal(Ok("synthetic-account"))
  ir.string_field(user, "session_id") |> should.equal(Ok("synthetic-session"))
  ir.field(user, "future") |> should.equal(Some(ir.Boolean(True)))
  request.prepare(
    "http://localhost:19444",
    request.OAuth("synthetic"),
    request.Messages(False),
    [],
    None,
    body,
  )
  |> should.equal(Error("Missing Claude OAuth credential identity"))
}

pub fn beta_order_duplicates_and_forced_thinking_test() {
  let input =
    "{\"model\":\"claude-synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"thinking\":{\"type\":\"adaptive\"},\"tool_choice\":{\"type\":\"tool\",\"name\":\"synthetic\"},\"output_config\":{\"effort\":\"high\",\"format\":{\"type\":\"json_schema\"}},\"betas\":[\"future-beta\",\"body-beta\"]}"
  let incoming = [
    Header(
      "Anthropic-Beta",
      "claude-code-20250219, future-beta,effort-2025-11-24",
    ),
    Header("anthropic-beta", "thinking-display-updates-2026-08-18,future-beta"),
  ]
  let assert Ok(prepared) =
    request.prepare(
      "http://localhost:19444",
      request.OAuth("synthetic"),
      request.Messages(False),
      incoming,
      session(),
      input,
    )
  header(prepared, "anthropic-beta")
  |> should.equal([
    "claude-code-20250219,oauth-2025-04-20,future-beta,body-beta",
  ])
  let assert Ok(value) = ir.parse(prepared.body)
  ir.field(value, "thinking") |> should.equal(None)
  ir.field(value, "betas") |> should.equal(None)
  let assert Ok(output) = ir.required(value, "output_config")
  ir.field(output, "effort") |> should.equal(None)
  ir.field(output, "format") |> should.not_equal(None)
}

pub fn thinking_display_sampling_and_haiku_effort_test() {
  let input =
    "{\"model\":\"claude-haiku-synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"thinking\":{\"type\":\"enabled\",\"display\":\"updates\"},\"temperature\":0.5,\"top_p\":0.5,\"top_k\":3}"
  let headers = [
    Header(
      "anthropic-beta",
      "redact-thinking-2026-02-12,thinking-display-updates-2026-08-18,effort-2025-11-24,oauth-2025-04-20",
    ),
  ]
  let assert Ok(prepared) =
    request.prepare(
      "http://localhost:19444",
      request.ApiKey("synthetic"),
      request.Messages(False),
      headers,
      None,
      input,
    )
  header(prepared, "anthropic-beta")
  |> should.equal(["thinking-display-updates-2026-08-18"])
  let assert Ok(value) = ir.parse(prepared.body)
  list.each(["temperature", "top_p", "top_k"], fn(k) {
    ir.field(value, k) |> should.equal(None)
  })
}

pub fn stream_mode_is_one_authority_test() {
  let assert Ok(prepared) =
    request.prepare(
      "http://localhost:19444",
      request.ApiKey("synthetic"),
      request.Messages(True),
      [],
      None,
      body,
    )
  header(prepared, "accept") |> should.equal(["text/event-stream"])
  let assert Ok(value) = ir.parse(prepared.body)
  ir.field(value, "stream") |> should.equal(Some(ir.Boolean(True)))
  request.prepare(
    "http://localhost:19444",
    request.ApiKey("synthetic"),
    request.Messages(False),
    [],
    None,
    prepared.body,
  )
  |> should.be_error
  request.prepare(
    "http://localhost:19444",
    request.ApiKey("synthetic"),
    request.CountTokens,
    [],
    None,
    prepared.body,
  )
  |> should.be_error
}

pub fn cache_ttl_order_and_breakpoint_limit_test() {
  let long =
    "{\"type\":\"text\",\"text\":\"synthetic\",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}}"
  let short =
    "{\"type\":\"text\",\"text\":\"synthetic\",\"cache_control\":{\"type\":\"ephemeral\"}}"
  let assert Ok(good) =
    ir.parse("{\"system\":[" <> long <> "," <> short <> "]}")
  cache.validate(good) |> should.equal(Ok(cache.Summary(2, True)))
  let assert Ok(bad) = ir.parse("{\"system\":[" <> short <> "," <> long <> "]}")
  cache.validate(bad) |> should.be_error
  let assert Ok(four) =
    ir.parse("{\"system\":[" <> string.join(list.repeat(short, 4), ",") <> "]}")
  cache.validate(four) |> should.equal(Ok(cache.Summary(4, False)))
  let assert Ok(five) =
    ir.parse("{\"system\":[" <> string.join(list.repeat(short, 5), ",") <> "]}")
  cache.validate(five) |> should.be_error
  let assert Ok(unsupported) =
    ir.parse("{\"cache_control\":{\"type\":\"ephemeral\"}}")
  cache.validate(unsupported) |> should.be_error
}

pub fn untrusted_origin_and_header_injection_test() {
  list.each(
    [
      "http://example.invalid", "https://user:secret@example.invalid",
      "https://example.invalid/path", "https://example.invalid?query=1",
    ],
    fn(origin) {
      request.prepare(
        origin,
        request.ApiKey("synthetic"),
        request.Messages(False),
        [],
        None,
        body,
      )
      |> should.be_error
    },
  )
  request.prepare(
    "http://localhost:19444",
    request.ApiKey("synthetic\r\nInjected: yes"),
    request.Messages(False),
    [],
    None,
    body,
  )
  |> should.be_error
  let injected =
    "{\"model\":\"synthetic\",\"messages\":[{}],\"betas\":[\"bad\\r\\nInjected: yes\"]}"
  request.prepare(
    "http://localhost:19444",
    request.ApiKey("synthetic"),
    request.Messages(False),
    [],
    None,
    injected,
  )
  |> should.be_error
  request.prepare(
    "http://localhost:19444",
    request.ApiKey("synthetic"),
    request.Messages(False),
    [Header("x-stainless-invalid:name", "synthetic")],
    None,
    body,
  )
  |> should.be_error
}

pub fn identity_and_legacy_metadata_validation_test() {
  identity.validate(identity.Account("invalid", "synthetic")) |> should.be_error
  let assert Ok(input) =
    ir.parse("{\"metadata\":{\"user_id\":\"legacy-opaque-synthetic\"}}")
  identity.apply(input, account(), "synthetic")
  |> should.equal(Error("Unsupported Claude metadata.user_id encoding"))
}
