/// Synthetic, source-derived F09 inputs. Never native captures or live calls.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/providers/claude/cache
import mimic/providers/claude/client_profile
import mimic/providers/claude/identity
import mimic/providers/claude/policy
import mimic/providers/claude/request
import mimic/types.{type Capture, type Header, Header}
import mimic/wire
import simplifile

const origin = "http://127.0.0.1:19444"

const minimal = "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}]}"

pub type Golden {
  Golden(
    id: String,
    selected: policy.Policy,
    operation: request.Operation,
    auth: String,
    headers: List(Header),
    source: String,
    body: String,
    beta: String,
  )
}

pub fn goldens() -> List(Golden) {
  let assert Ok(source) =
    simplifile.read("test/fixtures/claude/f09/ordered.json")
  let root = parse(source)
  ir.string_field(root, "source_pin")
  |> should.equal(Ok("acdace936fa7df2905500c7f5e0a97d683138dea"))
  let assert Ok(cases) = ir.required(root, "cases") |> result.try(ir.as_array)
  list.map(cases, fn(case_) {
    let assert Ok(headers) =
      ir.required(case_, "headers") |> result.try(ir.as_array)
    Golden(
      field(case_, "id"),
      policy.Policy(
        case field(case_, "input") {
          "native" -> policy.NativeMessages
          "translated" -> policy.TranslatedMessages
          _ -> panic as "unsupported synthetic policy"
        },
        case field(case_, "turn") {
          "conversation" -> policy.Conversation
          "subagent" -> policy.Subagent
          "helper" -> policy.Helper
          _ -> panic as "unsupported synthetic turn"
        },
        case field(case_, "cache") {
          "preserve" -> policy.PreserveCache
          "5m" -> policy.DefaultFiveMinutes
          "1h" -> policy.ApprovedOneHour
          _ -> panic as "unsupported synthetic cache"
        },
      ),
      case field(case_, "operation") {
        "messages" -> request.Messages(False)
        "count" -> request.CountTokens
        _ -> panic as "unsupported synthetic operation"
      },
      field(case_, "auth"),
      list.map(headers, fn(header) {
        let assert ir.Array([ir.String(name), ir.String(value)]) = header
        Header(name, value)
      }),
      field(case_, "source"),
      field(case_, "body"),
      field(case_, "beta"),
    )
  })
}

/// Separately authored source-derived expectations, not function-generated
/// captures. Compare the entire ordered request line/headers/body/UTF-8 length.
pub fn source_derived_ordered_wire_goldens_test() {
  list.each(goldens(), fn(golden) {
    let credential = case golden.auth {
      "api_key" -> request.ApiKey("synthetic-key")
      "oauth" -> request.OAuth("synthetic-access")
      _ -> panic as "unsupported synthetic auth"
    }
    let assert Ok(capture) =
      request.prepare_with_policy(
        origin,
        credential,
        golden.operation,
        golden.headers,
        case golden.auth {
          "oauth" -> session()
          _ -> None
        },
        golden.source,
        golden.selected,
      )
    let target = case golden.operation {
      request.CountTokens -> "/v1/messages/count_tokens?beta=true"
      _ -> "/v1/messages?beta=true"
    }
    let auth = case golden.auth {
      "oauth" -> "Authorization: Bearer synthetic-access\r\n"
      _ -> "x-api-key: synthetic-key\r\n"
    }
    let beta = case golden.beta {
      "" -> ""
      beta -> "anthropic-beta: " <> beta <> "\r\n"
    }
    let hints =
      golden.headers
      |> list.filter(fn(h) { string.lowercase(h.name) != "anthropic-beta" })
      |> list.map(fn(h) { h.name <> ": " <> h.value <> "\r\n" })
      |> string.join("")
    let identity = case golden.auth {
      "oauth" ->
        "X-Claude-Code-Session-Id: synthetic-session\r\nx-client-request-id: synthetic-request\r\n"
      _ -> ""
    }
    wire.render_request(capture)
    |> should.equal(Ok(
      "POST "
      <> target
      <> " HTTP/1.1\r\nHost: 127.0.0.1:19444\r\n"
      <> auth
      <> "Content-Type: application/json\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nanthropic-version: 2023-06-01\r\n"
      <> beta
      <> hints
      <> identity
      <> "Content-Length: "
      <> int.to_string(string.byte_size(golden.body))
      <> "\r\n\r\n"
      <> golden.body,
    ))
  })
}

