/// Synthetic complete-message composition only; no RFC6455 transport claim.
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket
import mimic/providers/codex/fixtures
import mimic/providers/codex/request
import mimic/providers/codex/routes
import mimic/providers/codex/session

fn scope() {
  websocket.Scope(
    "tenant",
    "codex",
    "credential",
    "account",
    "gpt-5.5",
    "session",
  )
}

fn context() {
  request.Context(
    session.Scope("tenant", "credential", "account", "gpt-5.5", "session"),
    "synthetic-token",
    "synthetic-test/1",
    Some("connection-1"),
  )
}

fn completed_session() {
  let assert Ok(initial) = websocket.new(scope(), "connection-1")
  let assert Ok(created) =
    websocket.create(
      initial,
      scope(),
      "connection-1",
      "{\"type\":\"response.create\",\"model\":\"gpt-5.5\",\"input\":[],\"generate\":true}",
    )
  let assert Ok(prepared) =
    request.prepare(
      created.1.document,
      context(),
      routes.Route(routes.Responses, routes.Websocket, True),
      None,
      ["high"],
    )
  let assert Ok(document) = responses.request_from_value(prepared.body)
  let assert Ok(wire) = websocket.encode_create(document)
  let assert Ok(wire) = ir.parse(wire)
  ir.field(wire, "generate") |> should.equal(Some(ir.Boolean(True)))
  ir.field(wire, "stream") |> should.equal(None)
  ir.field(wire, "type") |> should.equal(Some(ir.String("response.create")))

  // Use the common codec for fixture framing too; do not split SSE by hand.
  let assert Ok(events) =
    stream.feed(stream.new(), bit_array.from_string(fixtures.sse()))
  let completed =
    list.fold(events.1, #(created.0, None), fn(acc, event) {
      let assert Ok(received) =
        websocket.receive(
          acc.0,
          scope(),
          "connection-1",
          ir.stringify(event.document),
        )
      #(received.0, Some(received.1))
    })
  let assert Some(terminal) = completed.1
  let assert Ok(response) = stream.terminal_response(terminal)
  let assert Ok(pending) = responses.output_calls(response)
  let assert Ok(receipt) =
    session.completed_ws(
      prepared.identity,
      response.id,
      pending,
      "connection-1",
    )
  #(completed.0, receipt)
}

pub fn codex_shared_ws_create_preserves_incremental_continuation_test() {
  let #(connection, receipt) = completed_session()
  let assert Ok(body) = ir.parse(fixtures.continuation)
  let framed =
    ir.Object([#("type", ir.String("response.create")), ..ir.extras(body, [])])
  let assert Ok(next) =
    websocket.create(connection, scope(), "connection-1", ir.stringify(framed))
  let assert Ok(prepared) =
    request.prepare(
      next.1.document,
      context(),
      routes.Route(routes.Responses, routes.Websocket, True),
      Some(receipt),
      ["high"],
    )
  let assert Ok(document) = responses.request_from_value(prepared.body)
  let assert Ok(encoded) = websocket.encode_create(document)
  let assert Ok(encoded) = ir.parse(encoded)
  ir.field(encoded, "previous_response_id")
  |> should.equal(Some(ir.String("resp_synthetic")))
  let assert Some(ir.Array(input)) = ir.field(encoded, "input")
  list.length(input) |> should.equal(1)
  // No full history: the same provider receipt is not sufficient for HTTP.
  request.prepare(
    next.1.document,
    context(),
    routes.Route(routes.Responses, routes.Http, True),
    Some(receipt),
    ["high"],
  )
  |> should.be_error
}

pub fn codex_shared_ws_scope_connection_and_cancellation_test() {
  let #(connection, _) = completed_session()
  let message =
    "{\"type\":\"response.create\",\"model\":\"gpt-5.5\",\"input\":[]}"
  websocket.create(
    connection,
    websocket.Scope(..scope(), account: "other"),
    "connection-1",
    message,
  )
  |> should.be_error
  websocket.create(connection, scope(), "connection-replaced", message)
  |> should.be_error
  let cancelled = websocket.cancel(connection)
  cancelled.1 |> should.be_true
  websocket.cancel(cancelled.0).1 |> should.be_false
  websocket.create(cancelled.0, scope(), "connection-1", message)
  |> should.be_error
}
