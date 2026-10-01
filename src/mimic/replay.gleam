import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import mimic/corpus
import mimic/persona.{type HeaderRule, type Persona}
import mimic/types.{
  type Capture, type Header, type WireResponse, Capture, Header, WireResponse,
}
import simplifile

@external(erlang, "mimic_replay_ffi", "uuid")
fn uuid() -> String

@external(erlang, "mimic_replay_ffi", "timestamp_ms")
fn timestamp_ms() -> String

@external(erlang, "mimic_replay_ffi", "exchange")
fn exchange(
  tls: Bool,
  host: String,
  port: Int,
  request: String,
  method: String,
) -> Result(#(String, Int), String)

/// Materialization replaces the entire ordered header list. Never merge rules
/// into the old list: that would silently preserve extra, unprofiled headers.
pub fn materialize(
  persona: Persona,
  capture: Capture,
) -> Result(Capture, String) {
  case persona.lint(persona) {
    [] -> {
      let rules =
        list.filter(persona.headers, fn(h) {
          h.request_kind == "*" || h.request_kind == capture.request_kind
        })
      let betas =
        list.map(
          list.filter(persona.betas, fn(b) {
            b.request_kind == "*" || b.request_kind == capture.request_kind
          }),
          fn(b) { b.value },
        )
      use headers <- result.try(
        list.index_map(rules, fn(rule, index) {
          header_for(rule, index, rules, capture.headers, betas)
        })
        |> list.try_map(fn(x) { x }),
      )
      let emitted_betas =
        list.flat_map(headers, fn(header) {
          let Header(name, value) = header
          case string.lowercase(name) == "anthropic-beta" {
            True -> list.map(string.split(value, ","), string.trim)
            False -> []
          }
        })
      let forbidden =
        list.any(persona.forbidden_betas, fn(group) {
          list.all(group, fn(value) { list.contains(emitted_betas, value) })
        })
      case forbidden {
        True -> Error("Forbidden beta combination for request kind")
        False -> {
          let rendered = Capture(..capture, headers: headers)
          use _ <- result.try(validate_request(rendered))
          Ok(rendered)
        }
      }
    }
    errors -> Error("Invalid persona: " <> string.join(errors, "; "))
  }
}

fn header_for(
  rule: HeaderRule,
  index: Int,
  rules: List(HeaderRule),
  original: List(Header),
  betas: List(String),
) -> Result(Header, String) {
  let previous = list.take(rules, index)
  let occurrence =
    list.count(previous, fn(h) {
      string.lowercase(h.name) == string.lowercase(rule.name)
    })
  let value = case rule.source {
    "fixed" -> Ok(rule.value)
    "uuid" -> Ok(uuid())
    "timestamp" -> Ok(timestamp_ms())
    "betas" ->
      case betas {
        [] -> Error("No beta values for " <> rule.name)
        _ -> Ok(string.join(betas, ","))
      }
    "passthrough" -> {
      let matching =
        list.filter(original, fn(h) {
          let Header(name, _) = h
          string.lowercase(name) == string.lowercase(rule.name)
        })
      case list.drop(matching, occurrence) {
        [Header(_, value), ..] -> Ok(value)
        [] -> Error("Missing passthrough header " <> rule.name)
      }
    }
    _ -> Error("Unsupported header source " <> rule.source)
  }
  result.map(value, fn(v) { Header(rule.name, v) })
}

fn valid_field(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn validate_request(capture: Capture) -> Result(Nil, String) {
  let host =
    list.filter(capture.headers, fn(h) {
      let Header(name, _) = h
      string.lowercase(name) == "host"
    })
  let lengths =
    list.filter(capture.headers, fn(h) {
      let Header(name, _) = h
      string.lowercase(name) == "content-length"
    })
  let transfer =
    list.any(capture.headers, fn(h) {
      let Header(name, _) = h
      string.lowercase(name) == "transfer-encoding"
    })
  let safe_headers =
    list.all(capture.headers, fn(h) {
      let Header(name, value) = h
      name != ""
      && string.byte_size(name) == string.length(name)
      && list.all(string.to_graphemes(name), fn(c) {
        string.contains(
          "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
          c,
        )
      })
      && valid_field(value)
      && !string.contains(value, "[REDACTED]")
    })
  case
    capture.http_version == "HTTP/1.1"
    && {
      capture.transport.alpn == "http/1.1" || capture.transport.alpn == "none"
    }
    && capture.transport.ja4 == None
    && valid_field(capture.method)
    && capture.method != ""
    && !string.contains(capture.method, " ")
    && !string.contains(capture.method, "\t")
    && string.starts_with(capture.target, "/")
    && valid_field(capture.target)
    && !string.contains(capture.target, " ")
    && !string.contains(capture.target, "\t")
    && safe_headers
    && list.length(host) == 1
    && list.all(host, fn(h) {
      let Header(_, value) = h
      string.trim(value) != ""
    })
    && !transfer
    && list.length(lengths) <= 1
  {
    False ->
      case
        list.any(capture.headers, fn(h) {
          let Header(_, value) = h
          string.contains(value, "[REDACTED]")
        })
      {
        True -> Error("Unresolved redacted header; supply runtime value")
        False -> Error("Unsupported or unsafe HTTP/1.1 request/transport")
      }
    True ->
      case lengths {
        [] ->
          case capture.body {
            "" -> Ok(Nil)
            _ -> Error("Body requires Content-Length")
          }
        [Header(_, value)] ->
          case int.parse(value) {
            Ok(bytes) ->
              case bytes == string.byte_size(capture.body) {
                True -> Ok(Nil)
                False ->
                  Error("Content-Length does not match UTF-8 body byte size")
              }
            _ -> Error("Content-Length does not match UTF-8 body byte size")
          }
        _ -> Error("Duplicate Content-Length")
      }
  }
}

/// Exact request-line and ordered header serialization, with no HTTP client
/// normalization of case or duplicate header fields.
pub fn render_request(capture: Capture) -> Result(String, String) {
  use _ <- result.try(validate_request(capture))
  let headers =
    list.map(capture.headers, fn(h) {
      let Header(name, value) = h
      name <> ": " <> value <> "\r\n"
    })
  let frame =
    capture.method
    <> " "
    <> capture.target
    <> " HTTP/1.1\r\n"
    <> string.join(headers, "")
    <> "\r\n"
    <> capture.body
  case string.byte_size(frame) <= 2_097_152 {
    True -> Ok(frame)
    False -> Error("Request exceeds 2 MiB")
  }
}

/// Endpoint is an explicit authority, not a redirectable URL. Host in the
/// capture remains unchanged for local echo/oracle contract tests.
pub fn send(
  endpoint: String,
  capture: Capture,
) -> Result(WireResponse, String) {
  use authority <- result.try(parse_endpoint(endpoint))
  let #(tls, host, port) = authority
  use frame <- result.try(render_request(capture))
  use response <- result.try(exchange(tls, host, port, frame, capture.method))
  let #(raw, ttft_ms) = response
  parse_response(raw, ttft_ms)
}

fn parse_endpoint(endpoint: String) -> Result(#(Bool, String, Int), String) {
  let #(tls, authority) = case string.split_once(endpoint, "://") {
    Ok(#("http", value)) -> #(False, value)
    Ok(#("https", value)) -> #(True, value)
    _ -> #(False, "")
  }
  let authority = case string.split_once(authority, "/") {
    Ok(#(a, "")) -> a
    _ -> authority
  }
  case
    authority == ""
    || string.contains(authority, "/")
    || string.contains(authority, "@")
    || string.contains(authority, "?")
    || string.contains(authority, "#")
    || string.contains(authority, "\\")
  {
    True ->
      Error("Endpoint must be an explicit http(s)://host[:port] authority")
    False -> {
      let pieces = string.split(authority, ":")
      case pieces {
        [host] if host != "" ->
          Ok(
            #(tls, host, case tls {
              True -> 443
              False -> 80
            }),
          )
        [host, port] if host != "" ->
          case int.parse(port) {
            Ok(p) if p > 0 && p <= 65_535 -> Ok(#(tls, host, p))
            _ -> Error("Invalid endpoint port")
          }
        _ ->
          Error("Invalid endpoint authority (IPv6 literals are not supported)")
      }
    }
  }
}

fn parse_response(raw: String, ttft_ms: Int) -> Result(WireResponse, String) {
  use parts <- result.try(
    string.split_once(raw, "\r\n\r\n")
    |> result.map_error(fn(_) { "Malformed HTTP response" }),
  )
  let #(head, body) = parts
  case string.split(head, "\r\n") {
    [status_line, ..header_lines] -> {
      let status_parts = string.split(status_line, " ")
      use status <- result.try(case status_parts {
        ["HTTP/1.1", code, ..] ->
          int.parse(code)
          |> result.map_error(fn(_) { "Invalid response status" })
        _ -> Error("Unsupported response status line")
      })
      use headers <- result.try(
        list.try_map(header_lines, fn(line) {
          case string.split_once(line, ":") {
            Ok(#(name, value)) if name != "" ->
              case valid_response_header_value(bit_array.from_string(value)) {
                True -> Ok(Header(name, trim_http_ows_start(value)))
                False -> Error("Invalid response header value")
              }
            _ -> Error("Malformed response header")
          }
        }),
      )
      Ok(WireResponse(status, headers, body, ttft_ms))
    }
    _ -> Error("Empty response")
  }
}

// Unicode whitespace is not HTTP optional whitespace. Never erase malformed
// media bytes before a provider validates them. Preserve all non-OWS bytes.
fn trim_http_ows_start(value: String) -> String {
  case value {
    " " <> rest | "\t" <> rest -> trim_http_ows_start(rest)
    _ -> value
  }
}

fn valid_response_header_value(value: BitArray) -> Bool {
  case value {
    <<>> -> True
    <<byte, rest:bytes>> if byte == 9 || { byte >= 32 && byte != 127 } ->
      valid_response_header_value(rest)
    _ -> False
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [path, "--sample", root, id, "--endpoint", endpoint] ->
      run(path, root, id, endpoint)
    ["run", path, root, id, endpoint] | [path, root, id, endpoint] ->
      run(path, root, id, endpoint)
    _ ->
      Error(
        "Usage: replay [run] <persona.toml> <corpus-root> <capture-id> <explicit-endpoint> | <persona.toml> --sample <corpus-root> <capture-id> --endpoint <explicit-endpoint>",
      )
  }
}

fn run(
  path: String,
  root: String,
  id: String,
  endpoint: String,
) -> Result(String, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { "Cannot read persona: " <> path }),
  )
  use profile <- result.try(persona.parse(text))
  use capture <- result.try(corpus.load(root, id))
  use materialized <- result.try(materialize(profile, capture))
  use response <- result.try(send(endpoint, materialized))
  Ok(
    "HTTP "
    <> int.to_string(response.status)
    <> " (TTFT "
    <> int.to_string(response.ttft_ms)
    <> " ms)",
  )
}