pub fn all_managed_beta_and_unmanaged_count_policy_test() {
  let managed = [
    "claude-code-20250219", "oauth-2025-04-20",
    "interleaved-thinking-2025-05-14", "redact-thinking-2026-02-12",
    "thinking-token-count-2026-05-13", "context-management-2025-06-27",
    "prompt-caching-scope-2026-01-05", "token-counting-2024-11-01",
    "context-1m-2025-08-07", "mid-conversation-system-2026-04-07",
    "per-turn-control-2026-07-01", "timing-2026-09-09",
    "mid-conversation-tool-changes-2026-07-01", "inline-tools-2026-09-15",
    "advisor-tool-2026-03-01", "advanced-tool-use-2025-11-20",
    "mid-conversation-system-clear-at-2026-08-21",
    "dangerous-tool-use-2026-09-03", "effort-2025-11-24",
    "server-side-fallback-2026-06-01", "fallback-credit-2026-06-01",
    "structured-outputs-2025-12-15", "thinking-binding-controls-2026-08-01",
    "thinking-display-updates-2026-08-18", "thinking-resumption-2026-07-17",
    "fast-mode-2026-02-01", "afk-mode-2026-01-31",
    "extended-cache-ttl-2025-04-11", "prompt-caching-evict-2026-05-12",
    "cache-diagnosis-2026-04-07",
  ]
  list.each(managed, fn(beta) { request.managed_beta(beta) |> should.be_true })
  request.managed_beta("future-a") |> should.be_false
  reviewed_beta(
    string.join(managed, ",") <> ",future-a,future-b",
    minimal,
    request.CountTokens,
    policy.Policy(
      policy.TranslatedMessages,
      policy.Conversation,
      policy.PreserveCache,
    ),
  )
  |> should.equal(
    "claude-code-20250219,interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01,advisor-tool-2026-03-01,future-a,future-b",
  )
}

/// P2: positioning precedes ALL final trailer-removal gates.
pub fn advisor_position_survives_final_removal_gates_test() {
  list.each(
    [
      #(
        "claude-haiku-4-5",
        "server-side-fallback-2026-06-01",
        "",
        policy.Conversation,
      ),
      #("claude-haiku-4-5", "effort-2025-11-24", "", policy.Conversation),
      #(
        "claude-opus-4-6",
        "effort-2025-11-24",
        ",\"thinking\":{\"type\":\"disabled\"}",
        policy.Conversation,
      ),
      #("claude-opus-4-6", "extended-cache-ttl-2025-04-11", "", policy.Subagent),
      #(
        "claude-opus-4-6",
        "effort-2025-11-24",
        ",\"tool_choice\":{\"type\":\"any\"}",
        policy.Conversation,
      ),
    ],
    fn(row) {
      list.each(
        [
          "future-a," <> row.1 <> ",future-b,advisor-tool-2026-03-01",
          "advisor-tool-2026-03-01,future-a," <> row.1 <> ",future-b",
          "future-a,advisor-tool-2026-03-01,"
            <> row.1
            <> ",future-b,advisor-tool-2026-03-01",
        ],
        fn(header) {
          reviewed_beta(
            header,
            reviewed_body(row.0, row.2),
            request.Messages(False),
            policy.Policy(policy.NativeMessages, row.3, policy.PreserveCache),
          )
          |> should.equal("future-a,advisor-tool-2026-03-01,future-b")
        },
      )
    },
  )
}

