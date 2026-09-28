import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/providers/codex/request
import mimic/providers/codex/routes
import mimic/providers/codex/session

fn scope() {
  session.Scope(
    "synthetic-tenant",
    "credential-1",
    "chatgpt-account-1",
    "gpt-5.5",
    "client-session",
  )
}

fn context() {
  request.Context(
    scope(),
    "synthetic-access",
    "mimic-synthetic-codex-test/1",
    Some("socket-1"),
  )
}

fn route() {
  routes.Route(routes.Responses, routes.Http, False)
}

fn value(body: String) {
  let assert Ok(value) = ir.parse(body)
  value
}

fn prepare(body: String) {
  request.prepare(value(body), context(), route(), None, [
    "low",
    "medium",
    "high",
    "xhigh",
  ])
}

fn pair_tools(items, prior) {
  use request <- result.try(
    responses.request_from_value(
      ir.Object([
        #("model", ir.String("gpt-5.5")),
        #("input", ir.Array(items)),
      ]),
    ),
  )
  responses.pair_input(request, prior)
}

pub fn codex_backend_preparation_not_chat_completions_test() {
  let assert Ok(prepared) =
    prepare(
      "{\"model\":\"gpt-5.5\",\"input\":\"hello\",\"max_output_tokens\":10,\"temperature\":0.3,\"service_tier\":\"fast\",\"prompt_cache_key\":\"attacker-shared\"}",
    )
  prepared.target |> should.equal("/backend-api/codex/responses")
  ir.field(prepared.body, "store") |> should.equal(Some(ir.Boolean(False)))
  ir.field(prepared.body, "stream") |> should.equal(Some(ir.Boolean(True)))
  ir.field(prepared.body, "instructions") |> should.equal(Some(ir.String("")))
  ir.field(prepared.body, "max_output_tokens") |> should.equal(None)
  ir.field(prepared.body, "temperature") |> should.equal(None)
  ir.field(prepared.body, "service_tier")
  |> should.equal(Some(ir.String("priority")))
  ir.field(prepared.body, "prompt_cache_key")
  |> should.equal(Some(ir.String(prepared.identity.cache_id)))
  let assert Ok(account) =
    list.find(prepared.headers, fn(h) { h.name == "Chatgpt-Account-Id" })
  account.value |> should.equal("chatgpt-account-1")
  let assert Ok(hint) =
    list.find(prepared.headers, fn(h) { h.name == "X-Codex-Routing-Hint" })
  hint.value |> should.equal("model=gpt-5.5;tier=priority")
  prepare("{\"model\":\"gpt-5.5\",\"messages\":[]}") |> should.be_error
}

pub fn codex_native_instructions_are_not_fabricated_test() {
  let body = value("{\"model\":\"gpt-5.5\",\"input\":[]}")
  let assert Ok(prepared) =
    request.prepare(
      body,
      context(),
      routes.Route(..route(), native: True),
      None,
      [],
    )
  ir.field(prepared.body, "instructions") |> should.equal(None)
}

pub fn codex_ws_warmup_generate_flag_is_not_http_policy_test() {
  let body =
    value(
      "{\"model\":\"gpt-5.5\",\"input\":[],\"generate\":false,\"user\":\"synthetic-user\"}",
    )
  let assert Ok(ws) =
    request.prepare(
      body,
      context(),
      routes.Route(routes.Responses, routes.Websocket, True),
      None,
      [],
    )
  ir.field(ws.body, "generate") |> should.equal(Some(ir.Boolean(False)))
  ir.field(ws.body, "user") |> should.equal(None)
  let assert Ok(http) = request.prepare(body, context(), route(), None, [])
  ir.field(http.body, "generate") |> should.equal(None)
  prepare(
    "{\"model\":\"gpt-5.5\",\"input\":[],\"context_management\":[{\"type\":\"compaction\"}]}",
  )
  |> should.be_error
}

pub fn codex_compact_is_separate_http_operation_test() {
  let body =
    value("{\"model\":\"gpt-5.5\",\"input\":\"synthetic\",\"stream\":true}")
  let assert Ok(prepared) =
    request.prepare(
      body,
      context(),
      routes.Route(routes.Compact, routes.Http, True),
      None,
      [],
    )
  prepared.target |> should.equal("/backend-api/codex/responses/compact")
  ir.field(prepared.body, "stream") |> should.equal(None)
  request.prepare(
    body,
    context(),
    routes.Route(routes.Compact, routes.Websocket, True),
    None,
    [],
  )
  |> should.be_error
}

