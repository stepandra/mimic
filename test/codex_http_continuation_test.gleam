/// Synthetic, local policy tests. No provider or account discovery.
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/dialect/responses
import mimic/ir
import mimic/providers/codex/adapter
import mimic/providers/codex/fixtures
import mimic/providers/codex/models
import mimic/providers/codex/normalize
import mimic/providers/codex/response
import mimic/providers/codex/session
import mimic/providers/contracts

fn config() {
  adapter.Config("tenant", "synthetic-test/1", True, models.pinned(), None)
}

fn context() {
  contracts.Context(
    "codex",
    "oauth",
    "credential",
    "http://127.0.0.1:1234",
    "client",
    contracts.OAuth(
      contracts.OAuthData(
        auth.Credential("synthetic-access", "synthetic-refresh", 1_000_000),
        [#("chatgpt_account_id", "account")],
      ),
    ),
  )
}

fn request(body) {
  contracts.Request(
    "codex",
    "oauth",
    "gpt-5.5",
    "responses",
    "responses",
    contracts.Buffered,
    [],
    "client",
    Some("credential"),
    body,
  )
}

fn completion() {
  let assert Ok(plan) =
    adapter.prepare_native(config(), context(), request(fixtures.request))
  let assert Ok(collector) = response.new(plan)
  let assert Ok(batch) =
    response.feed(collector, bit_array.from_string(fixtures.sse()))
  let assert Ok(completion) = response.finish(batch.0)
  completion
}

pub fn codex_http_scope_binds_origin_tenant_account_and_client_test() {
  let receipt = completion().continuation
  let cfg = adapter.Config(..config(), continuation: Some(receipt))
  let req = request(fixtures.continuation)
  adapter.prepare_native(cfg, context(), req) |> should.be_ok
  let assert contracts.OAuth(old) = context().credential
  list.each(
    [
      contracts.Context(..context(), origin: "http://127.0.0.1:5678"),
      contracts.Context(..context(), session_key: "other-client"),
      contracts.Context(..context(), account: "other-credential"),
      contracts.Context(
        ..context(),
        credential: contracts.OAuth(
          contracts.OAuthData(..old, private_metadata: [
            #("chatgpt_account_id", "other-account"),
          ]),
        ),
      ),
    ],
    fn(ctx) { adapter.prepare_native(cfg, ctx, req) |> should.be_error },
  )
  adapter.prepare_native(adapter.Config(..cfg, tenant: "other"), context(), req)
  |> should.be_error
  adapter.prepare_native(
    cfg,
    context(),
    contracts.Request(..req, operation: "responses/lite"),
  )
  |> should.be_error
  let assert Ok(body) = ir.parse(fixtures.continuation)
  adapter.prepare_native(
    cfg,
    context(),
    contracts.Request(
      ..req,
      model: "gpt-6-astra",
      body: ir.stringify(normalize.put(body, "model", ir.String("gpt-6-astra"))),
    ),
  )
  |> should.be_error
}

pub fn codex_http_never_trusts_client_history_assertions_test() {
  let assert Ok(body) = ir.parse(fixtures.continuation)
  let body =
    body
    |> normalize.put("trusted_history", ir.Boolean(True))
    |> normalize.put("history", ir.Array([]))
  adapter.prepare_native(config(), context(), request(ir.stringify(body)))
  |> should.be_error
  adapter.prepare_native(
    config(),
    context(),
    request(
      "{\"model\":\"gpt-5.5\",\"input\":[],\"previous_response_id\":\"x\",\"previous_response_id\":null}",
    ),
  )
  |> should.be_error
  adapter.prepare_native(
    config(),
    context(),
    request(
      "{\"model\":\"gpt-5.5\",\"input\":[{\"type\":\"item_reference\",\"id\":\"msg_unknown\"}]}",
    ),
  )
  |> should.be_error
}

pub fn codex_http_receipt_expiration_size_and_cancel_policy_test() {
  let identity = session.Identity("synthetic-session", "synthetic-cache")
  let assert Ok(receipt) = session.completed_at(identity, "resp", [], 100)
  let receipt = session.retain_history(receipt, [])
  session.replay_at(receipt, 99) |> should.be_error
  session.replay_at(receipt, 100) |> should.equal(Ok([]))
  session.replay_at(receipt, 100 + session.http_ttl_ms - 1) |> should.be_ok
  session.replay_at(receipt, 100 + session.http_ttl_ms) |> should.be_error
  session.replay_at(session.cancel(receipt), 100) |> should.be_error
  session.replay_at(
    session.retain_history(
      receipt,
      list.repeat(ir.Null, session.http_max_history_items + 1),
    ),
    100,
  )
  |> should.be_error
  session.replay_at(
    session.retain_history(receipt, [
      ir.String(string.repeat("x", session.http_max_history_bytes)),
    ]),
    100,
  )
  |> should.be_error
}

pub fn codex_http_never_replays_websocket_receipt_even_with_history_test() {
  let identity = session.Identity("synthetic-session", "synthetic-cache")
  let assert Ok(receipt) = session.completed_ws(identity, "resp", [], "socket")
  let receipt = session.retain_history(receipt, [])
  session.replay(receipt) |> should.be_error
  session.validate_connection(Some(receipt), Some("socket")) |> should.be_ok
  session.validate_connection(Some(receipt), Some("other-socket"))
  |> should.be_error
}

pub fn codex_http_custom_result_pairing_and_encrypted_history_test() {
  let assert Ok(plan) =
    adapter.prepare_native(config(), context(), request(fixtures.request))
  let assert Ok(call) =
    ir.parse(
      "{\"type\":\"custom_tool_call\",\"call_id\":\"custom\",\"name\":\"exec\",\"input\":\"pwd\"}",
    )
  let assert Ok(reasoning) =
    ir.parse(
      "{\"type\":\"reasoning\",\"encrypted_content\":\"synthetic-opaque\"}",
    )
  let assert Ok(receipt) =
    session.completed(plan.identity, "resp_custom", [
      responses.PendingCall("custom", responses.Custom),
    ])
  let receipt = session.retain_history(receipt, [reasoning, call])
  let cfg = adapter.Config(..config(), continuation: Some(receipt))
  let body =
    "{\"model\":\"gpt-5.5\",\"previous_response_id\":\"resp_custom\",\"input\":[{\"type\":\"custom_tool_call_output\",\"call_id\":\"custom\",\"output\":\"synthetic-result\"}]}"
  let assert Ok(next) = adapter.prepare_native(cfg, context(), request(body))
  ir.field(next.body, "previous_response_id") |> should.equal(None)
  let assert Some(ir.Array([retained, _, _])) = ir.field(next.body, "input")
  retained |> should.equal(reasoning)
  adapter.prepare_native(
    cfg,
    context(),
    request(string.replace(
      body,
      "custom_tool_call_output",
      "function_call_output",
    )),
  )
  |> should.be_error
}
