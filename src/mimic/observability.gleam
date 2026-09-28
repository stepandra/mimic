import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/string
import mimic/types.{type Header, Header}

/// Secret values are held in memory only. Register tokens on load/refresh and
/// before logging or serialising any information derived from them.
pub type Redactor {
  Redactor(values: List(String))
}

pub fn new() -> Redactor {
  Redactor([])
}

pub fn register(redactor: Redactor, value: String) -> Redactor {
  case value == "" || list.contains(redactor.values, value) {
    True -> redactor
    False -> Redactor([value, ..redactor.values])
  }
}

pub fn register_all(redactor: Redactor, values: List(String)) -> Redactor {
  list.fold(values, redactor, register)
}

/// Header names are case-insensitive. Retain ordering, duplicate names and
/// original spelling but never retain values for sensitive headers.
pub fn headers(redactor: Redactor, input: List(Header)) -> List(Header) {
  list.map(input, fn(header) {
    let Header(name, value) = header
    Header(text(redactor, name), case sensitive(name) {
      True -> "[REDACTED]"
      False -> text(redactor, value)
    })
  })
}

pub fn sensitive(name: String) -> Bool {
  let name = string.lowercase(name)
  list.contains(
    [
      "authorization", "proxy-authorization", "x-api-key", "api-key",
      "x-auth-token", "x-access-token", "cookie", "set-cookie", "x-goog-api-key",
      "x-anthropic-api-key", "x-amz-security-token", "x-authorization",
      "client-secret", "access-token", "refresh-token", "id-token", "password",
      "secret", "token", "api_key", "access_token", "refresh_token",
      "client_secret", "private_key", "credential", "apikey", "accesstoken",
      "refreshtoken", "clientsecret", "privatekey", "sessiontoken",
    ],
    name,
  )
}

pub fn text(redactor: Redactor, input: String) -> String {
  list.fold(redactor.values, input, fn(acc, secret) {
    string.replace(acc, secret, "[REDACTED]")
  })
}

/// Parses the full JSON tree, redacting sensitive property names at any depth
/// and registered values within arbitrary strings. Invalid JSON fails closed.
pub fn json_body(redactor: Redactor, input: String) -> Result(String, String) {
  case json.parse(input, decode.dynamic) {
    Ok(value) -> Ok(json.to_string(redact_value(redactor, value)))
    Error(_) -> Error("invalid JSON")
  }
}

fn redact_value(redactor: Redactor, value: Dynamic) -> Json {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(object) ->
      object
      |> dict.to_list
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(text(redactor, key), case sensitive(key) {
          True -> json.string("[REDACTED]")
          False -> redact_value(redactor, value)
        })
      })
      |> json.object
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) ->
          json.array(items, fn(item) { redact_value(redactor, item) })
        Error(_) -> redact_scalar(redactor, value)
      }
  }
}

fn redact_scalar(redactor: Redactor, value: Dynamic) -> Json {
  case decode.run(value, decode.string) {
    Ok(value) -> json.string(text(redactor, value))
    Error(_) ->
      case decode.run(value, decode.int) {
        Ok(value) -> json.int(value)
        Error(_) ->
          case decode.run(value, decode.float) {
            Ok(value) -> json.float(value)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(value) -> json.bool(value)
                Error(_) -> json.null()
              }
          }
      }
  }
}

/// Logs only explicit structured fields; request/response bodies are not
/// implicitly captured. Callers must register known secrets before emission.
pub fn log(
  redactor: Redactor,
  event: String,
  fields: List(#(String, String)),
) -> Nil {
  let fields =
    list.map(fields, fn(field) {
      let #(key, value) = field
      #(
        text(redactor, key),
        json.string(case sensitive(key) {
          True -> "[REDACTED]"
          False -> text(redactor, value)
        }),
      )
    })
  json.object([#("event", json.string(text(redactor, event))), ..fields])
  |> json.to_string
  |> io.println
}

/// Metric label values are hashed at the boundary, never stored or exported
/// verbatim. Only these fixed metric names can enter the registry.
pub type Metric {
  Requests
  Accepted
  Rejected
  QuotaUtilization
  DriftIndex
}

fn metric_name(metric: Metric) -> String {
  case metric {
    Requests -> "mimic_requests_total"
    Accepted -> "mimic_acceptance_accepted_total"
    Rejected -> "mimic_acceptance_rejected_total"
    QuotaUtilization -> "mimic_quota_utilization_milli"
    DriftIndex -> "mimic_drift_index_milli"
  }
}

pub fn increment(metric: Metric, label: String) -> Nil {
  metric_increment(metric_name(metric), opaque_label(label))
}

pub fn gauge(metric: Metric, label: String, value: Int) -> Nil {
  metric_gauge(metric_name(metric), opaque_label(label), value)
}

pub fn metrics() -> String {
  metric_snapshot()
  |> list.map(fn(entry) {
    let #(name, label, value) = entry
    name <> "{id=\"" <> label <> "\"} " <> int_to_string(value)
  })
  |> string.join("\n")
}

@external(erlang, "mimic_observability_ffi", "opaque_label")
fn opaque_label(label: String) -> String

@external(erlang, "mimic_observability_ffi", "increment")
fn metric_increment(name: String, label: String) -> Nil

@external(erlang, "mimic_observability_ffi", "gauge")
fn metric_gauge(name: String, label: String, value: Int) -> Nil

@external(erlang, "mimic_observability_ffi", "snapshot")
fn metric_snapshot() -> List(#(String, String, Int))

@external(erlang, "mimic_observability_ffi", "integer_to_string")
fn int_to_string(value: Int) -> String

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["metrics"] -> Ok(metrics())
    ["redact", value] -> json_body(new(), value)
    _ -> Error("usage: mimic obs metrics | redact <json>")
  }
}