pub fn codex_identity_isolated_and_rotation_independent_test() {
  let assert Ok(identity) = session.identity(scope())
  list.each(
    [
      session.Scope(..scope(), tenant: "other"),
      session.Scope(..scope(), credential_id: "other"),
      session.Scope(..scope(), account_id: "other"),
      session.Scope(..scope(), model: "other"),
      session.Scope(..scope(), client_session: "other"),
    ],
    fn(scope) {
      let assert Ok(other) = session.identity(scope)
      { other.session_id != identity.session_id } |> should.be_true
      { other.cache_id != identity.cache_id } |> should.be_true
    },
  )
  { identity.cache_id != identity.session_id } |> should.be_true
  let body = value("{\"model\":\"gpt-5.5\",\"input\":[]}")
  let assert Ok(first) = request.prepare(body, context(), route(), None, [])
  let assert Ok(rotated) =
    request.prepare(
      body,
      request.Context(..context(), access_token: "synthetic-rotated"),
      route(),
      None,
      [],
    )
  first.identity |> should.equal(rotated.identity)
}

pub fn codex_tool_pairing_and_reasoning_survive_test() {
  let assert Ok(prepared) =
    prepare(
      "{\"model\":\"gpt-5.5\",\"input\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"synthetic-opaque\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"synthetic summary\"}]},{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"{ }\"},{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"ok\"}],\"reasoning\":{\"effort\":\"high\",\"summary\":\"auto\"},\"include\":[\"custom.field\"],\"tools\":[{\"type\":\"web_search_preview\"}],\"tool_choice\":{\"type\":\"allowed_tools\",\"tools\":[{\"type\":\"web_search_preview_2025_03_11\"}]}}",
    )
  prepared.pending_calls |> should.equal([])
  let assert Some(ir.Array([reasoning, call, _])) =
    ir.field(prepared.body, "input")
  ir.field(reasoning, "encrypted_content")
  |> should.equal(Some(ir.String("synthetic-opaque")))
  ir.field(reasoning, "summary") |> should.not_equal(None)
  ir.field(call, "arguments") |> should.equal(Some(ir.String("{ }")))
  ir.field(prepared.body, "tools")
  |> should.equal(Some(value("[{\"type\":\"web_search\"}]")))
  ir.field(prepared.body, "include")
  |> should.equal(
    Some(value("[\"custom.field\",\"reasoning.encrypted_content\"]")),
  )
}

pub fn codex_unpaired_duplicate_and_reversed_tools_fail_test() {
  let call =
    value(
      "{\"type\":\"function_call\",\"name\":\"lookup\",\"call_id\":\"call_1\",\"arguments\":\"{}\"}",
    )
  let output =
    value(
      "{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"ok\"}",
    )
  pair_tools([output], []) |> should.be_error
  pair_tools([call, call], []) |> should.be_error
  pair_tools([call, output, output], []) |> should.be_error
  pair_tools([output, call], []) |> should.be_error
  pair_tools([call, output], []) |> should.equal(Ok([]))
}

pub fn codex_tool_output_kind_must_match_across_turns_test() {
  let call =
    value(
      "{\"type\":\"function_call\",\"name\":\"lookup\",\"call_id\":\"call_1\",\"arguments\":\"{}\"}",
    )
  let custom =
    value(
      "{\"type\":\"custom_tool_call\",\"name\":\"lookup\",\"call_id\":\"call_1\",\"input\":\"x\"}",
    )
  let output =
    value(
      "{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"ok\"}",
    )
  let custom_output =
    value(
      "{\"type\":\"custom_tool_call_output\",\"call_id\":\"call_1\",\"output\":\"ok\"}",
    )
  pair_tools([call, custom_output], []) |> should.be_error
  pair_tools([custom, output], []) |> should.be_error
  pair_tools([custom, custom_output], []) |> should.equal(Ok([]))
  let assert Ok(pending) = pair_tools([custom], [])
  pair_tools([output], pending) |> should.be_error
  pair_tools([custom_output], pending) |> should.equal(Ok([]))
}

pub fn codex_ws_continuation_binds_connection_generation_and_transport_test() {
  let assert Ok(identity) = session.identity(scope())
  let pending = [responses.PendingCall("call_1", responses.Function)]
  let assert Ok(http_receipt) = session.completed(identity, "resp_1", pending)
  let assert Ok(ws_receipt) =
    session.completed_ws(identity, "resp_1", pending, "socket-1")
  let body =
    value(
      "{\"model\":\"gpt-5.5\",\"previous_response_id\":\"resp_1\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"ok\"}]}",
    )
  let ws = routes.Route(routes.Responses, routes.Websocket, True)
  request.prepare(body, context(), ws, Some(http_receipt), [])
  |> should.be_error
  request.prepare(
    body,
    request.Context(..context(), connection_generation: Some("socket-replaced")),
    ws,
    Some(ws_receipt),
    [],
  )
  |> should.be_error
  request.prepare(body, context(), ws, Some(ws_receipt), []) |> should.be_ok
}

