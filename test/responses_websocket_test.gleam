import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/websocket as ws

// Synthetic WS JSON messages, not evidence of physical WS transport.
fn scope() -> ws.Scope {
  ws.Scope(
    "tenant",
    "provider",
    "credential",
    "account",
    "synthetic",
    "session",
  )
}

fn fresh() -> ws.Session {
  let assert Ok(session) = ws.new(scope(), "server-generation-1")
  session
}

fn first() -> String {
  "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":[]}"
}

fn followup() -> String {
  "{\"type\":\"response.create\",\"model\":\"synthetic\",\"previous_response_id\":\"resp_ws\",\"input\":[]}"
}

fn created() -> String {
  "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}"
}

fn completed() -> ws.Session {
  let assert Ok(#(session, _)) =
    ws.create(fresh(), scope(), "server-generation-1", first())
  let assert Ok(#(session, _)) =
    ws.receive(session, scope(), "server-generation-1", created())
  let assert Ok(#(session, _)) =
    ws.receive(
      session,
      scope(),
      "server-generation-1",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}",
    )
  session
}

pub fn ws_previous_id_requires_same_completed_session_test() {
  ws.create(fresh(), scope(), "server-generation-1", followup())
  |> should.be_error
  let assert Ok(#(_, request)) =
    ws.create(completed(), scope(), "server-generation-1", followup())
  request.previous_response_id |> should.equal(Some("resp_ws"))
  ir.field(request.document, "input") |> should.equal(Some(ir.Array([])))
}

pub fn ws_scope_account_and_generation_cannot_leak_test() {
  let original = scope()
  list.each(
    [
      ws.Scope(..original, tenant: "other"),
      ws.Scope(..original, provider: "other"),
      ws.Scope(..original, credential: "other"),
      ws.Scope(..original, account: "other"),
      ws.Scope(..original, model: "other"),
      ws.Scope(..original, client_session: "other"),
    ],
    fn(scope) {
      ws.create(completed(), scope, "server-generation-1", followup())
      |> should.be_error
    },
  )
  ws.create(completed(), scope(), "server-generation-2", followup())
  |> should.be_error
  ws.new(scope(), "") |> should.be_error
}

pub fn ws_single_active_response_and_cancel_are_explicit_test() {
  let assert Ok(#(active, _)) =
    ws.create(fresh(), scope(), "server-generation-1", first())
  ws.create(active, scope(), "server-generation-1", first()) |> should.be_error
  ws.disconnected(active) |> should.be_error
  let #(closed, cleanup) = ws.cancel(active)
  cleanup |> should.be_true
  ws.cancel(closed).1 |> should.be_false
  ws.create(closed, scope(), "server-generation-1", first()) |> should.be_error
  ws.receive(closed, scope(), "server-generation-1", created())
  |> should.be_error
}

pub fn ws_rejects_unsupported_wire_cancel_append_background_and_nested_create_test() {
  list.each(
    [
      "{\"type\":\"response.cancel\"}",
      "{\"type\":\"response.append\",\"model\":\"synthetic\",\"input\":[]}",
      "{\"type\":\"response.create\",\"response\":{\"model\":\"synthetic\",\"input\":[]}}",
      "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":[],\"background\":true}",
      "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":\"text\"}",
    ],
    fn(source) {
      ws.create(fresh(), scope(), "server-generation-1", source)
      |> should.be_error
    },
  )
}

pub fn ws_encode_preserves_native_extensions_previous_id_without_provider_defaults_test() {
  let assert Ok(request) =
    responses.decode_request(
      "{\"model\":\"synthetic\",\"stream\":true,\"background\":false,\"input\":[],\"previous_response_id\":\"resp_prior\",\"vendor\":{\"opaque\":true}}",
    )
  let assert Ok(encoded) = ws.encode_create(request)
  let assert Ok(document) = ir.parse(encoded)
  ir.field(document, "type") |> should.equal(Some(ir.String("response.create")))
  ir.field(document, "stream") |> should.equal(None)
  ir.field(document, "background") |> should.equal(None)
  ir.field(document, "store") |> should.equal(None)
  ir.field(document, "previous_response_id")
  |> should.equal(Some(ir.String("resp_prior")))
  ir.field(document, "vendor")
  |> should.equal(ir.field(request.document, "vendor"))
}

pub fn ws_incomplete_cannot_grant_continuation_receipt_test() {
  let assert Ok(#(session, _)) =
    ws.create(fresh(), scope(), "server-generation-1", first())
  let assert Ok(#(session, _)) =
    ws.receive(session, scope(), "server-generation-1", created())
  let assert Ok(#(session, _)) =
    ws.receive(
      session,
      scope(),
      "server-generation-1",
      "{\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"incomplete\",\"output\":[]}}",
    )
  ws.create(session, scope(), "server-generation-1", followup())
  |> should.be_error
  ws.create(session, scope(), "server-generation-1", first()) |> should.be_ok
}

pub fn ws_pending_function_results_require_correct_kind_test() {
  let assert Ok(#(session, _)) =
    ws.create(fresh(), scope(), "server-generation-1", first())
  let frames = [
    created(),
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"\"}}",
    "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc\",\"arguments\":\"{}\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}]}}",
  ]
  let session =
    list.fold(frames, session, fn(session, frame) {
      let assert Ok(#(session, _)) =
        ws.receive(session, scope(), "server-generation-1", frame)
      session
    })
  ws.create(session, scope(), "server-generation-1", followup())
  |> should.be_error
  ws.create(
    session,
    scope(),
    "server-generation-1",
    "{\"type\":\"response.create\",\"model\":\"synthetic\",\"previous_response_id\":\"resp_ws\",\"input\":[{\"type\":\"custom_tool_call_output\",\"call_id\":\"c\",\"output\":\"ok\"}]}",
  )
  |> should.be_error
  ws.create(
    session,
    scope(),
    "server-generation-1",
    "{\"type\":\"response.create\",\"model\":\"synthetic\",\"previous_response_id\":\"resp_ws\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":\"ok\"}]}",
  )
  |> should.be_ok
}
