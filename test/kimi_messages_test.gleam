import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/messages
import mimic/providers/kimi/request

pub fn messages_preserve_signed_thinking_tools_and_native_extensions_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"max_tokens\":128,\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"synthetic\",\"signature\":\"synthetic-signature\"},{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"lookup\",\"input\":{\"q\":\"synthetic\"}}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call_1\",\"content\":\"synthetic\"}]}],\"native_extension\":true}"
  let assert Ok(prepared) = messages.prepare(body, "kimi-k2.8", False)
  let assert Ok(original) = ir.parse(body)
  let assert Ok(value) = ir.parse(prepared)
  ir.field(value, "messages") |> should.equal(ir.field(original, "messages"))
  ir.field(value, "native_extension") |> should.equal(Some(ir.Boolean(True)))
}

pub fn messages_use_kimi_auth_and_shared_native_route_not_claude_oauth_test() {
  let context =
    contracts.Context(
      "kimi",
      "api_key",
      "synthetic-account",
      "http://127.0.0.1:8000",
      "session-key",
      contracts.ApiKey("synthetic"),
    )
  let req =
    contracts.Request(
      "kimi",
      "api_key",
      "kimi-k2.8",
      "anthropic",
      "messages",
      contracts.Buffered,
      [],
      "session",
      None,
      "{\"model\":\"kimi-k2.8\",\"max_tokens\":128,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}",
    )
  let assert Ok(plan) = request.prepare_at("/coding/v1", context, req)
  plan.target |> should.equal("/coding/v1/messages?beta=true")
  list.any(plan.headers, fn(header) { header.name == "x-api-key" })
  |> should.be_false
  list.any(plan.headers, fn(header) {
    header.name == "Authorization" && header.value == "Bearer synthetic"
  })
  |> should.be_true
}

pub fn messages_unknown_media_and_unsigned_thinking_fail_explicitly_test() {
  list.each(
    [
      "{\"type\":\"thinking\",\"thinking\":\"synthetic\"}",
      "{\"type\":\"audio\",\"data\":\"synthetic\"}",
    ],
    fn(block) {
      messages.prepare(
        "{\"model\":\"kimi-k2.8\",\"max_tokens\":128,\"messages\":[{\"role\":\"user\",\"content\":["
          <> block
          <> "]}]}",
        "kimi-k2.8",
        False,
      )
      |> should.be_error
    },
  )
}

pub fn messages_orphan_and_duplicate_tool_ids_are_rejected_test() {
  list.each(
    [
      "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"orphan\",\"content\":\"synthetic\"}]}",
      "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"same\",\"name\":\"lookup\",\"input\":{}},{\"type\":\"tool_use\",\"id\":\"same\",\"name\":\"lookup\",\"input\":{}}]}",
    ],
    fn(message) {
      messages.prepare(
        "{\"model\":\"kimi-k2.8\",\"max_tokens\":128,\"messages\":["
          <> message
          <> "]}",
        "kimi-k2.8",
        False,
      )
      |> should.be_error
    },
  )
}
