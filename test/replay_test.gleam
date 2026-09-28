import gleam/int
import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/persona
import mimic/replay
import mimic/types.{type Capture, Capture, Header, Transport}

@external(erlang, "mimic_replay_test_ffi", "start")
fn start_server() -> Int

@external(erlang, "mimic_replay_test_ffi", "received")
fn received() -> String

@external(erlang, "mimic_replay_test_ffi", "start_chunked")
fn start_chunked_server() -> Int

@external(erlang, "mimic_replay_test_ffi", "start_bad_chunked")
fn start_bad_chunked_server() -> Int

@external(erlang, "mimic_replay_test_ffi", "start_bad_extension")
fn start_bad_extension_server() -> Int

@external(erlang, "mimic_replay_test_ffi", "start_bad_trailer")
fn start_bad_trailer_server() -> Int

@external(erlang, "mimic_replay_test_ffi", "start_response")
fn start_response(response: String) -> Int

@external(erlang, "mimic_replay_test_ffi", "start_interim")
fn start_interim() -> Int

@external(erlang, "mimic_replay_test_ffi", "start_fragmented")
fn start_fragmented() -> Int

fn sample() {
  Capture(
    "synthetic-client",
    "1.0.0",
    "http://127.0.0.1:9999",
    "main",
    "POST",
    "/v1/messages",
    "HTTP/1.1",
    [
      Header("Host", "fixture.test"),
      Header("X-Trace", "a"),
      Header("x-trace", "b"),
      Header("Content-Length", "2"),
    ],
    "{}",
    Transport("http/1.1", None),
  )
}

pub fn ordered_frame_test() {
  let capture = sample()
  let assert Ok(persona) = persona.draft([capture])
  let assert Ok(actual) = replay.materialize(persona, capture)
  actual.headers |> should.equal(capture.headers)
  let assert Ok(frame) = replay.render_request(actual)
  frame
  |> should.equal(
    "POST /v1/messages HTTP/1.1\r\nHost: fixture.test\r\nX-Trace: a\r\nx-trace: b\r\nContent-Length: 2\r\n\r\n{}",
  )
}

pub fn beta_rules_materialize_in_header_position_test() {
  let capture =
    Capture(..sample(), headers: [
      Header("Host", "fixture.test"),
      Header("AnThRoPiC-BeTa", "fixture-alpha,fixture-legacy"),
      Header("Content-Length", "2"),
    ])
  let assert Ok(profile) = persona.draft([capture])
  let assert Ok(actual) = replay.materialize(profile, capture)
  actual.headers |> should.equal(capture.headers)
}

pub fn forbidden_passthrough_beta_combination_test() {
  let capture =
    Capture(..sample(), headers: [
      Header("Host", "fixture.test"),
      Header("anthropic-beta", "a, b"),
      Header("Content-Length", "2"),
    ])
  let assert Ok(profile) = persona.draft([capture])
  let profile =
    persona.Persona(
      ..profile,
      headers: [
        persona.HeaderRule("Host", "fixed", "fixture.test", "*"),
        persona.HeaderRule("anthropic-beta", "passthrough", "", "*"),
        persona.HeaderRule("Content-Length", "passthrough", "", "*"),
      ],
      betas: [],
      forbidden_betas: [["a", "b"]],
    )
  let assert Error(message) = replay.materialize(profile, capture)
  message |> string.contains("Forbidden beta") |> should.be_true
}

pub fn forbidden_fixed_beta_combination_test() {
  let capture = sample()
  let assert Ok(profile) = persona.draft([capture])
  let profile =
    persona.Persona(
      ..profile,
      headers: [
        persona.HeaderRule("Host", "fixed", "fixture.test", "*"),
        persona.HeaderRule("anthropic-beta", "fixed", "a,b", "*"),
        persona.HeaderRule("Content-Length", "passthrough", "", "*"),
      ],
      betas: [],
      forbidden_betas: [["a", "b"]],
    )
  let assert Error(message) = replay.materialize(profile, capture)
  message |> string.contains("Forbidden beta") |> should.be_true
}

pub fn unresolved_redaction_placeholder_is_not_sent_test() {
  let capture =
    Capture(..sample(), headers: [
      Header("Host", "fixture.test"),
      Header("Authorization", "[REDACTED]"),
      Header("Content-Length", "2"),
    ])
  let assert Error(message) = replay.render_request(capture)
  message |> string.contains("redacted") |> should.be_true
}