pub fn header_profile_precedes_protocol_and_body_extras_test() {
  list.each(
    [
      #(
        ",\"tools\":[{\"type\":\" Advisor_synthetic \"}],\"betas\":[\"future-body\"]",
        "future-header,advisor-tool-2026-03-01,future-body",
      ),
      #(
        ",\"betas\":[\"future-body\",\"advisor-tool-2026-03-01\"]",
        "future-header,advisor-tool-2026-03-01,future-body",
      ),
      #(
        ",\"speed\":\"fast\",\"betas\":[\"future-body\"]",
        "future-header,fast-mode-2026-02-01,future-body",
      ),
      #(
        ",\"betas\":[\"future-body\",\"future-header\",\"oauth-2025-04-20\"]",
        "future-header,future-body",
      ),
    ],
    fn(row) {
      list.each(
        [request.Messages(False), request.Messages(True), request.CountTokens],
        fn(operation) {
          reviewed_beta(
            "future-header",
            reviewed_body("claude-opus-4-6", row.0),
            operation,
            policy.native(),
          )
          |> should.equal(
            row.1
            <> case operation {
              request.CountTokens -> ",token-counting-2024-11-01"
              _ -> ""
            },
          )
        },
      )
    },
  )
}

pub fn translated_count_advisor_precedes_unmanaged_extras_test() {
  list.each(
    [
      #("future-header,advisor-tool-2026-03-01", ",\"betas\":[\"future-body\"]"),
      #(
        "future-header",
        ",\"tools\":[{\"type\":\"advisor_synthetic\"}],\"betas\":[\"future-body\"]",
      ),
      #(
        "future-header",
        ",\"betas\":[\"future-body\",\"advisor-tool-2026-03-01\"]",
      ),
    ],
    fn(row) {
      reviewed_beta(
        row.0,
        reviewed_body("claude-opus-4-6", row.1),
        request.CountTokens,
        policy.Policy(
          policy.TranslatedMessages,
          policy.Conversation,
          policy.PreserveCache,
        ),
      )
      |> should.equal(
        "claude-code-20250219,interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01,advisor-tool-2026-03-01,future-header,future-body",
      )
    },
  )
}

/// P3: a prefix containing Haiku still gates the full supplied alias.
pub fn full_model_alias_uses_source_haiku_lexical_gate_test() {
  list.each(
    ["haiku-team/future-model", "team/claude-haiku-4-5", "claude-haiku-4-5"],
    fn(model) {
      policy.model(model) |> should.equal(policy.Haiku)
      reviewed_beta(
        "effort-2025-11-24,server-side-fallback-2026-06-01,future-a",
        reviewed_body(model, ""),
        request.Messages(False),
        policy.native(),
      )
      |> should.equal("future-a")
    },
  )
}

pub fn credential_and_operation_beta_staging_controls_test() {
  list.each([False, True], fn(oauth) {
    list.each([policy.NativeMessages, policy.TranslatedMessages], fn(input) {
      list.each(
        [request.Messages(False), request.Messages(True), request.CountTokens],
        fn(operation) {
          let assert Ok(capture) =
            request.prepare_with_policy(
              origin,
              case oauth {
                True -> request.OAuth("synthetic-access")
                False -> request.ApiKey("synthetic-key")
              },
              operation,
              [Header("anthropic-beta", "claude-code-20250219,future-header")],
              session(),
              reviewed_body(
                "claude-opus-4-6",
                ",\"tools\":[{\"type\":\"advisor_synthetic\"}],\"speed\":\"fast\",\"betas\":[\"future-body\",\"oauth-2025-04-20\"]",
              ),
              policy.Policy(input, policy.Conversation, policy.PreserveCache),
            )
          let prefix =
            "claude-code-20250219"
            <> case oauth {
              True -> ",oauth-2025-04-20"
              False -> ""
            }
          beta(capture)
          |> should.equal(case operation, input {
            request.CountTokens, policy.TranslatedMessages ->
              prefix
              <> ",interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01,advisor-tool-2026-03-01,future-header,future-body"
            _, _ ->
              prefix
              <> ",future-header,advisor-tool-2026-03-01,fast-mode-2026-02-01,future-body"
              <> case operation {
                request.CountTokens -> ",token-counting-2024-11-01"
                _ -> ""
              }
          })
        },
      )
    })
  })
}

