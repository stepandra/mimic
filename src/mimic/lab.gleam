import gleam/int
import gleam/list
import gleam/string
import mimic/types.{type Header, Header}

/// Synthetic oracle configuration. Required values are compared literally; names
/// are case-insensitive, while the observation retains their original spelling.
pub type Config {
  Config(
    required_headers: List(Header),
    failure_status: Int,
    status: Int,
    response_body: String,
    sse_events: List(String),
  )
}

pub type Observed {
  Observed(
    method: String,
    target: String,
    version: String,
    headers: List(Header),
    body: String,
  )
}

pub fn default_config() -> Config {
  Config([], 400, 200, "{\"ok\":true}", [])
}

/// Binds IPv4 loopback only. Port 0 allocates a free ephemeral port.
pub fn start(port: Int) -> Result(Int, String) {
  start_with(port, default_config())
}

pub fn start_with(port: Int, config: Config) -> Result(Int, String) {
  case port >= 0 && port <= 65_535 {
    True -> socket_start(port, fn(raw) { respond(raw, config) })
    False -> Error("port must be between 0 and 65535")
  }
}

pub fn stop(port: Int) -> Result(Nil, String) {
  socket_stop(port)
}

/// Latest observation is in memory only. Credential-like header values are
/// replaced with [REDACTED] before retention.
pub fn last(port: Int) -> Result(Observed, String) {
  socket_last(port)
}

/// Up to 32 recent frames, in memory. Sensitive header values are redacted.
pub fn requests(port: Int) -> Result(List(String), String) {
  socket_requests(port)
}

pub fn count(port: Int) -> Result(Int, String) {
  socket_count(port)
}

/// Raw loopback probe, useful for asserting header fidelity in local tests.
pub fn probe(port: Int, request: String) -> Result(String, String) {
  socket_probe(port, request)
}

pub fn respond(
  raw: String,
  config: Config,
) -> #(String, Observed, Int, String) {
  case parse(raw) {
    Error(reason) -> {
      let observed = Observed("", "", "", [], "")
      #(render(400, "text/plain", reason, []), observed, 0, "")
    }
    Ok(observed) -> {
      let valid =
        list.all(config.required_headers, fn(required) {
          let Header(name: required_name, value: required_value) = required
          list.any(observed.headers, fn(header) {
            let Header(name, value) = header
            string.lowercase(name) == string.lowercase(required_name)
            && value == required_value
          })
        })
      let #(status, content_type, body, events) = case valid {
        False -> #(
          config.failure_status,
          "application/json",
          "{\"error\":\"required header missing or invalid\"}",
          [],
        )
        True ->
          case config.sse_events {
            [] -> #(config.status, "application/json", config.response_body, [])
            events -> #(
              config.status,
              "text/event-stream",
              string.join(
                list.map(events, fn(event) { "data: " <> event <> "\n\n" }),
                "",
              ),
              events,
            )
          }
      }
      #(
        render(status, content_type, body, events),
        redact(observed),
        list.length(events),
        redacted_frame(observed),
      )
    }
  }
}

fn redacted_frame(observed: Observed) -> String {
  let safe = redact(observed)
  safe.method
  <> " "
  <> safe.target
  <> " "
  <> safe.version
  <> "\r\n"
  <> string.join(
    list.map(safe.headers, fn(header) {
      let Header(name, value) = header
      name <> ": " <> value <> "\r\n"
    }),
    "",
  )
  <> "\r\n"
  <> safe.body
}

pub fn parse(raw: String) -> Result(Observed, String) {
  case string.split_once(raw, "\r\n\r\n") {
    Error(_) -> Error("malformed HTTP/1.1 request")
    Ok(#(head, body)) -> {
      case string.split(head, "\r\n") {
        [] -> Error("missing request line")
        [request_line, ..header_lines] -> {
          case string.split(request_line, " ") {
            [method, target, "HTTP/1.1"] -> {
              use headers <- result_map(parse_headers(header_lines))
              Ok(Observed(method, target, "HTTP/1.1", headers, body))
            }
            _ -> Error("only HTTP/1.1 is supported")
          }
        }
      }
    }
  }
}

fn parse_headers(lines: List(String)) -> Result(List(Header), String) {
  case lines {
    [] -> Ok([])
    [line, ..rest] -> {
      case string.split_once(line, ":") {
        Ok(#(name, value)) if name != "" -> {
          use headers <- result_map(parse_headers(rest))
          Ok([Header(name, string.trim(value)), ..headers])
        }
        _ -> Error("malformed header")
      }
    }
  }
}

fn result_map(
  value: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case value {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}

fn redact(observed: Observed) -> Observed {
  let headers =
    list.map(observed.headers, fn(header) {
      let Header(name, value) = header
      let lower = string.lowercase(name)
      case
        string.contains(lower, "key")
        || string.contains(lower, "token")
        || string.contains(lower, "secret")
        || list.contains(
          ["authorization", "proxy-authorization", "cookie", "set-cookie"],
          lower,
        )
      {
        True -> Header(name, "[REDACTED]")
        False -> Header(name, value)
      }
    })
  Observed(..observed, headers: headers)
}

fn render(
  status: Int,
  content_type: String,
  body: String,
  events: List(String),
) -> String {
  let reason = case status {
    200 -> "OK"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    422 -> "Unprocessable Entity"
    429 -> "Too Many Requests"
    500 -> "Internal Server Error"
    _ -> "Response"
  }
  let extra = case events {
    [] -> ""
    _ -> "Cache-Control: no-cache\r\n"
  }
  "HTTP/1.1 "
  <> int.to_string(status)
  <> " "
  <> reason
  <> "\r\nContent-Type: "
  <> content_type
  <> "\r\nContent-Length: "
  <> int.to_string(byte_length(body))
  <> "\r\nConnection: close\r\n"
  <> extra
  <> "\r\n"
  <> body
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] -> run_server(4001)
    [port] ->
      case int.parse(port) {
        Ok(number) -> run_server(number)
        Error(_) -> Error("usage: lab [port]")
      }
    _ -> Error("usage: lab [port]")
  }
}

fn run_server(port: Int) -> Result(String, String) {
  case start(port) {
    Ok(bound) -> {
      wait_forever()
      Ok("lab stopped on 127.0.0.1:" <> int.to_string(bound))
    }
    Error(error) -> Error(error)
  }
}

@external(erlang, "mimic_lab_ffi", "start")
fn socket_start(
  port: Int,
  handler: fn(String) -> #(String, Observed, Int, String),
) -> Result(Int, String)

@external(erlang, "mimic_lab_ffi", "stop")
fn socket_stop(port: Int) -> Result(Nil, String)

@external(erlang, "mimic_lab_ffi", "last")
fn socket_last(port: Int) -> Result(Observed, String)

@external(erlang, "mimic_lab_ffi", "requests")
fn socket_requests(port: Int) -> Result(List(String), String)

@external(erlang, "mimic_lab_ffi", "count")
fn socket_count(port: Int) -> Result(Int, String)

@external(erlang, "mimic_lab_ffi", "probe")
fn socket_probe(port: Int, request: String) -> Result(String, String)

@external(erlang, "mimic_lab_ffi", "byte_length")
fn byte_length(value: String) -> Int

@external(erlang, "mimic_lab_ffi", "wait_forever")
fn wait_forever() -> Nil