pub fn materialize_rejects_unresolved_passthrough_credential_test() {
  let capture =
    Capture(..sample(), headers: [
      Header("Host", "fixture.test"),
      Header("Authorization", "[REDACTED]"),
      Header("Content-Length", "2"),
    ])
  let assert Ok(profile) = persona.draft([sample()])
  let profile =
    persona.Persona(..profile, headers: [
      persona.HeaderRule("Host", "fixed", "fixture.test", "*"),
      persona.HeaderRule("Authorization", "passthrough", "", "*"),
      persona.HeaderRule("Content-Length", "passthrough", "", "*"),
    ])
  let assert Error(message) = replay.materialize(profile, capture)
  message |> string.contains("redacted") |> should.be_true
}

pub fn reject_bad_length_test() {
  let capture = Capture(..sample(), body: "éé")
  let assert Error(message) = replay.render_request(capture)
  message |> string.contains("Content-Length") |> should.be_true
}

pub fn identity_uuid_test() {
  let capture = sample()
  let assert Ok(p) = persona.draft([capture])
  let rules = [
    persona.HeaderRule("Host", "fixed", "fixture.test", "*"),
    persona.HeaderRule("X-Request-Id", "uuid", "", "*"),
    persona.HeaderRule("Content-Length", "passthrough", "", "*"),
  ]
  let p = persona.Persona(..p, headers: rules)
  let assert Ok(first) = replay.materialize(p, capture)
  let assert Ok(second) = replay.materialize(p, capture)
  let assert [_, Header(_, a), _] = first.headers
  let assert [_, Header(_, b), _] = second.headers
  should.be_false(a == b)
  string.length(a) |> should.equal(36)
}

pub fn unsupported_transport_test() {
  let capture = Capture(..sample(), transport: Transport("h2", None))
  let assert Error(_) = replay.send("http://127.0.0.1:9999", capture)
}

pub fn http11_without_negotiated_alpn_test() {
  let capture = Capture(..sample(), transport: Transport("none", None))
  let assert Ok(_) = replay.render_request(capture)
}

pub fn loopback_send_test() {
  let port = start_server()
  let endpoint = "http://127.0.0.1:" <> int.to_string(port)
  let capture = sample()
  let assert Ok(p) = persona.draft([capture])
  let assert Ok(materialized) = replay.materialize(p, capture)
  let assert Ok(response) = replay.send(endpoint, materialized)
  response.status |> should.equal(200)
  response.body |> should.equal("ok")
  let assert Ok(expected) = replay.render_request(materialized)
  received() |> should.equal(expected)
}

pub fn chunked_sse_test() {
  let port = start_chunked_server()
  let endpoint = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(response) = replay.send(endpoint, sample())
  response.body |> should.equal("data: é\n\n")
  response.headers
  |> should.equal([
    Header("Transfer-Encoding", "chunked"),
    Header("X-Trailer", "yes"),
  ])
  let _ = received()
}

pub fn malformed_chunk_test() {
  let port = start_bad_chunked_server()
  let assert Error(message) =
    replay.send("http://127.0.0.1:" <> int.to_string(port), sample())
  message |> string.contains("Invalid chunk") |> should.be_true
  let _ = received()
}

pub fn malformed_chunk_extension_test() {
  let port = start_bad_extension_server()
  let assert Error(message) =
    replay.send("http://127.0.0.1:" <> int.to_string(port), sample())
  message |> string.contains("Invalid chunk") |> should.be_true
  let _ = received()
}

pub fn forbidden_trailer_test() {
  let port = start_bad_trailer_server()
  let assert Error(message) =
    replay.send("http://127.0.0.1:" <> int.to_string(port), sample())
  message |> string.contains("Invalid response trailer") |> should.be_true
  let _ = received()
}

fn send_response(response: String, capture: Capture) {
  let port = start_response(response)
  let result = replay.send("http://127.0.0.1:" <> int.to_string(port), capture)
  let _ = received()
  result
}

pub fn head_response_has_no_body_even_with_content_length_test() {
  let capture = Capture(..sample(), method: "HEAD")
  let assert Ok(response) =
    send_response("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n", capture)
  response.status |> should.equal(200)
  response.body |> should.equal("")
  response.headers |> should.equal([Header("Content-Length", "20")])
}

