/// Synthetic-only input enforcement. No HTTP continuation receipt is created,
/// no provider/OAuth endpoint is contacted, and no WS support is qualified.
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/dialect/responses
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/runtime
import mimic/providers/xai/adapter
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/providers/xai/http_continuation
import mimic/providers/xai/request as xai_request
import mimic/providers/xai/tools

const origin = "http://127.0.0.1:9"

fn config(mode) {
  endpoint.Config(
    mode,
    mode == endpoint.ApiKey,
    False,
    Some(origin <> "/v1"),
    Some(origin <> "/v1"),
    None,
    endpoint.LocalMock,
  )
}

fn context(mode) {
  let #(name, material) = case mode {
    endpoint.ApiKey -> #("api_key", c.ApiKey("synthetic-f17-key"))
    endpoint.DeviceOAuth -> #(
      "oauth",
      c.OAuth(
        c.OAuthData(
          auth.Credential("synthetic-f17-access", "synthetic-f17-refresh", 0),
          [],
        ),
      ),
    )
  }
  c.Context(
    "xai",
    name,
    "synthetic-f17-account",
    origin,
    "authenticated-tenant:synthetic-session",
    material,
  )
}

fn document(streaming) {
  ir.Object([
    #("model", ir.String("grok-4.7")),
    #("input", ir.String("synthetic input")),
    #("stream", ir.Boolean(streaming)),
  ])
}

fn request(mode, operation, body) {
  let streaming = ir.field(body, "stream") == Some(ir.Boolean(True))
  c.Request(
    "xai",
    case mode {
      endpoint.ApiKey -> "api_key"
      endpoint.DeviceOAuth -> "oauth"
    },
    "grok-4.7",
    "responses",
    operation,
    case streaming {
      True -> c.Streaming
      False -> c.Buffered
    },
    [],
    "authenticated-tenant:synthetic-session",
    None,
    ir.stringify(body),
  )
}

fn unsupported() {
  c.Failure(c.Unsupported, c.NotSent, None)
}

fn with_previous(body, previous) {
  tools.set(body, "previous_response_id", previous)
}

fn deny(mode, operation, body) {
  let req = request(mode, operation, body)
  http_continuation.guard(req.body) |> should.equal(Error(unsupported()))
  bridge.prepare_plan(config(mode), context(mode), req)
  |> should.equal(Error(unsupported()))
  // Calling all actual HTTP adapter factories must stop at admission, not at
  // a refused connection to the synthetic origin. No network is needed.
  list.each(
    [
      adapter.http(config(mode), None),
      adapter.selected_http(config(mode), None),
      adapter.configured_http(fn(_, _) { Ok(config(mode)) }, None),
    ],
    fn(http) {
      http.open(context(mode), req) |> should.equal(Error(unsupported()))
    },
  )
  runtime.retryable(unsupported()) |> should.be_false
}

pub fn every_top_level_previous_value_is_explicitly_unsupported_test() {
  list.each(
    [
      ir.Null,
      ir.String(""),
      ir.String("resp_synthetic_prior"),
      ir.Integer(1),
      ir.Boolean(False),
      ir.Array([]),
      ir.Object([]),
    ],
    fn(previous) {
      list.each([endpoint.ApiKey, endpoint.DeviceOAuth], fn(mode) {
        list.each([False, True], fn(streaming) {
          deny(mode, "responses", with_previous(document(streaming), previous))
        })
        deny(
          mode,
          "responses/compact",
          with_previous(document(False), previous),
        )
      })
    },
  )
}

pub fn public_http_transform_cannot_discard_or_preserve_untrusted_ids_test() {
  let body = with_previous(document(False), ir.String("resp_synthetic_prior"))
  list.each(
    [endpoint.Chat, endpoint.Responses, endpoint.Compact],
    fn(operation) {
      xai_request.prepare(config(endpoint.ApiKey), operation, body, "")
      |> should.equal(Error("xAI HTTP previous_response_id is unsupported"))
    },
  )
}

pub fn stateless_http_and_compact_positive_controls_keep_their_operations_test() {
  list.each([endpoint.ApiKey, endpoint.DeviceOAuth], fn(mode) {
    list.each([False, True], fn(streaming) {
      let body = document(streaming)
      http_continuation.guard(ir.stringify(body)) |> should.equal(Ok(Nil))
      let assert Ok(plan) =
        bridge.prepare_plan(
          config(mode),
          context(mode),
          request(mode, "responses", body),
        )
      plan.capture.target |> should.equal("/v1/responses")
      let assert Ok(wire) = ir.parse(plan.capture.body)
      ir.field(wire, "stream") |> should.equal(Some(ir.Boolean(True)))
      ir.field(wire, "previous_response_id") |> should.equal(None)
    })
    let body = document(False)
    let assert Ok(plan) =
      bridge.prepare_plan(
        config(mode),
        context(mode),
        request(mode, "responses/compact", body),
      )
    plan.capture.target |> should.equal("/v1/responses/compact")
    let assert Ok(wire) = ir.parse(plan.capture.body)
    ir.field(wire, "stream") |> should.equal(None)
    ir.field(wire, "previous_response_id") |> should.equal(None)
  })
}

fn history() {
  document(False)
  |> tools.set(
    "input",
    ir.Array([
      ir.Object([
        #("type", ir.String("function_call")),
        #("id", ir.String("item_synthetic_history")),
        #("call_id", ir.String("call_synthetic_history")),
        #("name", ir.String("lookup")),
        #("arguments", ir.String("{\"previous_response_id\":\"user-data\"}")),
      ]),
      ir.Object([
        #("type", ir.String("function_call_output")),
        #("call_id", ir.String("call_synthetic_history")),
        #("output", ir.String("synthetic result")),
      ]),
    ]),
  )
  |> tools.set(
    "tools",
    ir.Array([
      ir.Object([
        #("type", ir.String("function")),
        #("name", ir.String("lookup")),
        #("parameters", ir.Object([])),
      ]),
    ]),
  )
}

