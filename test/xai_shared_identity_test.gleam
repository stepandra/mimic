/// Assembled S6/xAI regression derived from the frozen provider fixture.
/// Real local WS, not a live-provider or gateway-route qualification.
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import mimic/providers/contracts as c
import mimic/providers/xai/endpoint
import mimic/providers/xai_websocket as xai
import xai_websocket_native_test

pub fn ws_argument_identity_is_validated_before_restoration_test() {
  let #(server, origin, _, closed) =
    xai_websocket_native_test.peer(None, "argument_identity")
  let context =
    c.Context(
      "xai",
      "api_key",
      "synthetic-a",
      origin,
      "synthetic-session",
      c.ApiKey("synthetic-only"),
    )
  let config =
    endpoint.Config(
      ..endpoint.defaults(endpoint.ApiKey),
      websockets: True,
      policy: endpoint.LocalMock,
    )
  let adapter = xai.selected_adapter("synthetic-tenant", config, None)
  let body =
    "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"input\":[],"
    <> "\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":"
    <> "[{\"type\":\"function\",\"name\":\"run\"}]},{\"type\":\"namespace\","
    <> "\"name\":\"other\",\"tools\":[{\"type\":\"function\",\"name\":\"run\"}]}]}"
  let request = xai_websocket_native_test.req("api_key", body)
  let assert Ok(opened) = adapter.open(context, request)
  let assert Ok(handle) = adapter.send(opened.handle, request)
  let #(error, handle, delivered) = until_error(adapter, handle, 100, 0)
  error.delivery |> should.equal(c.Started)
  // created, keepalive, added survive. Conflicting argument-done must not.
  delivered |> should.equal(3)
  adapter.cancel(handle)
  process.receive(closed, 1000) |> should.be_ok
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

fn until_error(
  adapter: c.SessionAdapter(xai.Handle),
  handle,
  attempts,
  delivered,
) {
  case adapter.receive(handle), attempts {
    Error(error), _ -> #(error, handle, delivered)
    Ok(#(None, next)), n if n > 0 -> until_error(adapter, next, n - 1, delivered)
    Ok(#(Some(_), next)), n if n > 0 ->
      until_error(adapter, next, n - 1, delivered + 1)
    _, _ -> panic as "synthetic conflicting tool identity was not rejected"
  }
}
