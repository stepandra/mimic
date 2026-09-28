import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/egress
import mimic/types.{type Capture, Capture, Header, Transport}

type Fixture

@external(erlang, "mimic_egress_test_ffi", "start")
fn fixture_start(response: String) -> Result(Fixture, String)

@external(erlang, "mimic_egress_test_ffi", "start_drop")
fn fixture_drop(response: String) -> Result(Fixture, String)

@external(erlang, "mimic_egress_test_ffi", "start_binary")
fn fixture_binary() -> Result(Fixture, String)

@external(erlang, "mimic_egress_test_ffi", "port")
fn fixture_port(fixture: Fixture) -> Int

@external(erlang, "mimic_egress_test_ffi", "accepts")
fn fixture_accepts(fixture: Fixture) -> Int

@external(erlang, "mimic_egress_test_ffi", "requests")
fn fixture_requests(fixture: Fixture) -> List(String)

@external(erlang, "mimic_egress_test_ffi", "stop")
fn fixture_stop(fixture: Fixture) -> Nil

fn endpoint(fixture: Fixture) -> String {
  "http://127.0.0.1:" <> int.to_string(fixture_port(fixture))
}

fn capture(endpoint: String) -> Capture {
  Capture(
    client: "synthetic",
    version: "1",
    endpoint: endpoint,
    request_kind: "test",
    method: "POST",
    target: "/v1/messages",
    http_version: "HTTP/1.1",
    headers: [
      Header("Host", "127.0.0.1"),
      Header("X-Order", "a"),
      Header("x-order", "b"),
      Header("Content-Type", "application/json"),
      Header("Content-Length", "2"),
    ],
    body: "{}",
    transport: Transport(alpn: "http/1.1", ja4: None),
  )
}

pub fn same_socket_serves_two_calls_in_order_test() {
  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nX-Order: a\r\nx-order: b\r\nContent-Length: 2\r\n\r\n{}",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  let assert Ok(first) = egress.send(client, capture(url))
  let assert Ok(second) = egress.send(client, capture(url))
  first.status |> should.equal(second.status)
  first.headers |> should.equal(second.headers)
  first.body |> should.equal(second.body)
  first.status |> should.equal(200)
  first.headers
  |> should.equal([
    Header("X-Order", "a"),
    Header("x-order", "b"),
    Header("Content-Length", "2"),
  ])
  first.body |> should.equal("{}")
  fixture_accepts(fixture) |> should.equal(1)
  fixture_requests(fixture)
  |> should.equal([
    "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Order: a\r\nx-order: b\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
    "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Order: a\r\nx-order: b\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
  ])
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)
}

pub fn chunked_response_and_next_request_test() {
  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  let assert Ok(response) = egress.send(client, capture(url))
  response.body |> should.equal("{}")
  egress.send(client, capture(url)) |> should.be_ok
  fixture_accepts(fixture) |> should.equal(1)
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)
}

pub fn connection_close_reconnects_on_next_request_test() {
  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  egress.send(client, capture(url)) |> should.be_ok
  egress.send(client, capture(url)) |> should.be_ok
  fixture_accepts(fixture) |> should.equal(2)
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)
}

pub fn observed_peer_disconnect_reconnects_without_replaying_test() {
  let assert Ok(fixture) =
    fixture_drop("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  egress.send(client, capture(url)) |> should.be_ok
  egress.send(client, capture(url)) |> should.be_ok
  fixture_accepts(fixture) |> should.equal(2)
  fixture_requests(fixture) |> list.length |> should.equal(2)
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)
}

pub fn no_body_and_interim_responses_test() {
  let assert Ok(head_fixture) =
    fixture_start("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n")
  let url = endpoint(head_fixture)
  let assert Ok(client) = egress.start(url)
  let head =
    Capture(
      ..capture(url),
      method: "HEAD",
      headers: [Header("Host", "127.0.0.1")],
      body: "",
    )
  let assert Ok(head_response) = egress.send(client, head)
  head_response.body |> should.equal("")
  egress.close(client) |> should.be_ok
  fixture_stop(head_fixture)

  let assert Ok(not_modified) =
    fixture_start("HTTP/1.1 304 Not Modified\r\nContent-Length: 20\r\n\r\n")
  let url = endpoint(not_modified)
  let assert Ok(client) = egress.start(url)
  let assert Ok(response) = egress.send(client, capture(url))
  response.body |> should.equal("")
  egress.close(client) |> should.be_ok
  fixture_stop(not_modified)

  let assert Ok(interim) =
    fixture_start(
      "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
    )
  let url = endpoint(interim)
  let assert Ok(client) = egress.start(url)
  let assert Ok(response) = egress.send(client, capture(url))
  response.status |> should.equal(200)
  response.body |> should.equal("{}")
  egress.close(client) |> should.be_ok
  fixture_stop(interim)
}

pub fn chunk_extension_and_ambiguous_whitespace_header_test() {
  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;foo=\"a;b\"\r\n{}\r\n0\r\n\r\n",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  let assert Ok(response) = egress.send(client, capture(url))
  response.body |> should.equal("{}")
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)

  let assert Ok(invalid) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding : chunked\r\nContent-Length: 4\r\n\r\n",
    )
  let url = endpoint(invalid)
  let assert Ok(client) = egress.start(url)
  egress.send(client, capture(url)) |> should.be_error
  egress.close(client) |> should.be_ok
  fixture_stop(invalid)
}

pub fn malformed_framing_fails_without_replay_test() {
  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  let assert Error(_) = egress.send(client, capture(url))
  fixture_accepts(fixture) |> should.equal(1)
  fixture_requests(fixture) |> list.length |> should.equal(1)
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)
}

pub fn binary_body_is_rejected_test() {
  let assert Ok(fixture) = fixture_binary()
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  let assert Error(reason) = egress.send(client, capture(url))
  string.contains(reason, "UTF-8") |> should.be_true
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)

  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 2\r\n\r\n{}",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  egress.send(client, capture(url)) |> should.be_error
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)
}

pub fn limits_and_protocol_rejections_test() {
  let assert Ok(fixture) =
    fixture_start("HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\n\r\n")
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  let assert Error(_) = egress.send(client, capture(url))
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)

  egress.start("http://user:secret@localhost") |> should.be_error
  egress.start("http://localhost/path") |> should.be_error
  egress.start("h2://localhost") |> should.be_error
  let assert Ok(other) = egress.start("http://127.0.0.1:1")
  let assert Error(_) = egress.send(other, capture("http://127.0.0.1:2"))
  egress.close(other) |> should.be_ok
}

pub fn cumulative_header_limit_and_timeout_test() {
  let long_headers = string.repeat("X-Test: a\r\n", 7000)
  let assert Ok(fixture) =
    fixture_start(
      "HTTP/1.1 200 OK\r\n" <> long_headers <> "Content-Length: 0\r\n\r\n",
    )
  let url = endpoint(fixture)
  let assert Ok(client) = egress.start(url)
  egress.send(client, capture(url)) |> should.be_error
  egress.close(client) |> should.be_ok
  fixture_stop(fixture)

  let assert Ok(silent) = fixture_start("")
  let url = endpoint(silent)
  let assert Ok(client) = egress.start(url)
  let assert Error(reason) = egress.send(client, capture(url))
  string.contains(reason, "timeout") |> should.be_true
  fixture_requests(silent) |> list.length |> should.equal(1)
  egress.close(client) |> should.be_ok
  fixture_stop(silent)
}
