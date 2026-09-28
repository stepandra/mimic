import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import mimic/types.{type Capture, type Header, Header, Transport}
import mimic/wire

@external(erlang, "mimic_corpus_ffi", "blake3")
fn blake3(data: String) -> Result(String, String)

@external(erlang, "mimic_corpus_ffi", "compress")
fn compress(data: String) -> Result(BitArray, String)

@external(erlang, "mimic_corpus_ffi", "decompress")
fn decompress(data: BitArray) -> Result(String, String)

@external(erlang, "mimic_corpus_ffi", "store")
fn store(root: String, id: String, data: BitArray) -> Result(Nil, String)

@external(erlang, "mimic_corpus_ffi", "read")
fn read(root: String, id: String) -> Result(BitArray, String)

@external(erlang, "mimic_corpus_ffi", "ids")
fn ids(root: String) -> Result(List(String), String)

@external(erlang, "mimic_corpus_ffi", "remove_older_than")
fn remove_older_than(root: String, days: Int) -> Result(Int, String)

/// Versioned, deliberately lossless serialization. This is not the redaction
/// boundary: use add for any persistent capture.
pub fn encode(capture: Capture) -> String {
  let types.Capture(
    client: client,
    version: version,
    endpoint: endpoint,
    request_kind: request_kind,
    method: method,
    target: target,
    http_version: http_version,
    headers: headers,
    body: body,
    transport: Transport(alpn: alpn, ja4: ja4),
  ) = capture
  json.object([
    #("schema", json.int(1)),
    #("client", json.string(client)),
    #("version", json.string(version)),
    #("endpoint", json.string(endpoint)),
    #("request_kind", json.string(request_kind)),
    #("method", json.string(method)),
    #("target", json.string(target)),
    #("http_version", json.string(http_version)),
    #(
      "headers",
      json.array(headers, fn(header) {
        let Header(name, value) = header
        json.object([
          #("name", json.string(name)),
          #("value", json.string(value)),
        ])
      }),
    ),
    #("body", json.string(body)),
    #(
      "transport",
      json.object([
        #("alpn", json.string(alpn)),
        #("ja4", json.nullable(ja4, json.string)),
      ]),
    ),
  ])
  |> json.to_string
}

pub fn decode(raw: String) -> Result(Capture, String) {
  use schema <- result.try(field(raw, "schema", decode.int))
  case schema {
    1 -> decode_v1(raw)
    _ -> Error("Unsupported capture schema")
  }
}

fn field(
  raw: String,
  name: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  json.parse(raw, decode.field(name, decoder, decode.success))
  |> result.map_error(fn(_) { "Invalid capture field: " <> name })
}

fn decode_v1(raw: String) -> Result(Capture, String) {
  use client <- result.try(field(raw, "client", decode.string))
  use version <- result.try(field(raw, "version", decode.string))
  use endpoint <- result.try(field(raw, "endpoint", decode.string))
  use kind <- result.try(field(raw, "request_kind", decode.string))
  use method <- result.try(field(raw, "method", decode.string))
  use target <- result.try(field(raw, "target", decode.string))
  use http_version <- result.try(field(raw, "http_version", decode.string))
  use headers <- result.try(field(
    raw,
    "headers",
    decode.list({
      use name <- decode.field("name", decode.string)
      use value <- decode.field("value", decode.string)
      decode.success(Header(name, value))
    }),
  ))
  use body <- result.try(field(raw, "body", decode.string))
  use alpn <- result.try(field(
    raw,
    "transport",
    decode.field("alpn", decode.string, decode.success),
  ))
  use ja4 <- result.try(field(
    raw,
    "transport",
    decode.field("ja4", decode.optional(decode.string), decode.success),
  ))
  let capture =
    types.Capture(
      client: client,
      version: version,
      endpoint: endpoint,
      request_kind: kind,
      method: method,
      target: target,
      http_version: http_version,
      headers: headers,
      body: body,
      transport: Transport(alpn: alpn, ja4: ja4),
    )
  use _ <- result.try(wire.render_request(capture))
  Ok(capture)
}

