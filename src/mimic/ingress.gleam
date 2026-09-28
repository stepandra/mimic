import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mimic/auth
import mimic/auth/storage
import mimic/dialect.{type Dialect, Anthropic, Gemini, Openai}
import mimic/dialect/anthropic
import mimic/dialect/openai
import mimic/fleet
import mimic/ingress/control
import mimic/ingress/keys
import mimic/persona
import mimic/replay
import mimic/types.{Capture, Header, Transport, WireResponse}
import mimic/workshop
import mist

/// A single operator-configured upstream. This local mode makes no implicit
/// network calls, and is intentionally not a public management endpoint.
pub type Config {
  Config(port: Int, upstream: String, api_key: String, upstream_key: String)
}

/// Opaque socket handle returned by the Erlang transport boundary.
pub type Upstream

type StreamMessage {
  NextChunk
}

type StreamState {
  StreamState(
    upstream: Upstream,
    subject: process.Subject(StreamMessage),
    stream: dialect.Stream,
    pending_utf8: BitArray,
    managed: Option(#(control.Controller, fleet.Selection)),
  )
}

type Managed {
  Managed(
    state_dir: String,
    provider: String,
    credential_id: String,
    controller: control.Controller,
  )
}

pub fn start(
  port: Int,
  upstream: String,
  api_key: String,
  upstream_key: String,
) -> Result(Int, String) {
  start_with(Config(port, upstream, api_key, upstream_key))
}

/// Mist binds IPv4 loopback. Port 0 returns the actual selected port.
pub fn start_with(config: Config) -> Result(Int, String) {
  start_as(config, Anthropic)
}

/// Select the actual upstream dialect explicitly; the default is Anthropic.
pub fn start_as(
  config: Config,
  upstream_dialect: Dialect,
) -> Result(Int, String) {
  case upstream_dialect {
    Gemini -> Error("Gemini ingress dialect is unsupported")
    _ -> start_context(config, upstream_dialect, None)
  }
}

/// Gated persona, client-key registry, auth store, fleet and quota mode.
/// Fleet currently supports only explicit local-loopback upstream profiles.
pub fn start_managed(
  port: Int,
  upstream: String,
  state_dir: String,
  provider: String,
  credential_id: String,
  upstream_dialect: Dialect,
) -> Result(Int, String) {
  use _ <- result_map(case upstream_dialect {
    Gemini -> Error("Gemini ingress dialect is unsupported")
    _ -> Ok(Nil)
  })
  let config = Config(port, upstream, "__registry__", "__auth_store__")
  use store <- result_map(storage.new(state_dir))
  use _ <- result_map(workshop.pointer(state_dir, provider))
  use controller <- result_map(control.start(
    fleet.Profile(credential_id, upstream, fleet.LocalLoopback, 64),
    store,
  ))
  start_context(
    config,
    upstream_dialect,
    Some(Managed(state_dir, provider, credential_id, controller)),
  )
}

fn start_context(
  config: Config,
  upstream_dialect: Dialect,
  managed: Option(Managed),
) -> Result(Int, String) {
  case valid(config) {
    Error(error) -> Error(error)
    Ok(_) -> {
      let subject = process.new_subject()
      let builder =
        mist.new(fn(request) {
          handle(request, config, upstream_dialect, managed)
        })
        |> mist.port(config.port)
        |> mist.bind("127.0.0.1")
        |> mist.after_start(fn(port, _, _) { process.send(subject, port) })
      case mist.start(builder) {
        Ok(started) ->
          case process.receive(subject, 5000) {
            Ok(port) -> {
              process.unlink(started.pid)
              register_server(port, started.pid)
              Ok(port)
            }
            Error(_) -> Error("mist started but port was not reported")
          }
        Error(_) -> Error("mist failed to bind loopback listener")
      }
    }
  }
}

pub fn stop(port: Int) -> Result(Nil, String) {
  stop_server(port)
}

fn valid(config: Config) -> Result(Nil, String) {
  case config.port >= 0 && config.port <= 65_535 {
    False -> Error("port must be between 0 and 65535")
    True ->
      case config.api_key == "" || config.upstream_key == "" {
        True -> Error("both client and upstream API keys must be configured")
        False ->
          case valid_origin(config.upstream) {
            True -> Ok(Nil)
            False ->
              Error(
                "upstream must be an explicit http(s) origin without path or credentials",
              )
          }
      }
  }
}

@external(erlang, "mimic_ingress_ffi", "valid_origin")
fn valid_origin(origin: String) -> Bool

@external(erlang, "mimic_ingress_ffi", "host_header")
fn host_header(origin: String) -> Result(String, String)

fn handle(
  req: Request(mist.Connection),
  config: Config,
  target_dialect: Dialect,
  managed: Option(Managed),
) -> Response(mist.ResponseData) {
  case authenticated(req, config.api_key, managed) {
    False -> reject(401, "unauthorized")
    True ->
      case allowed(req) {
        False -> reject(404, "unsupported endpoint")
        True ->
          case request_body(req) {
            Error(error) -> reject(400, error)
            Ok(body) -> {
              let source_dialect = case req.path {
                "/v1/messages" -> Anthropic
                _ -> Openai
              }
              case translate_request(source_dialect, target_dialect, body) {
                Error(_) -> reject(422, "unsupported dialect request")
                Ok(forward_body) ->
                  case managed {
                    None ->
                      forward(
                        req,
                        config,
                        source_dialect,
                        target_dialect,
                        forward_body,
                      )
                    Some(context) ->
                      managed_forward(
                        req,
                        config,
                        context,
                        source_dialect,
                        target_dialect,
                        forward_body,
                      )
                  }
              }
            }
          }
      }
  }
}

fn managed_forward(
  req: Request(mist.Connection),
  config: Config,
  managed: Managed,
  source_dialect: Dialect,
  target_dialect: Dialect,
  body: BitArray,
) -> Response(mist.ResponseData) {
  case prepare_managed(req, config, managed, target_dialect, body) {
    Error(_) -> reject(503, "managed profile or credential unavailable")
    Ok(#(target, method, headers, prepared_body)) -> {
      let session_id = case request_header(req, "x-client-request-id") {
        Ok(value) if value != "" -> value
        _ -> new_session_id()
      }
      case control.acquire(managed.controller, session_id, now_ms()) {
        Error(_) -> reject(503, "fleet profile unavailable or cooling down")
        Ok(selection) ->
          case
            upstream_open_preserve(
              selection.profile.upstream_url,
              target,
              method,
              headers,
              prepared_body,
            )
          {
            Error(_) -> {
              control.release(managed.controller, selection)
              reject(502, "managed upstream connection failed")
            }
            Ok(#(status, upstream_headers, upstream)) -> {
              let wire_headers =
                list.map(upstream_headers, fn(pair) { Header(pair.0, pair.1) })
              case
                control.observe(
                  managed.controller,
                  selection,
                  WireResponse(status, wire_headers, "", -1),
                  now_ms(),
                )
              {
                Error(_) -> {
                  upstream_close(upstream)
                  control.release(managed.controller, selection)
                  reject(503, "quota ledger unavailable")
                }
                Ok(_) ->
                  respond_upstream(
                    req,
                    source_dialect,
                    target_dialect,
                    status,
                    upstream_headers,
                    upstream,
                    Some(#(managed.controller, selection)),
                  )
              }
            }
          }
      }
    }
  }
}

fn prepare_managed(
  req: Request(mist.Connection),
  config: Config,
  managed: Managed,
  target_dialect: Dialect,
  body: BitArray,
) -> Result(#(String, String, List(#(String, String)), BitArray), String) {
  use digest <- result_map(workshop.pointer(managed.state_dir, managed.provider))
  use toml <- result_map(workshop.read_artifact(managed.state_dir, digest))
  use profile <- result_map(persona.parse(toml))
  case persona.lint(profile) {
    [] -> {
      use store <- result_map(storage.new(managed.state_dir))
      use credential <- result_map(auth.load(store, managed.credential_id))
      case
        credential.expires_at_ms > now_ms() && credential.access_token != ""
      {
        False -> Error("managed credential expired or empty")
        True -> {
          use upstream_host <- result_map(host_header(config.upstream))
          let upstream_authorization = "Bearer " <> credential.access_token
          let target = target_path(target_dialect, req.query)
          let safe_headers =
            list.filter(req.headers, fn(pair) {
              let #(name, _) = pair
              !list.contains(
                [
                  "authorization",
                  "x-api-key",
                  "proxy-authorization",
                  "cookie",
                  "set-cookie",
                  "x-goog-api-key",
                  "content-length",
                  "host",
                ],
                string.lowercase(name),
              )
            })
          let headers = [
            Header("Host", upstream_host),
            ..list.map(safe_headers, fn(pair) { Header(pair.0, pair.1) })
          ]
          let headers =
            list.append(headers, [
              Header("Content-Length", int.to_string(bit_array.byte_size(body))),
              Header("Authorization", upstream_authorization),
            ])
          use body_text <- result_map(
            bit_array.to_string(body) |> map_nil_error("invalid request UTF-8"),
          )
          let capture =
            Capture(
              "ingress",
              "managed",
              config.upstream,
              // Request kind is the persona scenario, not a dialect route.
              "main",
              http.method_to_string(req.method),
              target,
              "HTTP/1.1",
              headers,
              body_text,
              Transport("http/1.1", None),
            )
          use output <- result_map(replay.materialize(profile, capture))
          let headers =
            list.map(output.headers, fn(header) {
              let Header(name, value) = header
              #(name, value)
            })
          // Preserve a persona's auth-header position without forwarding the
          // ingress client's credentials or appending a duplicate header.
          use headers <- result_map(
            case
              list.filter(headers, fn(pair) {
                string.lowercase(pair.0) == "authorization"
              })
            {
              [] ->
                Ok(
                  list.append(headers, [
                    #("Authorization", upstream_authorization),
                  ]),
                )
              [#(_, value)] if value == upstream_authorization -> Ok(headers)
              _ -> Error("active persona changed upstream authorization")
            },
          )
          Ok(#(
            output.target,
            output.method,
            headers,
            bit_array.from_string(output.body),
          ))
        }
      }
    }
    _ -> Error("active persona did not pass lint")
  }
}

fn target_path(target: Dialect, query: Option(String)) -> String {
  let path = case target {
    Anthropic -> "/v1/messages"
    Openai -> "/v1/chat/completions"
    Gemini -> ""
  }
  case query {
    Some(value) -> path <> "?" <> value
    None -> path
  }
}

fn forward(
  req: Request(mist.Connection),
  config: Config,
  source_dialect: Dialect,
  target_dialect: Dialect,
  body: BitArray,
) -> Response(mist.ResponseData) {
  let target = case target_dialect {
    Anthropic -> "/v1/messages"
    Openai -> "/v1/chat/completions"
    Gemini -> ""
  }
  let target = case req.query {
    Some(query) -> target <> "?" <> query
    None -> target
  }
  let key_header = case target_dialect {
    Anthropic -> #("x-api-key", config.upstream_key)
    Openai -> #("authorization", "Bearer " <> config.upstream_key)
    Gemini -> #("authorization", "")
  }
  let headers = [
    key_header,
    ..list.filter(req.headers, fn(header) {
      let #(name, _) = header
      !list.contains(
        [
          "host",
          "content-length",
          "transfer-encoding",
          "connection",
          "authorization",
          "x-api-key",
          "proxy-authorization",
          "accept-encoding",
        ],
        string.lowercase(name),
      )
    })
  ]
  case
    upstream_open(
      config.upstream,
      target,
      http.method_to_string(req.method),
      headers,
      body,
    )
  {
    Error(_) -> reject(502, "upstream unavailable or invalid HTTP response")
    Ok(#(status, upstream_headers, upstream)) ->
      respond_upstream(
        req,
        source_dialect,
        target_dialect,
        status,
        upstream_headers,
        upstream,
        None,
      )
  }
}

fn respond_upstream(
  req: Request(mist.Connection),
  source_dialect: Dialect,
  target_dialect: Dialect,
  status: Int,
  upstream_headers: List(#(String, String)),
  upstream: Upstream,
  managed: Option(#(control.Controller, fleet.Selection)),
) -> Response(mist.ResponseData) {
  let content_type = case list.key_find(upstream_headers, "content-type") {
    Ok(value) -> string.lowercase(value)
    Error(_) -> ""
  }
  let encoding = case list.key_find(upstream_headers, "content-encoding") {
    Ok(value) -> string.lowercase(value)
    Error(_) -> "identity"
  }
  case encoding != "identity" {
    True -> {
      upstream_close(upstream)
      release_managed(managed)
      reject(502, "unsupported upstream content encoding")
    }
    False -> {
      let response_headers =
        list.filter(upstream_headers, fn(header) {
          let #(name, _) = header
          list.contains(
            ["content-type", "cache-control", "anthropic-version", "request-id"],
            string.lowercase(name),
          )
        })
      let response = Response(status, response_headers, "")
      case
        status >= 200
        && status < 300
        && string.starts_with(content_type, "text/event-stream")
      {
        True ->
          stream_response(
            req,
            response,
            upstream,
            target_dialect,
            source_dialect,
            managed,
          )
        False -> {
          let result = read_all(upstream, <<>>, 1024 * 1024)
          upstream_close(upstream)
          release_managed(managed)
          case result {
            Error(_) -> reject(502, "upstream response unreadable")
            Ok(bytes) ->
              case
                translate_response(
                  target_dialect,
                  source_dialect,
                  status,
                  bytes,
                )
              {
                Error(_) -> reject(502, "unsupported upstream dialect response")
                Ok(bytes) ->
                  Response(
                    status,
                    response_headers,
                    mist.Bytes(bytes_tree.from_bit_array(bytes)),
                  )
              }
          }
        }
      }
    }
  }
}

fn release_managed(
  managed: Option(#(control.Controller, fleet.Selection)),
) -> Nil {
  case managed {
    None -> Nil
    Some(#(controller, selection)) -> control.release(controller, selection)
  }
}

fn translate_request(
  source: Dialect,
  target: Dialect,
  body: BitArray,
) -> Result(BitArray, String) {
  case source == target {
    True -> Ok(body)
    False -> {
      use text <- result_map(
        bit_array.to_string(body) |> map_nil_error("invalid UTF-8"),
      )
      let decoded = case source {
        Anthropic -> anthropic.decode_request(text)
        Openai -> openai.decode_request(text)
        Gemini -> Error("Gemini request dialect is unsupported")
      }
      use request <- result_map(decoded)
      let encoded = case target {
        Anthropic -> anthropic.encode_request(request)
        Openai -> openai.encode_request(request)
        Gemini -> Error("Gemini request dialect is unsupported")
      }
      use text <- result_map(encoded)
      Ok(bit_array.from_string(text))
    }
  }
}

fn translate_response(
  source: Dialect,
  target: Dialect,
  status: Int,
  body: BitArray,
) -> Result(BitArray, String) {
  case source == target || status < 200 || status >= 300 {
    True -> Ok(body)
    False -> {
      use text <- result_map(
        bit_array.to_string(body) |> map_nil_error("invalid UTF-8"),
      )
      let decoded = case source {
        Anthropic -> anthropic.decode_response(text)
        Openai -> openai.decode_response(text)
        Gemini -> Error("Gemini response dialect is unsupported")
      }
      use message <- result_map(decoded)
      let encoded = case target {
        Anthropic -> anthropic.encode_response(message)
        Openai -> openai.encode_response(message)
        Gemini -> Error("Gemini response dialect is unsupported")
      }
      use text <- result_map(encoded)
      Ok(bit_array.from_string(text))
    }
  }
}

fn read_all(
  upstream: Upstream,
  accumulated: BitArray,
  max_bytes: Int,
) -> Result(BitArray, String) {
  case upstream_next(upstream) {
    Ok(None) -> Ok(accumulated)
    Ok(Some(#(data, next))) -> {
      let combined = bit_array.append(accumulated, data)
      case bit_array.byte_size(combined) > max_bytes {
        True -> Error("upstream response too large")
        False -> read_all(next, combined, max_bytes)
      }
    }
    Error(error) -> Error(error)
  }
}

fn stream_response(
  req: Request(mist.Connection),
  response: Response(String),
  upstream: Upstream,
  source: Dialect,
  target: Dialect,
  managed: Option(#(control.Controller, fleet.Selection)),
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: req,
    response: response,
    init: fn(subject) {
      process.send(subject, NextChunk)
      StreamState(
        upstream,
        subject,
        dialect.new_stream(source, target),
        <<>>,
        managed,
      )
    },
    loop: fn(state, _message, connection) {
      case upstream_next(state.upstream) {
        Ok(Some(#(bytes, next))) -> {
          let combined = bit_array.append(state.pending_utf8, bytes)
          case utf8_prefix(combined) {
            Error(_) -> {
              upstream_close(next)
              release_managed(state.managed)
              mist.chunk_stop_abnormal("invalid upstream stream encoding")
            }
            Ok(#(text, pending)) ->
              case dialect.feed(state.stream, text) {
                Error(_) -> {
                  upstream_close(next)
                  release_managed(state.managed)
                  mist.chunk_stop_abnormal("invalid upstream SSE frame")
                }
                Ok(#(updated, frames)) ->
                  case send_frames(connection, frames) {
                    Error(_) -> {
                      upstream_close(next)
                      release_managed(state.managed)
                      mist.chunk_stop()
                    }
                    Ok(_) -> {
                      process.send(state.subject, NextChunk)
                      mist.chunk_continue(StreamState(
                        next,
                        state.subject,
                        updated,
                        pending,
                        state.managed,
                      ))
                    }
                  }
              }
          }
        }
        Ok(None) -> {
          upstream_close(state.upstream)
          release_managed(state.managed)
          case
            bit_array.byte_size(state.pending_utf8),
            dialect.finish(state.stream)
          {
            0, Ok(frames) ->
              case send_frames(connection, frames) {
                Ok(_) -> mist.chunk_stop()
                Error(_) -> mist.chunk_stop()
              }
            _, _ -> mist.chunk_stop_abnormal("incomplete upstream SSE stream")
          }
        }
        Error(_) -> {
          upstream_close(state.upstream)
          release_managed(state.managed)
          mist.chunk_stop_abnormal("upstream stream failed")
        }
      }
    },
  )
}

fn send_frames(
  connection: mist.Connection,
  frames: List(String),
) -> Result(Nil, Nil) {
  case frames {
    [] -> Ok(Nil)
    [frame, ..rest] ->
      case mist.send_chunk(connection, bit_array.from_string(frame)) {
        Error(error) -> Error(error)
        Ok(_) -> send_frames(connection, rest)
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

fn map_nil_error(value: Result(a, Nil), message: String) -> Result(a, String) {
  case value {
    Ok(v) -> Ok(v)
    Error(_) -> Error(message)
  }
}

fn authenticated(
  req: Request(mist.Connection),
  key: String,
  managed: Option(Managed),
) -> Bool {
  let provided = case request_header(req, "x-api-key") {
    Ok(value) -> value
    Error(_) ->
      case request_header(req, "authorization") {
        Ok(value) ->
          case string.starts_with(value, "Bearer ") {
            True -> string.drop_start(value, 7)
            False -> ""
          }
        Error(_) -> ""
      }
  }
  case managed {
    None -> secure_equal(provided, key)
    Some(context) -> {
      let registered = case keys.verify(context.state_dir, provided) {
        Ok(value) -> value
        Error(_) -> False
      }
      let legacy = environment("MIMIC_INGRESS_KEY")
      registered || legacy != "" && secure_equal(provided, legacy)
    }
  }
}

fn request_header(req: Request(a), key: String) -> Result(String, Nil) {
  case list.filter(req.headers, fn(header) { header.0 == key }) {
    [#(_, value)] -> Ok(value)
    _ -> Error(Nil)
  }
}

fn allowed(req: Request(a)) -> Bool {
  req.method == http.Post
  && list.contains(["/v1/messages", "/v1/chat/completions"], req.path)
}

fn request_body(req: Request(mist.Connection)) -> Result(BitArray, String) {
  case request_header(req, "content-encoding") {
    Ok(value) if value != "identity" -> Error("unsupported content encoding")
    _ ->
      case mist.read_body(req, 1024 * 1024) {
        Ok(read) ->
          case bit_array.to_string(read.body) {
            Ok(_) -> Ok(read.body)
            Error(_) -> Error("request body must be UTF-8")
          }
        Error(_) -> Error("malformed or oversized request body")
      }
  }
}

fn reject(status: Int, message: String) -> Response(mist.ResponseData) {
  Response(
    status,
    [#("content-type", "application/json")],
    mist.Bytes(bytes_tree.from_string("{\"error\":\"" <> message <> "\"}")),
  )
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["managed", port, origin, state_dir, provider, credential_id, dialect_name] ->
      case int.parse(port), dialect_name {
        Ok(number), "anthropic" ->
          run_managed(
            number,
            origin,
            state_dir,
            provider,
            credential_id,
            Anthropic,
          )
        Ok(number), "openai" ->
          run_managed(
            number,
            origin,
            state_dir,
            provider,
            credential_id,
            Openai,
          )
        _, _ ->
          Error(
            "usage: serve managed <port> <upstream-origin> <state-dir> <provider> <credential-id> <anthropic|openai>",
          )
      }
    [port, origin] ->
      case int.parse(port) {
        Error(_) -> Error("usage: serve <port> <explicit-upstream-origin>")
        Ok(number) -> {
          let client_key = environment("MIMIC_INGRESS_KEY")
          let upstream_key = environment("MIMIC_UPSTREAM_KEY")
          case start(number, origin, client_key, upstream_key) {
            Ok(bound) -> {
              wait_forever()
              Ok("ingress stopped on 127.0.0.1:" <> int.to_string(bound))
            }
            Error(error) -> Error(error)
          }
        }
      }
    _ ->
      Error(
        "usage: serve <port> <explicit-upstream-origin>; keys via MIMIC_INGRESS_KEY and MIMIC_UPSTREAM_KEY",
      )
  }
}

fn run_managed(
  port: Int,
  origin: String,
  state_dir: String,
  provider: String,
  credential_id: String,
  dialect: Dialect,
) -> Result(String, String) {
  case
    start_managed(port, origin, state_dir, provider, credential_id, dialect)
  {
    Ok(bound) -> {
      wait_forever()
      Ok("ingress stopped on 127.0.0.1:" <> int.to_string(bound))
    }
    Error(error) -> Error(error)
  }
}

@external(erlang, "mimic_ingress_ffi", "secure_equal")
fn secure_equal(a: String, b: String) -> Bool

@external(erlang, "mimic_ingress_ffi", "utf8_prefix")
fn utf8_prefix(data: BitArray) -> Result(#(String, BitArray), String)

@external(erlang, "mimic_ingress_ffi", "open")
fn upstream_open(
  origin: String,
  target: String,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(#(Int, List(#(String, String)), Upstream), String)

@external(erlang, "mimic_ingress_ffi", "open_preserve")
fn upstream_open_preserve(
  origin: String,
  target: String,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(#(Int, List(#(String, String)), Upstream), String)

@external(erlang, "mimic_ingress_ffi", "next")
fn upstream_next(
  upstream: Upstream,
) -> Result(Option(#(BitArray, Upstream)), String)

@external(erlang, "mimic_ingress_ffi", "close")
fn upstream_close(upstream: Upstream) -> Nil

@external(erlang, "mimic_ingress_ffi", "register")
fn register_server(port: Int, pid: process.Pid) -> Nil

@external(erlang, "mimic_ingress_ffi", "stop")
fn stop_server(port: Int) -> Result(Nil, String)

@external(erlang, "mimic_ingress_ffi", "environment")
fn environment(name: String) -> String

@external(erlang, "mimic_ingress_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "mimic_ingress_ffi", "new_session_id")
fn new_session_id() -> String

@external(erlang, "mimic_ingress_ffi", "wait_forever")
fn wait_forever() -> Nil