pub fn codex_http_vs_websocket_continuation_and_cancellation_test() {
  let assert Ok(identity) = session.identity(scope())
  let assert Ok(receipt) =
    session.completed_ws(
      identity,
      "resp_1",
      [
        responses.PendingCall("call_1", responses.Function),
      ],
      "socket-1",
    )
  let body =
    value(
      "{\"model\":\"gpt-5.5\",\"previous_response_id\":\"resp_1\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"ok\"}]}",
    )
  let ws = routes.Route(routes.Responses, routes.Websocket, True)
  let assert Ok(prepared) =
    request.prepare(body, context(), ws, Some(receipt), [])
  ir.field(prepared.body, "previous_response_id")
  |> should.equal(Some(ir.String("resp_1")))
  // Incremental-only input must never be silently converted to standalone HTTP.
  request.prepare(body, context(), route(), Some(receipt), [])
  |> should.be_error
  request.prepare(body, context(), ws, None, []) |> should.be_error
  request.prepare(body, context(), ws, Some(session.cancel(receipt)), [])
  |> should.be_error
  let other =
    request.Context(
      ..context(),
      scope: session.Scope(..scope(), credential_id: "failover-account"),
    )
  request.prepare(body, other, ws, Some(receipt), []) |> should.be_error
  let call =
    value(
      "{\"type\":\"function_call\",\"name\":\"lookup\",\"call_id\":\"call_1\",\"arguments\":\"{}\"}",
    )
  let retained = session.retain_history(receipt, [call])
  let assert Ok(http) =
    request.prepare(body, context(), route(), Some(retained), [])
  ir.field(http.body, "previous_response_id") |> should.equal(None)
  let assert Some(ir.Array(items)) = ir.field(http.body, "input")
  list.length(items) |> should.equal(2)
}

pub fn codex_standalone_ws_does_not_inherit_previous_id_test() {
  let assert Ok(identity) = session.identity(scope())
  let assert Ok(receipt) =
    session.completed(identity, "resp_old", [
      responses.PendingCall("call_old", responses.Function),
    ])
  let assert Ok(prepared) =
    request.prepare(
      value("{\"model\":\"gpt-5.5\",\"input\":\"new conversation\"}"),
      context(),
      routes.Route(routes.Responses, routes.Websocket, True),
      Some(receipt),
      [],
    )
  ir.field(prepared.body, "previous_response_id") |> should.equal(None)
  prepared.pending_calls |> should.equal([])
}

pub fn codex_native_route_intent_test() {
  routes.resolve("POST", "/backend-api/codex/responses", False, False)
  |> should.equal(Ok(routes.Route(routes.Responses, routes.Http, True)))
  routes.resolve("GET", "/v1/responses", True, True)
  |> should.equal(Ok(routes.Route(routes.Responses, routes.Websocket, True)))
  routes.resolve("POST", "/responses/compact", False, False)
  |> should.equal(Ok(routes.Route(routes.Compact, routes.Http, False)))
  routes.resolve("GET", "/backend-api/codex/models", False, False)
  |> should.equal(Ok(routes.Route(routes.Models, routes.Http, True)))
  routes.resolve("POST", "/v1/chat/completions", False, True) |> should.be_error
  routes.resolve("GET", "/responses", False, True) |> should.be_error
  routes.resolve("GET", "/responses/compact", True, True) |> should.be_error
}

pub fn codex_reasoning_model_and_header_validation_test() {
  prepare(
    "{\"model\":\"gpt-5.5\",\"input\":[],\"reasoning\":{\"effort\":\"ultra\"}}",
  )
  |> should.be_error
  prepare("{\"model\":\"gpt-other\",\"input\":[]}") |> should.be_error
  prepare("{\"model\":\"gpt-5.5\",\"input\":[],\"service_tier\":\"unknown\"}")
  |> should.be_error
  request.prepare(
    value("{\"model\":\"gpt-5.5\",\"input\":[]}"),
    request.Context(..context(), access_token: "synthetic\r\nHeader: invalid"),
    route(),
    None,
    [],
  )
  |> should.be_error
}