pub fn count_does_not_run_messages_normalization_test() {
  let source =
    reviewed_body(
      "claude-opus-4-6",
      ",\"thinking\":{\"type\":\"adaptive\",\"future\":true},\"tool_choice\":{\"type\":\"tool\",\"name\":\"synthetic\"},\"output_config\":{\"effort\":\"high\",\"future\":7},\"temperature\":0.4,\"top_p\":0.2,\"top_k\":3,\"future\":{\"keep\":true}",
    )
  list.each([policy.NativeMessages, policy.TranslatedMessages], fn(input) {
    let assert Ok(capture) =
      request.prepare_with_policy(
        origin,
        request.ApiKey("synthetic-key"),
        request.CountTokens,
        [],
        None,
        source,
        policy.Policy(input, policy.Conversation, policy.PreserveCache),
      )
    capture.body |> should.equal(source)
    capture.target |> should.equal("/v1/messages/count_tokens?beta=true")
  })
}

pub fn count_prune_is_explicit_cross_origin_contract_test() {
  // Preparation only: NEVER network to these HTTPS origins.
  let assert Ok(golden) =
    list.find(goldens(), fn(g) { g.id == "native-count-controls-and-pruning" })
  list.each(
    [
      "https://api.anthropic.com",
      "https://operator.example.invalid",
      "http://127.0.0.1:19444",
      "http://localhost:19444",
    ],
    fn(origin) {
      list.each([False, True], fn(oauth) {
        list.each([policy.NativeMessages, policy.TranslatedMessages], fn(input) {
          let assert Ok(capture) =
            request.prepare_with_policy(
              origin,
              case oauth {
                True -> request.OAuth("synthetic-access")
                False -> request.ApiKey("synthetic-key")
              },
              request.CountTokens,
              golden.headers,
              session(),
              golden.source,
              policy.Policy(input, policy.Conversation, policy.PreserveCache),
            )
          capture.body |> should.equal(golden.body)
        })
      })
    },
  )
}

