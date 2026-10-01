/// Synthetic binding/registration policy, not account entitlement or CPA proof.
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/xai/endpoint
import mimic/providers/xai/operations
import mimic/providers/xai_websocket

fn request(mode: String) {
  c.Request(
    "xai",
    mode,
    "grok-4.7",
    "responses",
    "responses/websocket",
    c.Streaming,
    [c.WebSocket],
    "synthetic-session",
    Some("synthetic-account"),
    "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"input\":[]}",
  )
}

fn context(mode: String, origin: String) {
  c.Context(
    "xai",
    mode,
    "synthetic-account",
    origin,
    "synthetic-opaque",
    c.ApiKey("synthetic-key"),
  )
}

pub fn ws_binding_is_exact_and_does_not_infer_http_operations_test() {
  list.each(["api_key", "oauth"], fn(mode) {
    let assert Ok(binding) =
      operations.new(
        "synthetic-account",
        mode,
        "responses",
        "responses/websocket",
        "https://api.x.ai/v1",
        True,
      )
    let assert Ok(row) =
      operations.registration("synthetic-account", mode, [binding], "grok-4.7")
    row.operations |> should.equal(["responses/websocket"])
    row.capabilities
    |> should.equal([c.Stream, c.Tools, c.WebSocket, c.Continuation])
    let assert Ok(config) =
      operations.select(
        [binding],
        context(mode, "https://api.x.ai"),
        request(mode),
      )
    let assert Ok(plan) = endpoint.select(config, endpoint.WebSocket)
    plan.url |> should.equal("wss://api.x.ai/v1/responses")
    plan.proxy_identity |> should.equal(False)
    let assert Ok(headers) = endpoint.headers(plan, "synthetic-conversation")
    list.any(headers, fn(h) { h.name == "X-XAI-Token-Auth" })
    |> should.equal(False)
    let assert [bound] = operations.runtime_bindings([binding])
    bound.operation |> should.equal("responses/websocket")
    bound.origin |> should.equal("https://api.x.ai")
  })
}

pub fn explicit_http_rows_remain_http_only_test() {
  list.each(["responses", "responses/compact"], fn(operation) {
    let assert Ok(binding) =
      operations.new(
        "synthetic-account",
        "api_key",
        "responses",
        operation,
        "http://127.0.0.1:12345/v1",
        True,
      )
    let assert Ok(row) =
      operations.registration(
        "synthetic-account",
        "api_key",
        [binding],
        "grok-4.7",
      )
    row.operations |> should.equal([operation])
    list.contains(row.capabilities, c.WebSocket) |> should.equal(False)
    operations.select(
      [binding],
      context("api_key", "http://127.0.0.1:12345"),
      request("api_key"),
    )
    |> should.be_error
  })
  let assert Ok(legacy) =
    operations.registration("synthetic-account", "api_key", [], "grok-4.7")
  list.contains(legacy.operations, "responses/websocket") |> should.equal(False)
}

pub fn proxy_build_composer_and_implicit_ws_fail_closed_test() {
  list.each(
    [
      "https://api.x.ai/v1",
      "https://cli-chat-proxy.grok.com/v1",
      "http://127.0.0.1:12345/v1",
    ],
    fn(base) {
      operations.new(
        "synthetic-account",
        "oauth",
        "responses",
        "responses/websocket",
        base,
        False,
      )
      |> should.be_error
    },
  )
  operations.new(
    "synthetic-account",
    "api_key",
    "responses",
    "responses/websocket",
    "https://cli-chat-proxy.grok.com/v1",
    True,
  )
  |> should.be_error
  let assert Ok(binding) =
    operations.new(
      "synthetic-account",
      "oauth",
      "responses",
      "responses/websocket",
      "https://api.x.ai/v1",
      True,
    )
  list.each(
    ["grok-build-0.1", "grok-4.7-build-fast", "grok-composer-2.5-fast"],
    fn(model) {
      operations.registration("synthetic-account", "oauth", [binding], model)
      |> should.be_error
    },
  )
}

pub fn canonical_base_and_unique_operation_are_required_test() {
  list.each(
    [
      "wss://api.x.ai/v1",
      "http://example.invalid/v1",
      "https://API.X.AI/v1",
      "https://api.x.ai/v1/",
      "https://user@api.x.ai/v1",
      "https://api.x.ai/v1?synthetic=true",
      "https://api.x.ai/v1#synthetic",
      "https://api.x.ai/not-v1",
    ],
    fn(base) {
      operations.new(
        "synthetic-account",
        "api_key",
        "responses",
        "responses/websocket",
        base,
        True,
      )
      |> should.be_error
    },
  )
  let assert Ok(binding) =
    operations.new(
      "synthetic-account",
      "api_key",
      "responses",
      "responses/websocket",
      "https://api.x.ai/v1",
      True,
    )
  operations.validate_account("synthetic-account", "api_key", [binding, binding])
  |> should.be_error
  let assert Ok(raw) =
    ir.parse(
      "[{\"protocol\":\"responses\",\"operation\":\"responses/websocket\",\"base\":\"https://api.x.ai/v1\",\"using_api\":true}]",
    )
  operations.decode("synthetic-account", "api_key", raw) |> should.be_ok
}

pub fn actual_selected_binding_cannot_switch_account_origin_auth_or_operation_test() {
  let assert Ok(binding) =
    operations.new(
      "synthetic-account",
      "api_key",
      "responses",
      "responses/websocket",
      "https://api.x.ai/v1",
      True,
    )
  let selected = context("api_key", "https://api.x.ai")
  list.each(
    [
      c.Context(..selected, account: "other"),
      c.Context(..selected, provider: "codex"),
      c.Context(..selected, origin: "https://other.invalid"),
      c.Context(..selected, auth_mode: "oauth"),
    ],
    fn(ctx) {
      operations.select([binding], ctx, request("api_key")) |> should.be_error
    },
  )
  list.each(
    [
      c.Request(..request("api_key"), operation: "responses"),
      c.Request(..request("api_key"), pinned_account: Some("other")),
      c.Request(..request("api_key"), protocol: "chat"),
    ],
    fn(req) { operations.select([binding], selected, req) |> should.be_error },
  )
}

pub fn selected_library_adapter_does_not_replace_explicit_ws_base_test() {
  let config =
    endpoint.Config(
      ..endpoint.defaults(endpoint.ApiKey),
      websockets: True,
      websocket_base: Some("http://127.0.0.1:1/v1"),
      policy: endpoint.LocalMock,
    )
  xai_websocket.selected_adapter("synthetic-tenant", config, None).open(
    context("api_key", "http://127.0.0.1:2"),
    request("api_key"),
  )
  |> should.be_error
}

pub fn selected_adapter_missing_base_is_not_masked_by_tls_policy_test() {
  let config =
    endpoint.Config(..endpoint.defaults(endpoint.ApiKey), websockets: True)
  // Deliberately incompatible synthetic material makes this test incapable of
  // connecting to a public endpoint if the explicit-base guard regresses.
  // The exact Unsupported result must come from destination admission first,
  // not LocalMock's unrelated HTTPS rejection or credential extraction.
  let selected =
    c.Context(
      ..context("api_key", "https://api.x.ai"),
      credential: c.SessionToken("synthetic-not-an-api-key", []),
    )
  xai_websocket.selected_adapter("synthetic-tenant", config, None).open(
    selected,
    request("api_key"),
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
}