/// Allow only known wire-profile values; all other header values may contain
/// credentials or account identifiers. Never persist raw request bodies.
fn safe_header(header: Header, endpoint: String) -> Header {
  let Header(name, value) = header
  let lower = string.lowercase(name)
  case lower {
    "host" ->
      case safe_host(value, endpoint) {
        True -> header
        False -> Header(name, "[REDACTED]")
      }
    "content-type" -> {
      case wire.content_type_media(value) {
        Ok(mime) -> Header(name, mime)
        Error(_) -> Header(name, "[REDACTED]")
      }
    }
    "accept" ->
      case
        list.contains(["application/json", "text/event-stream", "*/*"], value)
      {
        True -> header
        False -> Header(name, "[REDACTED]")
      }
    "anthropic-version" ->
      case date(value) {
        True -> header
        False -> Header(name, "[REDACTED]")
      }
    "anthropic-beta" -> {
      let betas = string.split(value, on: ",") |> list.map(string.trim)
      case
        list.all(betas, fn(beta) {
          let date_part = string.slice(beta, at_index: -10, length: 10)
          let prefix = string.drop_end(beta, 10)
          string.length(prefix) <= 64
          && string.length(prefix) > 1
          && string.ends_with(prefix, "-")
          && date(date_part)
          && safe_chars(prefix, "abcdefghijklmnopqrstuvwxyz0123456789-")
        })
      {
        True -> header
        False -> Header(name, "[REDACTED]")
      }
    }
    "content-length" -> header
    _ -> Header(name, "[REDACTED]")
  }
}

/// The endpoint authority is already retained as operator-supplied metadata.
/// Its matching Host header can remain structural; an unrelated Host value
/// must not be inferred safe.
fn safe_host(value: String, endpoint: String) -> Bool {
  let authority = case string.split_once(endpoint, on: "://") {
    Ok(#(_, rest)) -> rest
    Error(_) -> endpoint
  }
  let authority =
    authority
    |> string.split(on: "/")
    |> list.first
    |> result.unwrap("")
    |> string.split(on: "?")
    |> list.first
    |> result.unwrap("")
  value != ""
  && string.length(value) <= 253
  && string.lowercase(value) == string.lowercase(authority)
  && safe_chars(
    value,
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-[]",
  )
}

fn safe_chars(value: String, allowed: String) -> Bool {
  list.all(string.to_graphemes(value), fn(character) {
    string.contains(allowed, character)
  })
}

fn date(value: String) -> Bool {
  string.length(value) == 10
  && string.slice(value, at_index: 4, length: 1) == "-"
  && string.slice(value, at_index: 7, length: 1) == "-"
  && safe_chars(string.replace(value, "-", ""), "0123456789")
}

fn safe_structural_string(key: String, value: String) -> Bool {
  case key {
    "model" ->
      string.length(value) > 0
      && string.length(value) <= 128
      && {
        string.starts_with(value, "claude-")
        || string.starts_with(value, "gpt-")
        || string.starts_with(value, "gemini-")
        || string.starts_with(value, "o1")
        || string.starts_with(value, "o3")
      }
      && safe_chars(
        value,
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/",
      )
    "role" ->
      list.contains(["user", "assistant", "system", "developer", "tool"], value)
    "type" ->
      list.contains(
        [
          "message",
          "text",
          "tool_use",
          "tool_result",
          "thinking",
          "redacted_thinking",
          "image",
          "document",
          "input_json_delta",
          "text_delta",
          "message_start",
          "message_delta",
          "message_stop",
          "content_block_start",
          "content_block_delta",
          "content_block_stop",
        ],
        value,
      )
    "stop_reason" ->
      list.contains(
        ["end_turn", "max_tokens", "stop_sequence", "tool_use"],
        value,
      )
    _ -> False
  }
}

fn safe_number(key: String) -> Bool {
  list.contains(["max_tokens", "temperature", "top_p", "top_k"], key)
}

/// JSON keys can themselves be credentials (for example, tool input maps
/// keyed by API token). Preserve only known protocol field names. Unknown
/// fields fail explicitly rather than replacing multiple keys with one name
/// or silently overwriting a property.
fn safe_json_key(key: String) -> Bool {
  list.contains(
    [
      "model", "max_tokens", "temperature", "top_p", "top_k", "messages",
      "system", "tools", "tool_choice", "role", "content", "type", "text",
      "input", "input_schema", "name", "description", "required", "properties",
      "items", "additionalProperties", "stream", "stop_sequences", "thinking",
      "budget_tokens", "cache_control", "ttl", "tool_use_id", "id", "metadata",
      "user_id", "output_config", "format", "schema",
    ],
    key,
  )
}

fn redact_json_value(value: Dynamic, key: String) -> Result(json.Json, String) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(object) -> {
      use entries <- result.try(
        dict.to_list(object)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.try_map(fn(entry) {
          let #(key, value) = entry
          use _ <- result.try(case safe_json_key(key) {
            True -> Ok(Nil)
            False -> Error("Unsupported JSON object field name")
          })
          use safe <- result.try(redact_json_value(value, key))
          Ok(#(key, safe))
        }),
      )
      Ok(json.object(entries))
    }
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> {
          use safe <- result.try(
            list.try_map(items, fn(item) { redact_json_value(item, key) }),
          )
          Ok(json.preprocessed_array(safe))
        }
        Error(_) ->
          case decode.run(value, decode.string) {
            Ok(text) ->
              case safe_structural_string(key, text) {
                True -> Ok(json.string(text))
                False -> Ok(json.string("[REDACTED]"))
              }
            Error(_) ->
              case decode.run(value, decode.int) {
                Ok(number) ->
                  case safe_number(key) && number >= 0 && number <= 200_000 {
                    True -> Ok(json.int(number))
                    False -> Ok(json.int(0))
                  }
                Error(_) ->
                  case decode.run(value, decode.float) {
                    Ok(number) ->
                      case
                        safe_number(key)
                        && number >=. 0.0
                        && number <=. 200_000.0
                      {
                        True -> Ok(json.float(number))
                        False -> Ok(json.int(0))
                      }
                    Error(_) ->
                      case decode.run(value, decode.bool) {
                        Ok(boolean) -> Ok(json.bool(boolean))
                        Error(_) ->
                          case
                            decode.run(value, decode.optional(decode.dynamic))
                          {
                            Ok(None) -> Ok(json.null())
                            _ -> Error("Unsupported JSON body value")
                          }
                      }
                  }
              }
          }
      }
  }
}