pub fn invalid_cache_and_policy_matrix_test() {
  let short = "{\"type\":\"text\",\"cache_control\":{\"type\":\"ephemeral\"}}"
  let long =
    "{\"type\":\"text\",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}}"
  list.each(
    [
      "{\"tools\":[" <> short <> "],\"system\":[" <> long <> "]}",
      "{\"system\":["
        <> short
        <> "],\"messages\":[{\"content\":["
        <> long
        <> "]}]}",
      "{\"system\":[" <> string.join(list.repeat(short, 5), ",") <> "]}",
      "{\"system\":[{\"cache_control\":{\"type\":\"future\"}}]}",
      "{\"system\":[{\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"2h\"}}]}",
      "{\"system\":[{\"cache_control\":null}]}",
      "{\"cache_control\":{\"type\":\"ephemeral\"}}",
      "{\"tools\":{\"cache_control\":{\"type\":\"ephemeral\"}}}",
      "{\"system\":{\"cache_control\":{\"type\":\"ephemeral\"}}}",
      "{\"messages\":[{\"role\":\"user\",\"cache_control\":{\"type\":\"ephemeral\"},\"content\":\"λ\"}]}",
      "{\"messages\":[{\"role\":\"user\",\"content\":{\"cache_control\":{\"type\":\"ephemeral\"}}}]}",
      "{\"messages\":[{\"role\":\"user\",\"content\":[\"not-a-block\"]}]}",
    ],
    fn(source) { cache.validate(parse(source)) |> should.be_error },
  )
  list.each([False, True], fn(oauth) {
    let auth = case oauth {
      True -> request.OAuth("synthetic-access")
      False -> request.ApiKey("synthetic-key")
    }
    list.each(
      [request.Messages(False), request.Messages(True), request.CountTokens],
      fn(op) {
        request.prepare_with_policy(
          origin,
          auth,
          op,
          [],
          session(),
          "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":["
            <> long
            <> "]}]}",
          policy.Policy(
            policy.NativeMessages,
            policy.Helper,
            policy.PreserveCache,
          ),
        )
        |> should.be_error
        let prepared =
          request.prepare_with_policy(
            origin,
            auth,
            op,
            [],
            session(),
            minimal,
            policy.Policy(
              policy.TranslatedMessages,
              policy.Conversation,
              policy.ApprovedOneHour,
            ),
          )
        case oauth {
          True -> {
            prepared |> should.be_ok
            Nil
          }
          False -> {
            prepared |> should.be_error
            Nil
          }
        }
        request.prepare_with_policy(
          origin,
          auth,
          op,
          [],
          session(),
          minimal,
          policy.Policy(
            policy.NativeMessages,
            policy.Conversation,
            policy.DefaultFiveMinutes,
          ),
        )
        |> should.be_error
      },
    )
  })
}

pub fn source_predicates_do_not_rewrite_caller_values_test() {
  let body =
    parse(
      "{\"thinking\":{\"type\":\" Adaptive \"},\"temperature\":0.5,\"top_p\":0.94,\"top_k\":3,\"future\":true}",
    )
  let assert Ok(normalized) = policy.normalize(body, policy.native())
  list.each(["temperature", "top_p", "top_k"], fn(key) {
    ir.field(normalized, key) |> should.equal(None)
  })
  ir.field(normalized, "thinking") |> should.equal(ir.field(body, "thinking"))
  ir.field(normalized, "future") |> should.equal(Some(ir.Boolean(True)))
}

pub fn direct_request_uses_shared_ambiguity_and_header_guards_test() {
  request.prepare(
    origin,
    request.ApiKey("synthetic-key"),
    request.Messages(False),
    [],
    None,
    "{\"model\":\"claude-opus-4-6\",\"mod\\u0065l\":\"claude-haiku-4-5\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}]}",
  )
  |> should.be_error
  list.each(["synthetic\u{0001}", "synthetic\u{007f}"], fn(value) {
    request.prepare(
      origin,
      request.ApiKey(value),
      request.Messages(False),
      [],
      None,
      minimal,
    )
    |> should.be_error
  })
  client_profile.validate_headers([
    Header("User-Agent", "a"),
    Header("user-agent", "b"),
  ])
  |> should.be_error
}

fn reviewed_body(model: String, fields: String) -> String {
  "{\"model\":\""
  <> model
  <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}]"
  <> fields
  <> "}"
}

fn reviewed_beta(header, body, operation, selected) -> String {
  let assert Ok(capture) =
    request.prepare_with_policy(
      origin,
      request.ApiKey("synthetic-key"),
      operation,
      [Header("anthropic-beta", header)],
      None,
      body,
      selected,
    )
  beta(capture)
}

fn parse(source: String) -> ir.Value {
  let assert Ok(body) = ir.parse(source)
  body
}

fn field(body: ir.Value, key: String) -> String {
  let assert Ok(value) = ir.string_field(body, key)
  value
}

fn beta(capture: Capture) -> String {
  list.find(capture.headers, fn(header) {
    string.lowercase(header.name) == "anthropic-beta"
  })
  |> result.map(fn(header) { header.value })
  |> result.unwrap("")
}

fn session() {
  Some(request.Identity(
    "synthetic-session",
    "synthetic-request",
    Some(identity.Account(string.repeat("a", 64), "synthetic-account")),
  ))
}
