/// Public non-duplex WS destination policy, not executor transparency.
/// CPA acdace936: websocket_forward, websocket_timeline and client_error.
/// Only validated canonical JSON error envelopes enter this boundary. No
/// credential ownership, quota observation, logging, retry or raw diagnostics.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir

pub type Action {
  Suppressed
  RequestFault(data: String)
  TransportClose(code: Int, reason: String)
}

/// Source's payload wrapper has no IsTerminalAuth interface. A raw JSON flag
/// never manufactures that trusted exception. Preserve classified request
/// fault data only; credential echoes and unsupported error shapes suppress.
pub fn classify(
  document: ir.Value,
  data: String,
  continuing: Bool,
  secrets: List(String),
) -> Action {
  case ir.field(document, "type"), ir.field(document, "error") {
    Some(ir.String("error")), Some(ir.Object(_) as error) -> {
      case ir.string_field(error, "message") {
        Ok(message) if message != "" -> {
          let status = status(document)
          let too_big =
            status == 413
            && ir.field(error, "code") == Some(ir.String("message_too_big"))
          case echoes(document, secrets) || !canonical(error) {
            True -> Suppressed
            False if continuing && { status == 401 || status == 429 } ->
              TransportClose(1012, "upstream requires HTTP replay")
            False if too_big -> {
              let reason = case string.trim(message) {
                "" -> "message too big"
                value -> value
              }
              TransportClose(1009, reason_prefix(reason, 123))
            }
            False ->
              case request_fault(document, status, data) {
                True -> RequestFault(data)
                False -> Suppressed
              }
          }
        }
        _ -> Suppressed
      }
    }
    _, _ -> Suppressed
  }
}

/// Timeline payload errors read top-level status, then status_code, then 500.
/// Integer/string integer statuses are supported; no numeric truthiness.
fn status(document: ir.Value) -> Int {
  case positive_status(ir.field(document, "status")) {
    Some(status) -> status
    None ->
      positive_status(ir.field(document, "status_code"))
      |> option.unwrap(500)
  }
}

fn positive_status(value) {
  let decoded = case value {
    Some(ir.Integer(value)) -> Ok(value)
    Some(ir.String(value)) -> int.parse(value)
    _ -> Error(Nil)
  }
  case decoded {
    Ok(value) if value > 0 && value <= 599 -> Some(value)
    _ -> None
  }
}

fn canonical(error: ir.Value) -> Bool {
  list.all(["type", "code", "param"], fn(name) {
    case ir.field(error, name) {
      None | Some(ir.Null) | Some(ir.String(_)) -> True
      _ -> False
    }
  })
}

fn at(document: ir.Value, path: List(String)) {
  case path {
    [] -> Some(document)
    [key, ..rest] ->
      case ir.field(document, key) {
        None -> None
        Some(value) -> at(value, rest)
      }
  }
}

fn identifiers(document: ir.Value, field: String) -> List(String) {
  [
    ["error", field],
    [field],
    ["response", "error", field],
    ["body", "error", field],
  ]
  |> list.filter_map(fn(path) {
    case at(document, path) {
      Some(ir.String(value)) -> Ok(string.lowercase(string.trim(value)))
      _ -> Error(Nil)
    }
  })
}

fn request_fault(document: ir.Value, status: Int, data: String) -> Bool {
  let types = identifiers(document, "type")
  let codes = identifiers(document, "code")
  case
    status == 402
    || status == 429
    || { status == 401 && list.contains(types, "authentication_error") }
    || list.any(codes, fn(code) {
      code == "model_not_found" || code == "model_not_found_error"
    })
  {
    True -> False
    False ->
      list.any(codes, fn(code) {
        list.contains(
          [
            "cyber_policy", "context_length_exceeded", "message_too_big",
            "string_above_max_length", "invalid_prompt", "invalid_value",
            "unsupported_value", "invalid_request_error",
            "previous_response_not_found",
          ],
          code,
        )
      })
      || list.any(types, fn(kind) {
        list.contains(
          [
            "invalid_request", "invalid_request_error", "bad_request_error",
            "invalid_prompt",
          ],
          kind,
        )
      })
      || item_not_persisted(data)
      || list.contains([400, 409, 413, 422], status)
  }
}

fn item_not_persisted(data: String) -> Bool {
  let lower = string.lowercase(data)
  string.contains(lower, "item with id")
  && string.contains(lower, "not found")
  && string.contains(
    lower,
    "items are not persisted when `store` is set to false",
  )
}

/// Deliberate stricter local boundary: never reflect decoded credential values
/// (including JSON-escaped object keys/strings) or credential-bearing fields.
fn echoes(value: ir.Value, secrets: List(String)) -> Bool {
  case value {
    ir.String(value) ->
      list.any(secrets, fn(secret) {
        secret != "" && string.contains(value, secret)
      })
    ir.Array(values) -> list.any(values, fn(value) { echoes(value, secrets) })
    ir.Object(fields) ->
      list.any(fields, fn(field) {
        list.contains(
          ["authorization", "access_token", "refresh_token", "api_key"],
          string.lowercase(field.0),
        )
        || echoes(ir.String(field.0), secrets)
        || echoes(field.1, secrets)
      })
    _ -> False
  }
}

fn reason_prefix(value: String, bytes: Int) -> String {
  prefix(bit_array.from_string(value), bytes, <<>>)
  |> bit_array.to_string
  |> result.unwrap("")
}

fn prefix(value: BitArray, bytes: Int, kept: BitArray) -> BitArray {
  case value {
    <<char:utf8_codepoint, rest:bits>> -> {
      let encoded = <<char:utf8_codepoint>>
      let size = bit_array.byte_size(encoded)
      case size <= bytes {
        True -> prefix(rest, bytes - size, <<kept:bits, encoded:bits>>)
        False -> kept
      }
    }
    _ -> kept
  }
}
