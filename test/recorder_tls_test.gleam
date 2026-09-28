import gleam/option
import gleam/result
import gleam/string
import gleeunit
import mimic/corpus
import mimic/recorder/tls
import mimic/types.{Capture, Header, Transport}
import mimic/wire

pub fn main() {
  gleeunit.main()
}

pub fn local_connect_tls_sse_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(new_ca_dir())
  let assert Ok(#(response, #(raw, endpoint, alpn), denied)) =
    roundtrip(cert, key, True, fn(_, _, _) { Ok("synthetic") })

  assert string.starts_with(denied, "HTTP/1.1 403")
  assert string.starts_with(response, "HTTP/1.1 200 OK")
  assert string.contains(response, "B\r\ndata: one\n\n\r\n")
  assert string.contains(response, "B\r\ndata: two\n\n\r\n0\r\n\r\n")
  assert string.starts_with(raw, "POST /v1/qa HTTP/1.1\r\n")
  assert string.contains(raw, "X-CaSe: first\r\nx-case: second\r\n")
  assert string.contains(raw, "{\"stream\":true}")
  assert string.starts_with(endpoint, "127.0.0.1:")
  assert alpn == "http/1.1"
}

pub fn capture_is_redacted_before_persistence_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(new_ca_dir())
  let root = new_ca_dir()
  let assert Ok(#(response, _, _)) =
    roundtrip(cert, key, True, fn(raw, endpoint, alpn) {
      use captured <- result.try(wire.parse_request(
        raw,
        "synthetic-test",
        "1",
        endpoint,
        "qa",
      ))
      corpus.add(
        root,
        Capture(..captured, transport: Transport(alpn: alpn, ja4: option.None)),
      )
    })
  assert string.starts_with(response, "HTTP/1.1 200 OK")
  let assert Ok([captured]) = corpus.list(root)
  let assert [
    Header("Host", _),
    Header("X-CaSe", _),
    Header("x-case", _),
    Header("Authorization", "[REDACTED]"),
    ..
  ] = captured.headers
  let assert False =
    string.contains(corpus.encode(captured), "synthetic-not-a-secret")
}

pub fn upstream_certificate_is_verified_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(new_ca_dir())
  let assert Ok(#(response, _, _)) =
    roundtrip(cert, key, False, fn(_, _, _) { Ok("synthetic") })
  assert string.starts_with(response, "HTTP/1.1 502")
}

pub fn h2_and_encoded_requests_fail_closed_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(new_ca_dir())
  let assert Ok(h2) = rejected_request(cert, key, "h2")
  let assert Ok(encoded) = rejected_request(cert, key, "encoding")
  assert string.starts_with(h2, "HTTP/1.1 400")
  assert string.starts_with(encoded, "HTTP/1.1 415")
}

pub fn upstream_must_be_explicit_https_test() {
  let result =
    tls.serve_with_capture(0, "", "", "http://127.0.0.1:1", "", fn(_, _, _) {
      Ok("synthetic")
    })
  assert result == Error("Upstream must be explicit https://host:port")
}

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn new_ca_dir() -> String

@external(erlang, "mimic_recorder_tls_test_ffi", "roundtrip")
fn roundtrip(
  cert: String,
  key: String,
  trust_upstream: Bool,
  persist: fn(String, String, String) -> Result(String, String),
) -> Result(#(String, #(String, String, String), String), String)

@external(erlang, "mimic_recorder_tls_test_ffi", "rejected_request")
fn rejected_request(
  cert: String,
  key: String,
  kind: String,
) -> Result(String, String)
