/// Synthetic cases derived from pinned CPA source, not live captures.
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/codex/adapter
import mimic/providers/codex/lite
import mimic/providers/codex/local
import mimic/providers/codex/models
import mimic/providers/codex/normalize
import mimic/providers/codex/request
import mimic/providers/codex/routes
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/types.{Header}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

pub fn codex_lite_real_loopback_runtime_two_turns_test() {
  local.run_lite(directory()) |> should.be_ok
}

fn body() {
  let assert Ok(body) =
    ir.parse(
      "{\"model\":\"gpt-6-astra\",\"input\":[{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"custom\",\"name\":\"exec\"}]}]},{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"https://example.invalid/synthetic.png\"}]}],\"parallel_tool_calls\":true,\"client_metadata\":{\"ws_request_header_x_openai_internal_codex_responses_lite\":\"true\"}}",
    )
  body
}

fn prepare(body, operation) {
  request.prepare(
    body,
    request.Context(
      session.Scope("tenant", "credential", "account", "gpt-6-astra", "client"),
      "synthetic-token",
      "synthetic-test/1",
      None,
    ),
    routes.Route(operation, routes.Http, False),
    None,
    ["medium"],
  )
}

pub fn codex_lite_uses_responses_route_and_native_tool_declarations_test() {
  let assert Ok(plan) = prepare(body(), routes.Responses)
  plan.target |> should.equal("/backend-api/codex/responses")
  ir.field(plan.body, "parallel_tool_calls")
  |> should.equal(Some(ir.Boolean(False)))
  ir.field(plan.body, "input") |> should.equal(ir.field(body(), "input"))
  ir.field(plan.body, "tools") |> should.equal(None)
  ir.field(plan.body, "instructions") |> should.equal(None)
  ir.field(plan.body, "include")
  |> should.equal(Some(ir.Array([ir.String("reasoning.encrypted_content")])))
  list.contains(
    plan.headers,
    Header("X-OpenAI-Internal-Codex-Responses-Lite", "true"),
  )
  |> should.be_true
  list.contains(plan.headers, Header("Accept", "text/event-stream"))
  |> should.be_true
}

pub fn codex_lite_marker_not_model_name_selects_request_mode_test() {
  let plain = normalize.remove(body(), ["client_metadata", "input"])
  let plain = normalize.put(plain, "input", ir.String("synthetic"))
  let assert Ok(normal) = prepare(plain, routes.Responses)
  list.any(normal.headers, fn(h) {
    h.name == "X-OpenAI-Internal-Codex-Responses-Lite"
  })
  |> should.be_false
  let assert Ok(lite_plan) = prepare(plain, routes.Lite)
  ir.field(lite_plan.body, "parallel_tool_calls")
  |> should.equal(Some(ir.Boolean(False)))
  prepare(body(), routes.Compact) |> should.be_error
  let assert Ok(compact) = prepare(plain, routes.Compact)
  compact.target |> should.equal("/backend-api/codex/responses/compact")
  ir.field(compact.body, "stream") |> should.equal(None)
}

pub fn codex_lite_gateway_header_hook_rejects_ambiguity_test() {
  let header = Header("X-OpenAI-Internal-Codex-Responses-Lite", " TRUE ")
  list.each(
    ["/responses", "/v1/responses", "/backend-api/codex/responses"],
    fn(path) {
      routes.resolve_http("POST", path, False, [header])
      |> should.equal(Ok(routes.Route(routes.Lite, routes.Http, True)))
    },
  )
  routes.resolve_http("POST", "/responses/compact", True, [header])
  |> should.be_error
  routes.resolve_http("POST", "/responses/lite", True, [])
  |> should.be_error
  lite.header_enabled([header, header]) |> should.be_error
  lite.header_enabled([Header(lite.header, "yes")]) |> should.be_error
  lite.header_enabled([Header(lite.header, "false")]) |> should.equal(Ok(False))
  lite.header_enabled([]) |> should.equal(Ok(False))
}

pub fn codex_native_thread_hints_are_not_cache_affinity_or_authority_test() {
  let headers = [
    Header("thread-id", "synthetic-thread"),
    Header("x-client-request-id", "synthetic-thread"),
    Header("session-id", "synthetic-shared-affinity"),
  ]
  routes.client_session_hint(headers)
  |> should.equal(Ok(Some("synthetic-thread")))
  routes.client_session_hint([Header("session-id", "shared")])
  |> should.equal(Ok(None))
  routes.client_session_hint([
    Header("thread-id", "one"),
    Header("x-client-request-id", "two"),
  ])
  |> should.be_error
  routes.client_session_hint([
    Header("thread-id", "one"),
    Header("Thread-Id", "one"),
  ])
  |> should.be_error
  routes.client_session_hint([Header("thread-id", "")]) |> should.be_error
}

pub fn codex_lite_metadata_values_match_explicit_source_markers_test() {
  list.each([ir.Boolean(True), ir.String(" TRUE ")], fn(marker) {
    lite.enabled(normalize.put(
      body(),
      "client_metadata",
      ir.Object([#(lite.metadata_key, marker)]),
    ))
    |> should.equal(Ok(True))
  })
  lite.enabled(normalize.put(
    body(),
    "client_metadata",
    ir.Object([#(lite.metadata_key, ir.Integer(1))]),
  ))
  |> should.be_error
}

pub fn codex_lite_rejects_malformed_declarations_and_image_generation_test() {
  let assert Ok(bad) =
    ir.parse(
      "[{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[{\"type\":\"custom\"}]}]",
    )
  prepare(normalize.put(body(), "input", bad), routes.Lite) |> should.be_error
  let assert Ok(tools) = ir.parse("[{\"type\":\"image_generation\"}]")
  prepare(normalize.put(body(), "tools", tools), routes.Lite) |> should.be_error
  lite.validate_modalities(body(), ["text", "image"]) |> should.be_ok
  lite.validate_modalities(body(), ["text"]) |> should.be_error
  let assert Ok(audio) =
    ir.parse(
      "{\"input\":[{\"content\":[{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"synthetic\",\"format\":\"wav\"}}]}]}",
    )
  lite.validate_modalities(audio, ["text", "image"]) |> should.be_error
}

pub fn codex_lite_catalog_registration_keeps_exact_source_flags_test() {
  let assert Ok(model) = models.lookup(models.pinned(), "gpt-6-astra")
  let assert Ok(registration) = adapter.registration(model)
  list.contains(registration.operations, "responses/lite") |> should.be_true
  list.contains(registration.capabilities, contracts.Images) |> should.be_true
  model.responses_lite |> should.be_true
  // Catalog says the model can parallelize; lite request mode still forces false.
  model.parallel_tools |> should.be_true
}
