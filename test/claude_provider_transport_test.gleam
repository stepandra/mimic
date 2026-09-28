import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request as http_request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/egress
import mimic/providers/claude/request
import mist

/// Synthetic native-shaped requests through the real HTTP/1.1 egress client.
/// This is not an ingress route test or a real Claude Code binary run.
pub fn local_messages_and_count_tokens_wire_test() {
  let started = process.new_subject()
  let observed = process.new_subject()
  let handler = fn(req: http_request.Request(BitArray)) {
    let assert Ok(body) = bit_array.to_string(req.body)
    process.send(observed, #(req.path, req.query, req.headers, body))
    let response_body = case req.path {
      "/v1/messages/count_tokens" -> "{\"input_tokens\":3}"
      _ ->
        "{\"id\":\"synthetic-message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"synthetic\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}"
    }
    response.new(200)
    |> response.set_header("content-type", "application/json")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(response_body)))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
    |> mist.read_request_body(
      bytes_limit: 8192,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(started, 5000)
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(client) = egress.start(origin)
  let body =
    "{\"model\":\"synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}]}"
  list.each([request.Messages(False), request.CountTokens], fn(operation) {
    let assert Ok(capture) =
      request.prepare(
        origin,
        request.ApiKey("synthetic-selected-key"),
        operation,
        [],
        None,
        body,
      )
    let assert Ok(response) = egress.send(client, capture)
    response.status |> should.equal(200)
    let assert Ok(#(path, query, headers, received_body)) =
      process.receive(observed, 5000)
    let expected_path = case operation {
      request.Messages(_) -> "/v1/messages"
      request.CountTokens -> "/v1/messages/count_tokens"
    }
    path |> should.equal(expected_path)
    query |> should.equal(Some("beta=true"))
    list.key_find(headers, "x-api-key")
    |> should.equal(Ok("synthetic-selected-key"))
    list.key_find(headers, "authorization") |> should.be_error
    received_body |> should.equal(body)
  })
  egress.close(client) |> should.equal(Ok(Nil))
  process.unlink(server.pid)
  process.send_exit(server.pid)
}
