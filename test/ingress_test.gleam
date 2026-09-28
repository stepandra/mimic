import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import mimic/ingress
import mimic/lab
import mimic/types.{Header}

pub fn authenticated_anthropic_sse_loopback_test() {
  let oracle =
    lab.Config([Header("x-api-key", "upstream-secret")], 403, 200, "", [
      "{\"part\":1}",
      "{\"part\":2}",
      "[DONE]",
    ])
  let assert Ok(lab_port) = lab.start_with(0, oracle)
  let origin = "http://127.0.0.1:" <> int.to_string(lab_port)
  let assert Ok(port) =
    ingress.start(0, origin, "client-secret", "upstream-secret")
  let bad =
    "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}"
  let assert Ok(denied) = lab.probe(port, bad)
  string.contains(denied, "401") |> should.be_true
  let assert Error(_) = lab.last(lab_port)

  let good =
    "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nx-api-key: client-secret\r\ncontent-type: application/json\r\nContent-Length: 2\r\n\r\n{}"
  let assert Ok(stream) = lab.probe(port, good)
  string.contains(stream, "HTTP/1.1 200") |> should.be_true
  string.contains(stream, "data: {\"part\":1}") |> should.be_true
  string.contains(stream, "data: {\"part\":2}") |> should.be_true
  let assert Ok(observed) = lab.last(lab_port)
  list.contains(observed.headers, Header("x-api-key", "[REDACTED]"))
  |> should.be_true
  let assert Ok(_) = ingress.stop(port)
  let assert Ok(_) = lab.stop(lab_port)
}

pub fn ingress_rejects_unconfigured_or_plaintext_remote_test() {
  let assert Error(_) =
    ingress.start(0, "http://example.com:80", "client", "upstream")
  let assert Error(_) = ingress.start(0, "http://127.0.0.1:80", "", "upstream")
}

pub fn openai_chat_translates_via_ir_to_anthropic_test() {
  let response =
    "{\"id\":\"msg_synthetic\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"test-model\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}"
  let config =
    lab.Config([Header("x-api-key", "upstream-secret")], 403, 200, response, [])
  let assert Ok(lab_port) = lab.start_with(0, config)
  let assert Ok(port) =
    ingress.start(
      0,
      "http://127.0.0.1:" <> int.to_string(lab_port),
      "client-secret",
      "upstream-secret",
    )
  let body =
    "{\"model\":\"test-model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}"
  let request =
    "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer client-secret\r\nContent-Type: application/json\r\nContent-Length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\n\r\n"
    <> body
  let assert Ok(result) = lab.probe(port, request)
  string.contains(result, "HTTP/1.1 200") |> should.be_true
  string.contains(result, "\"choices\"") |> should.be_true
  let assert Ok(observed) = lab.last(lab_port)
  observed.target |> should.equal("/v1/messages")
  string.contains(observed.body, "\"max_tokens\":10") |> should.be_true
  let assert Ok(_) = ingress.stop(port)
  let assert Ok(_) = lab.stop(lab_port)
}

pub fn coalesced_framing_respects_header_and_chunk_caps_test() {
  framing_cases() |> should.be_ok
}

pub fn large_coalesced_chunk_over_real_loopback_test() {
  let upstream_port = chunked_origin()
  let assert Ok(port) =
    ingress.start(
      0,
      "http://127.0.0.1:" <> int.to_string(upstream_port),
      "client-secret",
      "upstream-secret",
    )
  let request =
    "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nx-api-key: client-secret\r\ncontent-type: application/json\r\nContent-Length: 2\r\n\r\n{}"
  let assert Ok(response) = lab.probe(port, request)
  string.contains(response, "HTTP/1.1 200") |> should.be_true
  string.contains(response, string.repeat("x", 9000)) |> should.be_true
  ingress.stop(port) |> should.be_ok
}

@external(erlang, "mimic_ingress_transport_test_ffi", "framing_cases")
fn framing_cases() -> Result(Nil, String)

@external(erlang, "mimic_ingress_transport_test_ffi", "chunked_origin")
fn chunked_origin() -> Int
