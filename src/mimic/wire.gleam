import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import mimic/types.{type Capture, type Header, Header, Transport}

/// Parse a complete, unencoded HTTP/1.1 request. The caller supplies provenance;
/// this parser never invents a transport fingerprint.
pub fn parse_request(
  raw: String,
  client: String,
  version: String,
  endpoint: String,
  request_kind: String,
) -> Result(Capture, String) {
  use parts <- result.try(
    string.split_once(raw, on: "\r\n\r\n")
    |> result.replace_error("Incomplete HTTP/1.1 header block"),
  )
  let #(head, body) = parts
  let lines = string.split(head, on: "\r\n")
  use request_line <- result.try(
    list.first(lines) |> result.replace_error("Missing request line"),
  )
  use parsed <- result.try(parse_line(request_line))
  let #(method, target, http_version) = parsed
  use headers <- result.try(list.drop(lines, 1) |> list.try_map(parse_header))
  use _ <- result.try(validate_body(headers, body))
  Ok(types.Capture(
    client: client,
    version: version,
    endpoint: endpoint,
    request_kind: request_kind,
    method: method,
    target: target,
    http_version: http_version,
    headers: headers,
    body: body,
    transport: Transport(alpn: "http/1.1", ja4: None),
  ))
}

fn parse_line(line: String) -> Result(#(String, String, String), String) {
  case string.split(line, on: " ") {
    [method, target, "HTTP/1.1"] -> {
      case
        method != ""
        && target != ""
        && !string.contains(method, "\t")
        && !string.contains(method, "\r")
        && !string.contains(method, "\n")
        && !string.contains(target, "\r")
        && !string.contains(target, "\n")
      {
        True -> Ok(#(method, target, "HTTP/1.1"))
        False -> Error("Invalid HTTP/1.1 request line")
      }
    }
    _ -> Error("Only HTTP/1.1 request lines are supported")
  }
}

fn parse_header(line: String) -> Result(Header, String) {
  use pair <- result.try(
    string.split_once(line, on: ":")
    |> result.replace_error("Malformed HTTP header"),
  )
  let #(name, value) = pair
  case
    valid_name(name)
    && !string.contains(value, "\r")
    && !string.contains(value, "\n")
  {
    True -> Ok(Header(name, string.trim_start(value)))
    False -> Error("Unsafe HTTP header")
  }
}

fn valid_name(name: String) -> Bool {
  name != ""
  && !string.contains(name, " ")
  && !string.contains(name, "\t")
  && !string.contains(name, "\r")
  && !string.contains(name, "\n")
  && !string.contains(name, ":")
}

fn header_values(headers: List(Header), name: String) -> List(String) {
  headers
  |> list.filter_map(fn(h) {
    let Header(n, value) = h
    case string.lowercase(n) == name {
      True -> Ok(value)
      False -> Error(Nil)
    }
  })
}

fn validate_body(headers: List(Header), body: String) -> Result(Nil, String) {
  let encodings = header_values(headers, "content-encoding")
  let transfers = header_values(headers, "transfer-encoding")
  let lengths = header_values(headers, "content-length")
  let contents = header_values(headers, "content-type")
  case encodings, transfers, lengths {
    [], [], [] if body == "" -> validate_content_type(contents, body)
    [], [], [length] -> {
      use expected <- result.try(
        int.parse(length) |> result.replace_error("Invalid Content-Length"),
      )
      case expected == bit_array.byte_size(bit_array.from_string(body)) {
        True -> validate_content_type(contents, body)
        False -> Error("Content-Length mismatch")
      }
    }
    [], [], [] -> Error("Body requires Content-Length")
    _, _, _ -> Error("Unsupported transfer or content encoding/framing")
  }
}

fn validate_content_type(
  contents: List(String),
  body: String,
) -> Result(Nil, String) {
  case body, contents {
    "", _ -> Ok(Nil)
    _, [content] -> {
      use _ <- result.try(content_type_media(content))
      Ok(Nil)
    }
    _, _ -> Error("Nonempty body requires one JSON or SSE Content-Type")
  }
}

/// The same media rule is used by the wire validator and corpus sanitizer.
/// Strip only supported charset parameters, preserving the media subtype.
pub fn content_type_media(value: String) -> Result(String, String) {
  let parts =
    string.lowercase(value)
    |> string.split(on: ";")
    |> list.map(string.trim)
  let media = list.first(parts) |> result.unwrap("")
  let parameters = list.drop(parts, 1)
  let json_media =
    media == "application/json"
    || {
      string.starts_with(media, "application/")
      && string.ends_with(media, "+json")
      && string.length(media) > string.length("application/+json")
      && string.length(media) <= 128
      && list.all(string.to_graphemes(media), fn(c) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-", c)
        || c == "/"
      })
    }
  case
    { json_media || media == "text/event-stream" }
    && list.all(parameters, fn(param) { param == "charset=utf-8" })
  {
    True -> Ok(media)
    False -> Error("Only UTF-8 JSON or SSE bodies are supported")
  }
}

/// Render an ordered HTTP/1.1 request; reject stale lengths and unsafe framing.
pub fn render_request(capture: Capture) -> Result(String, String) {
  let types.Capture(
    method: method,
    target: target,
    http_version: version,
    headers: headers,
    body: body,
    transport: transport,
    ..,
  ) = capture
  let Transport(alpn: alpn, ..) = transport
  case parse_line(method <> " " <> target <> " " <> version) {
    Ok(_) if alpn == "http/1.1" || alpn == "none" -> {
      use _ <- result.try(
        list.try_map(headers, fn(h) {
          let Header(name, value) = h
          case
            valid_name(name)
            && !string.contains(value, "\r")
            && !string.contains(value, "\n")
          {
            True -> Ok(Nil)
            False -> Error("Unsafe HTTP header")
          }
        }),
      )
      use _ <- result.try(validate_body(headers, body))
      let header_block =
        headers
        |> list.map(fn(h) {
          let Header(name, value) = h
          name <> ": " <> value
        })
        |> string.join(with: "\r\n")
      let prefix = method <> " " <> target <> " HTTP/1.1\r\n"
      case header_block {
        "" -> Ok(prefix <> "\r\n" <> body)
        _ -> Ok(prefix <> header_block <> "\r\n\r\n" <> body)
      }
    }
    _ -> Error("Only HTTP/1.1 transport is supported")
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["parse", raw, client, version, endpoint, kind] -> {
      use capture <- result.try(parse_request(
        raw,
        client,
        version,
        endpoint,
        kind,
      ))
      render_request(capture)
    }
    _ -> Error("Usage: wire parse <raw> <client> <version> <endpoint> <kind>")
  }
}