fn redact_body(body: String, headers: List(Header)) -> Result(String, String) {
  case body {
    "" -> Ok("")
    _ -> {
      let is_json =
        list.any(headers, fn(header) {
          let Header(name, value) = header
          string.lowercase(name) == "content-type"
          && string.contains(string.lowercase(value), "json")
        })
      case is_json {
        False ->
          Error("SSE body persistence is not supported (may contain secrets)")
        True -> {
          use parsed <- result.try(
            json.parse(body, decode.dynamic)
            |> result.map_error(fn(_) { "Invalid JSON body" }),
          )
          use safe <- result.try(redact_json_value(parsed, ""))
          Ok(json.to_string(safe))
        }
      }
    }
  }
}

fn redact_path(path: String) -> String {
  case string.split_once(path, on: "://") {
    Ok(#(scheme, rest)) ->
      case string.split_once(rest, on: "/") {
        Ok(#(host, route)) ->
          scheme <> "://" <> host <> sanitize_route("/" <> route)
        Error(_) -> scheme <> "://" <> rest
      }
    Error(_) ->
      case string.starts_with(path, "/") {
        True -> sanitize_route(path)
        False ->
          case
            list.contains(["local", "lab"], path) || string.contains(path, ".")
          {
            True -> path
            False -> "REDACTED"
          }
      }
  }
}

fn sanitize_route(path: String) -> String {
  path
  |> string.split(on: "/")
  |> list.map(fn(segment) {
    case
      segment == ""
      || list.contains(
        [
          "v1", "v2", "v3", "v4", "v1beta", "beta", "messages", "count_tokens",
          "chat", "completions", "responses", "models", "generateContent",
          "streamGenerateContent",
        ],
        segment,
      )
    {
      True -> segment
      False -> "REDACTED"
    }
  })
  |> string.join(with: "/")
}

fn safe_query_key(key: String) -> String {
  case
    list.contains(
      [
        "token", "access_token", "api_key", "key", "version", "api-version",
        "beta", "stream", "alt", "format",
      ],
      key,
    )
  {
    True -> key
    False -> "redacted"
  }
}

fn redact_target(target: String) -> String {
  case string.split_once(target, on: "?") {
    Ok(#(path, query)) -> {
      let safe =
        query
        |> string.split(on: "&")
        |> list.map(fn(part) {
          case string.split_once(part, on: "=") {
            Ok(#(key, _)) -> safe_query_key(key) <> "=REDACTED"
            Error(_) -> safe_query_key(part) <> "=REDACTED"
          }
        })
        |> string.join(with: "&")
      redact_path(path) <> "?" <> safe
    }
    Error(_) -> redact_path(target)
  }
}

/// A redacted capture remains renderable, including a corrected Content-Length.
pub fn redact(capture: Capture) -> Result(Capture, String) {
  use _ <- result.try(wire.render_request(capture))
  use _ <- result.try(
    case
      string.contains(capture.endpoint, "@")
      || string.contains(capture.target, "@")
      || string.contains(capture.endpoint, "#")
      || string.contains(capture.target, "#")
    {
      True ->
        Error("Userinfo/fragments in URL are unsupported for safe capture")
      False -> Ok(Nil)
    },
  )
  let types.Capture(headers: headers, body: body, ..) = capture
  use safe_body <- result.try(redact_body(body, headers))
  let length =
    bit_array.byte_size(bit_array.from_string(safe_body)) |> int.to_string
  let safe_headers =
    headers
    |> list.map(fn(h) {
      let Header(name, _) = h
      case string.lowercase(name) {
        "content-length" -> Header(name, length)
        _ -> safe_header(h, capture.endpoint)
      }
    })
  let safe =
    types.Capture(
      ..capture,
      endpoint: redact_target(capture.endpoint),
      target: redact_target(capture.target),
      headers: safe_headers,
      body: safe_body,
    )
  use _ <- result.try(wire.render_request(safe))
  Ok(safe)
}

/// The address is BLAKE3 of the redacted, versioned UTF-8 record. zstd is
/// mandatory; neither primitive silently falls back to a different algorithm.
pub fn add(root: String, capture: Capture) -> Result(String, String) {
  use safe <- result.try(redact(capture))
  let raw = encode(safe)
  use id <- result.try(blake3(raw))
  use compressed <- result.try(compress(raw))
  use _ <- result.try(store(root, id, compressed))
  Ok(id)
}

pub fn load(root: String, id: String) -> Result(Capture, String) {
  use compressed <- result.try(read(root, id))
  use raw <- result.try(decompress(compressed))
  use actual <- result.try(blake3(raw))
  case actual == id {
    True -> decode(raw)
    False -> Error("Corpus BLAKE3 mismatch")
  }
}

pub fn list(root: String) -> Result(List(Capture), String) {
  use names <- result.try(ids(root))
  list.try_map(names, fn(id) { load(root, id) })
}

pub fn select(
  root: String,
  client: String,
  version: String,
  endpoint: String,
  kind: String,
) -> Result(List(Capture), String) {
  use captures <- result.try(list(root))
  let endpoint = case endpoint {
    "" -> ""
    _ -> redact_target(endpoint)
  }
  Ok(
    list.filter(captures, fn(c) {
      { client == "" || c.client == client }
      && { version == "" || c.version == version }
      && { endpoint == "" || c.endpoint == endpoint }
      && { kind == "" || c.request_kind == kind }
    }),
  )
}

/// Export a selection as newline-delimited redacted capture JSON.
pub fn export(
  root: String,
  client: String,
  version: String,
  endpoint: String,
  kind: String,
) -> Result(String, String) {
  use captures <- result.try(select(root, client, version, endpoint, kind))
  Ok(captures |> list.map(encode) |> string.join(with: "\n"))
}

pub fn rotate(root: String, older_than_days: Int) -> Result(Int, String) {
  case older_than_days > 0 {
    True -> remove_older_than(root, older_than_days)
    False -> Error("Rotation age must be positive")
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["add", root, capture_json] -> {
      use capture <- result.try(decode(capture_json))
      add(root, capture)
    }
    ["ls", root] -> {
      use captures <- result.try(list(root))
      Ok(
        json.array(captures, fn(c) { json.string(encode(c)) }) |> json.to_string,
      )
    }
    ["load", root, id] -> {
      use capture <- result.try(load(root, id))
      Ok(encode(capture))
    }
    ["select", root, client, version, endpoint, kind] -> {
      use captures <- result.try(select(root, client, version, endpoint, kind))
      Ok(
        json.array(captures, fn(c) { json.string(encode(c)) }) |> json.to_string,
      )
    }
    ["diff-export", root, client, version, endpoint, kind] ->
      export(root, client, version, endpoint, kind)
    ["rotate", root, days] -> {
      use age <- result.try(
        int.parse(days) |> result.replace_error("Invalid rotation age"),
      )
      use count <- result.try(rotate(root, age))
      Ok(int.to_string(count))
    }
    _ ->
      Error(
        "Usage: corpus add <root> <capture-json> | ls <root> | load <root> <id> | select|diff-export <root> <client> <version> <endpoint> <kind> | rotate <root> <days>",
      )
  }
}