pub fn not_modified_response_has_no_body_even_with_content_length_test() {
  let assert Ok(response) =
    send_response(
      "HTTP/1.1 304 Not Modified\r\nContent-Length: 20\r\nContent-Encoding: gzip\r\n\r\n",
      sample(),
    )
  response.status |> should.equal(304)
  response.body |> should.equal("")
}

pub fn head_response_allows_representation_content_encoding_test() {
  let assert Ok(response) =
    send_response(
      "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nContent-Encoding: gzip\r\n\r\n",
      Capture(..sample(), method: "HEAD"),
    )
  response.status |> should.equal(200)
  response.body |> should.equal("")
}

pub fn no_content_response_has_no_body_even_with_content_length_test() {
  let assert Ok(response) =
    send_response(
      "HTTP/1.1 204 No Content\r\nContent-Length: 20\r\n\r\n",
      sample(),
    )
  response.status |> should.equal(204)
  response.body |> should.equal("")
}

pub fn interim_response_is_consumed_test() {
  let port = start_interim()
  let result = replay.send("http://127.0.0.1:" <> int.to_string(port), sample())
  let _ = received()
  let assert Ok(response) = result
  response.status |> should.equal(200)
  response.body |> should.equal("ok")
  response.headers |> should.equal([Header("Content-Length", "2")])
}

pub fn coalesced_interim_and_final_response_test() {
  let assert Ok(response) =
    send_response(
      "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
      sample(),
    )
  response.status |> should.equal(200)
  response.body |> should.equal("ok")
}

pub fn quoted_semicolon_chunk_extension_test() {
  let assert Ok(response) =
    send_response(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2 \t; foo \t= \"a;b\" \r\nok\r\n0\r\n\r\n",
      sample(),
    )
  response.body |> should.equal("ok")
}

pub fn non_decimal_content_length_is_rejected_test() {
  let assert Error(message) =
    send_response("HTTP/1.1 200 OK\r\nContent-Length: +2\r\n\r\nok", sample())
  message |> string.contains("Content-Length") |> should.be_true
}

pub fn representation_trailer_is_rejected_test() {
  let assert Error(message) =
    send_response(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nContent-Encoding: gzip\r\n\r\n",
      sample(),
    )
  message |> string.contains("Invalid response trailer") |> should.be_true
}

pub fn whitespace_before_header_colon_is_rejected_test() {
  let assert Error(message) =
    send_response(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding : chunked\r\nContent-Length: 4\r\n\r\nokay",
      sample(),
    )
  message |> string.contains("header") |> should.be_true
}

pub fn complete_oversized_headers_are_rejected_test() {
  let assert Error(message) =
    send_response(
      "HTTP/1.1 200 OK\r\nX-Fill: "
        <> string.repeat("x", 70_000)
        <> "\r\nContent-Length: 2\r\n\r\nok",
      sample(),
    )
  message |> string.contains("64 KiB") |> should.be_true
}

pub fn complete_oversized_trailers_are_rejected_test() {
  let assert Error(message) =
    send_response(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
        <> string.repeat("X-Fill: " <> string.repeat("x", 300) <> "\r\n", 220)
        <> "\r\n",
      sample(),
    )
  message |> string.contains("64 KiB") |> should.be_true
}

pub fn ambiguous_transfer_encoding_and_length_are_rejected_test() {
  let assert Error(message) =
    send_response(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n0\r\n\r\n",
      sample(),
    )
  message |> string.contains("Ambiguous") |> should.be_true
}

pub fn unsupported_upgrade_is_rejected_test() {
  let assert Error(message) =
    send_response("HTTP/1.1 101 Switching Protocols\r\n\r\n", sample())
  message |> string.contains("upgrade") |> should.be_true
}

pub fn too_many_interim_responses_are_rejected_test() {
  let assert Error(message) =
    send_response(
      string.repeat("HTTP/1.1 100 Continue\r\n\r\n", 17)
        <> "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
      sample(),
    )
  message |> string.contains("Too many interim") |> should.be_true
}

pub fn oversized_response_is_rejected_test() {
  let assert Error(message) =
    send_response(
      "HTTP/1.1 200 OK\r\n\r\n" <> string.repeat("x", 2_100_000),
      sample(),
    )
  message |> string.contains("2 MiB") |> should.be_true
}

pub fn fragmented_valid_response_is_not_limited_by_receive_count_test() {
  let port = start_fragmented()
  let result = replay.send("http://127.0.0.1:" <> int.to_string(port), sample())
  let _ = received()
  let assert Ok(response) = result
  response.body |> should.equal(string.repeat("x", 800))
}
