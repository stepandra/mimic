/// Synthetic policy inputs. No native-client or provider measurements.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/ir
import mimic/providers/claude/adapter
import mimic/providers/claude/cache
import mimic/providers/claude/client_profile
import mimic/providers/claude/identity
import mimic/providers/claude/policy
import mimic/providers/claude/request
import mimic/providers/contracts
import mimic/types.{Header}
import simplifile

pub fn source_model_boundaries_test() {
  list.each(
    [
      #("claude-haiku-4-5-20251001", policy.Haiku),
      #("claude-3-haiku-20240307", policy.Haiku),
      #("claude-3-5-haiku-20241022", policy.Haiku),
      #("claude-3-7-sonnet-20250219", policy.Legacy),
      #("claude-opus-4-6", policy.Modern),
      #("claude-sonnet-4-5", policy.Modern),
      #("vendor/claude-opus-5-5[1m]", policy.Progress),
      #("claude-sonnet-5-20260923", policy.Progress),
      #("claude-fable-5-1", policy.Progress),
      #("claude-opus-5-50", policy.Unknown),
      #("future-synthetic", policy.Unknown),
    ],
    fn(pair) { policy.model(pair.0) |> should.equal(pair.1) },
  )
}

pub fn translated_and_native_sampling_matrix_test() {
  list.each([policy.NativeMessages, policy.TranslatedMessages], fn(input) {
    list.each(["enabled", "adaptive", "auto", "disabled"], fn(thinking) {
      let body =
        parse(
          "{\"thinking\":{\"type\":\""
          <> thinking
          <> "\"},\"temperature\":1,\"top_p\":0.99,\"top_k\":4,\"future\":{\"keep\":true}}",
        )
      let assert Ok(normalized) =
        policy.normalize(
          body,
          policy.Policy(input, policy.Conversation, policy.PreserveCache),
        )
      ir.field(normalized, "future") |> should.equal(ir.field(body, "future"))
      ir.field(normalized, "temperature")
      |> should.equal(case input {
        policy.NativeMessages -> Some(ir.Integer(1))
        policy.TranslatedMessages -> None
      })
      ir.field(normalized, "top_k")
      |> should.equal(case thinking {
        "disabled" -> Some(ir.Integer(4))
        _ -> None
      })
      ir.field(normalized, "top_p")
      |> should.equal(case input, thinking {
        policy.NativeMessages, "disabled" -> None
        policy.NativeMessages, _ -> Some(ir.Decimal(0.99))
        _, _ -> None
      })
    })
  })
  policy.normalize(parse("{\"top_p\":\"synthetic\"}"), policy.native())
  |> should.be_error
  policy.normalize(parse("{\"output_config\":[]}"), policy.native())
  |> should.be_error
}

pub fn forced_tool_preserves_extensions_test() {
  list.each(["any", "tool"], fn(choice) {
    let original =
      parse(
        "{\"tool_choice\":{\"type\":\""
        <> choice
        <> "\",\"name\":\"synthetic\"},\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\",\"format\":{\"type\":\"json_schema\"},\"future\":7},\"tools\":[{\"name\":\"synthetic\",\"input_schema\":{\"cache_control\":{\"const\":\"not-a-marker\"}}}]}",
      )
    let assert Ok(body) = policy.normalize(original, policy.native())
    ir.field(body, "thinking") |> should.equal(None)
    let assert Ok(output) = ir.required(body, "output_config")
    ir.field(output, "effort") |> should.equal(None)
    ir.field(output, "future") |> should.equal(Some(ir.Integer(7)))
    ir.field(body, "tools") |> should.equal(ir.field(original, "tools"))
    ir.field(body, "tool_choice")
    |> should.equal(ir.field(original, "tool_choice"))
  })
}

