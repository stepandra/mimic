import gleam/int
import gleam/string
import gleeunit/should
import mimic/lab
import mimic/types.{Header}

pub fn raw_h1_roundtrip_test() {
  let config =
    lab.Config([Header("X-Required", "yes")], 422, 200, "{\"ok\":true}", [])
  let assert Ok(port) = lab.start_with(0, config)
  let request =
    "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Required: yes\r\nx-Dup: one\r\nX-Dup: two\r\nAuthorization: secret\r\nContent-Length: 2\r\n\r\n{}"
  let assert Ok(response) = lab.probe(port, request)
  string.contains(response, "HTTP/1.1 200 OK") |> should.be_true
  let assert Ok(observed) = lab.last(port)
  observed.method |> should.equal("POST")
  observed.target |> should.equal("/v1/messages")
  observed.body |> should.equal("{}")
  observed.headers
  |> should.equal([
    Header("Host", "127.0.0.1"),
    Header("X-Required", "yes"),
    Header("x-Dup", "one"),
    Header("X-Dup", "two"),
    Header("Authorization", "[REDACTED]"),
    Header("Content-Length", "2"),
  ])
  let assert Ok(_) = lab.stop(port)
}

pub fn required_header_and_scripted_events_test() {
  let config =
    lab.Config([Header("anthropic-version", "2023-06-01")], 400, 200, "", [
      "{\"n\":1}",
      "{\"n\":2}",
    ])
  let assert Ok(port) = lab.start_with(0, config)
  let assert Ok(bad) =
    lab.probe(
      port,
      "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nAnthropic-Version: wrong\r\n\r\n",
    )
  string.contains(bad, "HTTP/1.1 400 Bad Request") |> should.be_true
  let assert Ok(zero) = lab.count(port)
  zero |> should.equal(0)
  let assert Ok(good) =
    lab.probe(
      port,
      "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nAnthropic-Version: 2023-06-01\r\n\r\n",
    )
  string.contains(good, "Content-Type: text/event-stream") |> should.be_true
  string.contains(good, "data: {\"n\":1}\n\ndata: {\"n\":2}\n\n")
  |> should.be_true
  let assert Ok(events) = lab.count(port)
  events |> should.equal(2)
  let assert Ok(_) = lab.stop(port)
}

pub fn large_coalesced_request_body_does_not_count_as_header_test() {
  let assert Ok(port) = lab.start(0)
  let body = string.repeat("x", 70_000)
  let request =
    "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\n\r\n"
    <> body
  let assert Ok(response) = lab.probe(port, request)
  string.contains(response, "HTTP/1.1 200") |> should.be_true
  let assert Ok(observed) = lab.last(port)
  observed.body |> should.equal(body)
  lab.stop(port) |> should.be_ok
}
