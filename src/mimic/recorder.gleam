import gleam/int
import gleam/result
import mimic/corpus
import mimic/recorder/tls
import mimic/wire
import simplifile

/// Record one complete HTTP/1.1 request from an explicitly operator-owned
/// source. Persistence is always delegated to the redacting corpus boundary.
pub fn record_request(
  root: String,
  raw: String,
  client: String,
  version: String,
  endpoint: String,
  request_kind: String,
) -> Result(String, String) {
  use capture <- result.try(wire.parse_request(
    raw,
    client,
    version,
    endpoint,
    request_kind,
  ))
  corpus.add(root, capture)
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["ca", directory] -> {
      use files <- result.try(tls.generate_ca(directory))
      Ok(
        "CA certificate: "
        <> files.0
        <> "\nCA private key: "
        <> files.1
        <> "\nTrust the certificate only in your explicitly configured QA client.",
      )
    }
    ["capture", root, path, client, version, endpoint, kind] -> {
      use raw <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(_) { "could not read the request file" }),
      )
      record_request(root, raw, client, version, endpoint, kind)
    }
    ["tls", root, port, ca_cert, ca_key, upstream] -> {
      use port <- result.try(
        int.parse(port)
        |> result.map_error(fn(_) { "port must be an integer" }),
      )
      case port > 0 && port <= 65_535 {
        False -> Error("port must be between 1 and 65535")
        True ->
          tls.serve(root, port, ca_cert, ca_key, upstream)
          |> result.map(fn(_) { "" })
      }
    }
    _ ->
      Error(
        "Usage: record capture <corpus-root> <request-file> <client> <version> <endpoint> <request-kind>\n"
        <> "       record ca <new-private-directory>\n"
        <> "       record tls <corpus-root> <port> <ca-cert-file> <ca-key-file> <https-upstream>\n"
        <> "Raw requests are read from files, never command-line arguments.",
      )
  }
}
