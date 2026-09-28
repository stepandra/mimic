import gleam/option
import gleam/result
import mimic/corpus
import mimic/types.{Capture, Transport}
import mimic/wire

/// Create a private CA for a single, explicitly opted-in QA proxy.
/// The key and certificate paths are returned; never install the CA system-wide.
pub fn generate_ca(directory: String) -> Result(#(String, String), String) {
  ffi_generate_ca(directory)
}

/// Blocks while serving a loopback-only CONNECT proxy. The upstream must be an
/// explicit https://host:port URL. Only successful, redacted corpus writes allow
/// a request to be forwarded.
pub fn serve(
  root: String,
  bind_port: Int,
  ca_cert: String,
  ca_key: String,
  allowed_upstream: String,
) -> Result(Nil, String) {
  serve_with_capture(
    bind_port,
    ca_cert,
    ca_key,
    allowed_upstream,
    "",
    fn(raw, endpoint, alpn) {
      use captured <- result.try(wire.parse_request(
        raw,
        "unknown",
        "unknown",
        endpoint,
        "unknown",
      ))
      corpus.add(
        root,
        Capture(..captured, transport: Transport(alpn: alpn, ja4: option.None)),
      )
    },
  )
}

/// The trust file is for an operator-owned QA upstream only. An empty trust
/// file means the OS CA bundle. The callback runs before any request is sent.
/// It must persist only redacted data and return an error to fail closed.
pub fn serve_with_capture(
  bind_port: Int,
  ca_cert: String,
  ca_key: String,
  allowed_upstream: String,
  upstream_ca: String,
  capture: fn(String, String, String) -> Result(String, String),
) -> Result(Nil, String) {
  ffi_serve(bind_port, ca_cert, ca_key, allowed_upstream, upstream_ca, capture)
}

@external(erlang, "mimic_recorder_tls_ffi", "generate_ca")
fn ffi_generate_ca(directory: String) -> Result(#(String, String), String)

@external(erlang, "mimic_recorder_tls_ffi", "serve")
fn ffi_serve(
  port: Int,
  ca_cert: String,
  ca_key: String,
  upstream: String,
  upstream_ca: String,
  capture: fn(String, String, String) -> Result(String, String),
) -> Result(Nil, String)