pub fn full_paired_history_is_stateless_input_not_previous_id_authority_test() {
  let body = history()
  let assert Ok(decoded) = responses.decode_request(ir.stringify(body))
  responses.pair_input(decoded, []) |> should.be_ok
  list.each([endpoint.ApiKey, endpoint.DeviceOAuth], fn(mode) {
    http_continuation.guard(ir.stringify(body)) |> should.equal(Ok(Nil))
    let assert Ok(plan) =
      bridge.prepare_plan(
        config(mode),
        context(mode),
        request(mode, "responses", body),
      )
    let assert Ok(wire) = ir.parse(plan.capture.body)
    ir.field(wire, "input") |> should.equal(ir.field(decoded.document, "input"))
    deny(mode, "responses", with_previous(body, ir.String("resp_synthetic")))
  })
}

pub fn nested_user_content_and_extension_keys_are_not_state_instructions_test() {
  let body =
    document(False)
    |> tools.set(
      "input",
      ir.Array([
        ir.Object([
          #("role", ir.String("user")),
          #(
            "content",
            ir.Array([
              ir.Object([
                #("type", ir.String("input_text")),
                #("text", ir.String("{\"previous_response_id\":null}")),
              ]),
            ]),
          ),
        ]),
      ]),
    )
    |> tools.set(
      "vendor_extension",
      ir.Object([#("previous_response_id", ir.String("synthetic-user-data"))]),
    )
  http_continuation.guard(ir.stringify(body)) |> should.equal(Ok(Nil))
  let assert Ok(prepared) =
    xai_request.prepare(config(endpoint.ApiKey), endpoint.Responses, body, "")
  ir.field(prepared.body, "vendor_extension")
  |> should.equal(ir.field(body, "vendor_extension"))
  ir.field(prepared.body, "input") |> should.equal(ir.field(body, "input"))
}

pub fn websocket_transform_retains_its_separate_state_boundary_test() {
  let body =
    document(False)
    |> with_previous(ir.String("resp_synthetic_ws"))
    |> tools.set("instructions", ir.String("synthetic instructions"))
  let assert Ok(prepared) =
    xai_request.prepare(config(endpoint.ApiKey), endpoint.WebSocket, body, "")
  ir.field(prepared.body, "previous_response_id")
  |> should.equal(Some(ir.String("resp_synthetic_ws")))
  ir.field(prepared.body, "type")
  |> should.equal(Some(ir.String("response.create")))
  ir.field(prepared.body, "instructions") |> should.equal(None)
  deny(endpoint.ApiKey, "responses", body)
}

pub fn client_scope_claims_and_id_provenance_cannot_authorize_http_test() {
  list.each(
    [
      "resp_synthetic_first_turn",
      "resp_synthetic_ws_receipt",
      "compact_synthetic_id",
      "resp_synthetic_unknown",
    ],
    fn(id) {
      let body =
        document(False)
        |> with_previous(ir.String(id))
        |> tools.set(
          "continuation",
          ir.Object([
            #("tenant", ir.String("synthetic-tenant-claim")),
            #("account", ir.String("synthetic-account-claim")),
            #("revision", ir.String("synthetic-revision-claim")),
            #("origin", ir.String("http://127.0.0.1:9")),
            #("history", ir.Array([])),
          ]),
        )
      deny(endpoint.ApiKey, "responses", body)
    },
  )
}

pub fn escaped_single_key_is_presence_and_duplicate_keys_are_invalid_test() {
  http_continuation.guard(
    "{\"model\":\"grok-4.7\",\"input\":\"synthetic\",\"\\u0070revious_response_id\":null}",
  )
  |> should.equal(Error(unsupported()))
  list.each(
    [
      "{\"previous_response_id\":\"resp_a\",\"previous_response_id\":\"resp_b\"}",
      "{\"previous_response_id\":\"resp_a\",\"\\u0070revious_response_id\":\"resp_b\"}",
      "[{\"previous_response_id\":\"resp_a\"}]",
      "{\"previous_response_id\":",
    ],
    fn(body) {
      http_continuation.guard(body)
      |> should.equal(Error(c.Failure(c.InvalidConfiguration, c.NotSent, None)))
    },
  )
}

pub fn orphan_output_is_not_implicit_history_replay_test() {
  let body =
    document(False)
    |> tools.set(
      "input",
      ir.Array([
        ir.Object([
          #("type", ir.String("function_call_output")),
          #("call_id", ir.String("call_synthetic_unknown")),
          #("output", ir.String("synthetic result")),
        ]),
      ]),
    )
  http_continuation.guard(ir.stringify(body)) |> should.equal(Ok(Nil))
  bridge.prepare_plan(
    config(endpoint.ApiKey),
    context(endpoint.ApiKey),
    request(endpoint.ApiKey, "responses", body),
  )
  |> should.equal(Error(c.Failure(c.InvalidConfiguration, c.NotSent, None)))
  deny(
    endpoint.ApiKey,
    "responses",
    with_previous(body, ir.String("resp_synthetic")),
  )
}

pub fn required_continuation_or_ws_cannot_downgrade_to_http_test() {
  let req = request(endpoint.ApiKey, "responses", document(False))
  list.each([c.Continuation, c.WebSocket], fn(capability) {
    bridge.prepare_plan(
      config(endpoint.ApiKey),
      context(endpoint.ApiKey),
      c.Request(..req, required: [capability]),
    )
    |> should.equal(Error(unsupported()))
  })
}
