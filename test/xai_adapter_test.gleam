/// Synthetic loopback bytes through runtime v4 and Responses v2. No live xAI.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/dialect/responses
import mimic/fleet
import mimic/protocol/responses/http as responses_http
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/xai/adapter
import mimic/providers/xai/endpoint
import mimic/providers/xai/models
import mist

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn state_directory() -> String

fn created() {
  "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_xai\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
}

fn terminal() {
  "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_xai\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"total_tokens\":5}}}\n\n"
}

fn setup(body: String) {
  let started = process.new_subject()
  let received = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    process.send(received, #(
      req.path,
      request.get_header(req, "authorization"),
      request.get_header(req, "host"),
    ))
    response.new(200)
    |> response.set_header("content-type", "text/event-stream; charset=utf-8")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
    |> mist.read_request_body(
      bytes_limit: 4096,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(started, 5000)
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(store) = storage.new(state_directory())
  let key = credentials.key("xai", "api_key", "synthetic-a")
  credentials.save_api_key(store, key, "synthetic-key") |> should.be_ok
  let assert Ok(model) = models.registration("grok-4.7")
  let assert Ok(catalog) = registry.new([model])
  let assert Ok(pool) =
    runtime.start(store, catalog, [
      runtime.Account(
        "xai",
        "api_key",
        "synthetic-a",
        origin,
        fleet.LocalLoopback,
        1,
        ["grok-4.7"],
        credentials.StaticKey,
      ),
    ])
  let config =
    endpoint.Config(
      endpoint.ApiKey,
      True,
      False,
      Some(origin <> "/v1"),
      None,
      None,
      endpoint.LocalMock,
    )
  #(pool, adapter.http(config, None), server, received, origin)
}

fn request(mode: contracts.Mode) {
  let streaming = case mode {
    contracts.Buffered -> "false"
    contracts.Streaming -> "true"
  }
  contracts.Request(
    "xai",
    "api_key",
    "grok-4.7",
    "responses",
    "responses",
    mode,
    [],
    "synthetic-session",
    None,
    "{\"model\":\"grok-4.7\",\"input\":\"synthetic prompt\",\"stream\":"
      <> streaming
      <> "}",
  )
}

pub fn buffered_sse_collects_terminal_json_usage_and_runtime_credential_test() {
  let #(pool, http_adapter, server, received, _) =
    setup(created() <> terminal() <> "data: [DONE]\n\n")
  let assert Ok(opened) =
    runtime.open(pool, http_adapter, request(contracts.Buffered))
  let assert Ok(collected) = adapter.collect(opened, "responses")
  let assert Ok(body) = bit_array.to_string(collected.body)
  let assert Ok(decoded) = responses.decode_response(body)
  decoded.id |> should.equal("resp_synthetic_xai")
  let assert Some(usage) = decoded.usage
  usage.input_tokens |> should.equal(3)
  usage.output_tokens |> should.equal(2)
  let assert Ok(#(path, auth, host)) = process.receive(received, 5000)
  path |> should.equal("/v1/responses")
  auth |> should.equal(Ok("Bearer synthetic-key"))
  host |> should.be_ok
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

pub fn valid_prefix_before_malformed_frame_is_emitted_then_cancelled_test() {
  let #(pool, http_adapter, server, _, _) =
    setup(created() <> "event: response.completed\ndata: {malformed}\n\n")
  let assert Ok(opened) =
    runtime.open(pool, http_adapter, request(contracts.Streaming))
  let events = process.new_subject()
  adapter.run(opened, fn(event) {
    process.send(events, event.name)
    Ok(responses_http.Continue)
  })
  |> should.equal(
    Error(contracts.Failure(contracts.InvalidResponse, contracts.Started, None)),
  )
  process.receive(events, 1000) |> should.equal(Ok("response.created"))
  process.receive(events, 0) |> should.be_error
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
  process.unlink(server.pid)
  process.send_exit(server.pid)
}