pub fn cache_selection_and_explicit_ownership_test() {
  let body =
    parse(
      "{\"system\":\"synthetic system\",\"tools\":[{\"name\":\"synthetic\"}],\"messages\":[{\"role\":\"user\",\"content\":\"λ\"},{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"synthetic\",\"signature\":\"synthetic\"}]}]}",
    )
  list.each([policy.DefaultFiveMinutes, policy.ApprovedOneHour], fn(selection) {
    let assert Ok(normalized) =
      cache.ensure_translated(body, True, translated(selection))
    cache.validate(normalized)
    |> should.equal(Ok(cache.Summary(2, selection == policy.ApprovedOneHour)))
    ir.field(normalized, "tools") |> should.equal(ir.field(body, "tools"))
    let assert Ok(messages) =
      ir.required(normalized, "messages") |> result.try(ir.as_array)
    let assert Ok(last) = list.last(messages)
    let assert Ok(original) =
      ir.required(body, "messages") |> result.try(ir.as_array)
    list.last(original) |> should.equal(Ok(last))
  })
  cache.ensure_translated(body, False, translated(policy.ApprovedOneHour))
  |> should.be_error
  let explicit =
    parse(
      "{\"system\":[{\"type\":\"text\",\"text\":\"synthetic\",\"cache_control\":{\"type\":\"ephemeral\",\"scope\":\"global\",\"future\":true}}],\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  cache.ensure_translated(explicit, True, translated(policy.ApprovedOneHour))
  |> should.equal(Ok(explicit))
}

pub fn deferred_tools_final_system_and_ttl_order_test() {
  let body =
    parse(
      "{\"tools\":[{\"name\":\"first\"},{\"name\":\"deferred\",\"defer_loading\":true}],\"messages\":[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"system\",\"content\":\"last\"}]}",
    )
  let assert Ok(normalized) =
    cache.ensure_translated(body, False, translated(policy.DefaultFiveMinutes))
  cache.validate(normalized) |> should.equal(Ok(cache.Summary(2, False)))
  let assert Some(ir.Array([first, deferred])) = ir.field(normalized, "tools")
  ir.field(first, "cache_control") |> should.not_equal(None)
  ir.field(deferred, "cache_control") |> should.equal(None)
  let assert Some(ir.Array([user, system])) = ir.field(normalized, "messages")
  ir.field(user, "content") |> should.equal(Some(ir.String("hi")))
  let assert Some(ir.Array([block])) = ir.field(system, "content")
  ir.field(block, "cache_control") |> should.not_equal(None)
  let invalid =
    parse(
      "{\"tools\":[{\"cache_control\":{\"type\":\"ephemeral\"}}],\"system\":[{\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}}]}",
    )
  cache.ensure_translated(invalid, True, translated(policy.ApprovedOneHour))
  |> should.be_error
}

pub fn auth_model_operation_beta_matrix_test() {
  list.each(
    [
      "claude-haiku-4-5",
      "claude-3-haiku-20240307",
      "claude-opus-4-6",
      "claude-sonnet-5",
      "future-synthetic",
    ],
    fn(model) {
      list.each(
        [request.ApiKey("synthetic-key"), request.OAuth("synthetic-access")],
        fn(auth) {
          list.each(
            [
              request.Messages(False),
              request.Messages(True),
              request.CountTokens,
            ],
            fn(operation) {
              let source =
                "{\"model\":\""
                <> model
                <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"betas\":[\"future-a\",\"effort-2025-11-24\",\"future-b\",\"extended-cache-ttl-2025-04-11\",\"future-a\"]}"
              let assert Ok(capture) =
                request.prepare_with_policy(
                  "http://127.0.0.1:19444",
                  auth,
                  operation,
                  [],
                  account(),
                  source,
                  translated(policy.PreserveCache),
                )
              let beta =
                list.find(capture.headers, fn(h) { h.name == "anthropic-beta" })
              let assert Ok(beta) = beta
              let betas = string.split(beta.value, ",")
              list.filter(betas, fn(b) { string.starts_with(b, "future-") })
              |> should.equal(["future-a", "future-b"])
              list.contains(betas, "oauth-2025-04-20")
              |> should.equal(case auth {
                request.OAuth(_) -> True
                _ -> False
              })
              case operation {
                request.CountTokens -> {
                  beta.value
                  |> should.equal(
                    "claude-code-20250219,"
                    <> case auth {
                      request.OAuth(_) -> "oauth-2025-04-20,"
                      _ -> ""
                    }
                    <> "interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01,future-a,future-b",
                  )
                }
                _ ->
                  list.contains(betas, "effort-2025-11-24")
                  |> should.equal(policy.model(model) != policy.Haiku)
              }
            },
          )
        },
      )
    },
  )
}

pub fn approved_profile_rejects_credentials_and_duplicate_identity_test() {
  let context =
    contracts.Context(
      "claude",
      "api_key",
      "synthetic-account",
      "http://127.0.0.1:19444",
      "synthetic-session",
      contracts.ApiKey("synthetic"),
    )
  list.each(
    [
      "Authorization",
      "x-api-key",
      "Host",
      "x-client-request-id",
      "X-Claude-Code-Session-Id",
      "Cookie",
    ],
    fn(name) {
      client_profile.from_operator(context, [Header(name, "synthetic")])
      |> should.be_error
    },
  )
  client_profile.from_operator(context, [
    Header("User-Agent", "a"),
    Header("user-agent", "b"),
  ])
  |> should.be_error
  client_profile.from_operator(context, [Header("User-Agent", "bad\u{007f}")])
  |> should.be_error
  let headers = [
    Header("User-Agent", "synthetic-approved"),
    Header("X-Claude-Code-Agent-Type", "synthetic"),
    Header("X-Stainless-Package-Version", "synthetic"),
  ]
  let assert Ok(profile) = client_profile.from_operator(context, headers)
  client_profile.for_context(profile, context) |> should.equal(Ok(headers))
  list.each(
    [
      contracts.Context(..context, account: "other"),
      contracts.Context(..context, auth_mode: "oauth"),
      contracts.Context(..context, origin: "http://127.0.0.1:19445"),
      contracts.Context(..context, session_key: "other-session"),
    ],
    fn(other) { client_profile.for_context(profile, other) |> should.be_error },
  )
}

pub fn advisor_beta_order_and_identity_ambiguity_test() {
  let source =
    "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[{\"type\":\"advisor_synthetic\",\"name\":\"advisor\"}],\"betas\":[\"future-a\",\"effort-2025-11-24\",\"advisor-tool-2026-03-01\",\"future-b\"]}"
  let assert Ok(capture) =
    request.prepare(
      "http://127.0.0.1:19444",
      request.ApiKey("synthetic"),
      request.Messages(False),
      [],
      None,
      source,
    )
  let assert Ok(beta) =
    list.find(capture.headers, fn(h) { h.name == "anthropic-beta" })
  beta.value
  |> should.equal("future-a,advisor-tool-2026-03-01,effort-2025-11-24,future-b")
  let ambiguous =
    parse(
      "{\"metadata\":{\"user_id\":\"{\\\"device_id\\\":\\\"a\\\",\\\"device_\\\\u0069d\\\":\\\"b\\\"}\"}}",
    )
  identity.apply(
    ambiguous,
    identity.Account(string.repeat("a", 64), "synthetic-account"),
    "synthetic-session",
  )
  |> should.be_error
}

pub fn subagent_helper_cache_and_beta_matrix_test() {
  list.each([request.ApiKey("synthetic"), request.OAuth("synthetic")], fn(auth) {
    list.each([policy.Conversation, policy.Subagent, policy.Helper], fn(turn) {
      list.each([False, True], fn(one_hour) {
        let marker = case one_hour {
          True -> ",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}"
          False -> ""
        }
        let source =
          "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"synthetic\""
          <> marker
          <> "}]}],\"betas\":[\"future-a\",\"effort-2025-11-24\",\"thinking-display-updates-2026-08-18\",\"extended-cache-ttl-2025-04-11\"]}"
        let prepared =
          request.prepare_with_policy(
            "http://127.0.0.1:19444",
            auth,
            request.Messages(False),
            [],
            account(),
            source,
            policy.Policy(policy.NativeMessages, turn, policy.PreserveCache),
          )
        case turn == policy.Helper && one_hour {
          True -> {
            prepared |> should.be_error
            Nil
          }
          False -> {
            let assert Ok(prepared) = prepared
            let assert Ok(beta) =
              list.find(prepared.headers, fn(h) { h.name == "anthropic-beta" })
            let betas = string.split(beta.value, ",")
            list.contains(betas, "future-a") |> should.be_true
            list.contains(betas, "extended-cache-ttl-2025-04-11")
            |> should.equal(turn == policy.Conversation || one_hour)
            list.contains(betas, "effort-2025-11-24")
            |> should.equal(turn != policy.Helper)
            list.contains(betas, "thinking-display-updates-2026-08-18")
            |> should.equal(turn != policy.Helper)
          }
        }
      })
    })
  })
}

pub fn differential_fixture_expectations_test() {
  let assert Ok(source) =
    simplifile.read("test/fixtures/claude/policy_v1/differential.json")
  let root = parse(source)
  let assert Ok(cases) = ir.required(root, "cases") |> result.try(ir.as_array)
  list.each(cases, fn(case_) {
    let assert Ok(input) = ir.required(case_, "input")
    let assert Ok(expected) = ir.required(case_, "expected")
    let assert Ok(kind) = ir.string_field(case_, "input_policy")
    let selected = case kind {
      "NativeMessages/Conversation/PreserveCache" -> policy.native()
      "TranslatedMessages/Conversation/DefaultFiveMinutes" ->
        translated(policy.DefaultFiveMinutes)
      _ -> translated(policy.PreserveCache)
    }
    let operation = case ir.string_field(case_, "operation") {
      Ok("messages/count_tokens") -> request.CountTokens
      _ -> request.Messages(False)
    }
    let assert Ok(capture) =
      request.prepare_with_policy(
        "http://127.0.0.1:19444",
        request.ApiKey("synthetic"),
        operation,
        [],
        None,
        ir.stringify(input),
        selected,
      )
    // Object key order is not a semantic difference; serialize canonical fixture
    // through the same IR equality rule by comparing fields recursively.
    equivalent(parse(capture.body), expected) |> should.be_true
    let actual = case
      list.find(capture.headers, fn(h) { h.name == "anthropic-beta" })
    {
      Ok(header) -> string.split(header.value, ",") |> list.map(ir.String)
      Error(_) -> []
    }
    ir.field(case_, "expected_betas") |> should.equal(Some(ir.Array(actual)))
  })
}

fn equivalent(a: ir.Value, b: ir.Value) -> Bool {
  case a, b {
    ir.Object(a), ir.Object(b) ->
      list.length(a) == list.length(b)
      && list.all(a, fn(field) {
        case list.key_find(b, field.0) {
          Ok(value) -> equivalent(field.1, value)
          Error(_) -> False
        }
      })
    ir.Array(a), ir.Array(b) ->
      list.length(a) == list.length(b)
      && list.all(list.zip(a, b), fn(pair) { equivalent(pair.0, pair.1) })
    _, _ -> a == b
  }
}

pub fn runtime_identity_isolation_and_context_guard_test() {
  let req =
    contracts.Request(
      "claude",
      "oauth",
      "claude-opus-4-6",
      "claude",
      "messages",
      contracts.Buffered,
      [],
      "untrusted-session",
      None,
      "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"metadata\":{\"user_id\":\"{\\\"device_id\\\":\\\"caller\\\",\\\"account_uuid\\\":\\\"caller\\\",\\\"session_id\\\":\\\"caller\\\",\\\"future\\\":true}\"}}",
    )
  list.each(["a", "b"], fn(account) {
    let context =
      contracts.Context(
        "claude",
        "oauth",
        account,
        "http://127.0.0.1:19444",
        "trusted-session-" <> account,
        contracts.OAuth(
          contracts.OAuthData(
            auth.Credential(
              "synthetic-" <> account,
              "synthetic-refresh",
              100_000,
            ),
            [
              #("device_id", string.repeat(account, 64)),
              #("account_uuid", account),
            ],
          ),
        ),
      )
    let assert Ok(capture) = adapter.prepare(context, req)
    let body = parse(capture.body)
    let assert Ok(metadata) = ir.required(body, "metadata")
    let assert Ok(user) = ir.string_field(metadata, "user_id")
    let user = parse(user)
    ir.string_field(user, "account_uuid") |> should.equal(Ok(account))
    ir.string_field(user, "session_id") |> should.equal(Ok(context.session_key))
    ir.field(user, "future") |> should.equal(Some(ir.Boolean(True)))
    adapter.prepare(contracts.Context(..context, provider: "other"), req)
    |> should.equal(
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
    )
    adapter.prepare(context, contracts.Request(..req, model: "other-model"))
    |> should.equal(
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
    )
    adapter.prepare(context, contracts.Request(..req, auth_mode: "api_key"))
    |> should.be_error
    adapter.prepare(
      context,
      contracts.Request(
        ..req,
        body: "{\"model\":\"claude-opus-4-6\",\"mod\\u0065l\":\"other\",\"messages\":[{}]}",
      ),
    )
    |> should.be_error
  })
}

fn parse(source) {
  let assert Ok(body) = ir.parse(source)
  body
}

fn translated(cache) {
  policy.Policy(policy.TranslatedMessages, policy.Conversation, cache)
}

fn account() {
  Some(request.Identity(
    "synthetic-session",
    "synthetic-request",
    Some(identity.Account(string.repeat("a", 64), "synthetic-account")),
  ))
}
