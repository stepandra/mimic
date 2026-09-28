import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import mimic/observability
import mist

pub type CredentialInput {
  CredentialInput(
    id: String,
    access_token: String,
    refresh_token: String,
    expires_at_ms: Int,
  )
}

pub type CredentialMetadata {
  CredentialMetadata(id: String, expires_at_ms: Int)
}

/// Only metadata crosses the response boundary. Implementations must call
/// persona.parse/lint before create_persona, Workshop.artifact for storage,
/// and Workshop.promote for activation (never mutate the pointer directly).
pub type Backend {
  Backend(
    create_persona: fn(String, String) -> Result(String, String),
    active_persona: fn(String) -> Result(String, String),
    promote: fn(String, String) -> Result(Nil, String),
    credentials: fn() -> Result(List(CredentialMetadata), String),
    create_credential: fn(CredentialInput) -> Result(Nil, String),
    delete_credential: fn(String) -> Result(Nil, String),
    keys: fn() -> Result(List(String), String),
    create_key: fn(String, String) -> Result(Nil, String),
    delete_key: fn(String) -> Result(Nil, String),
    quotas: fn() -> Result(List(#(String, Int)), String),
    drift: fn() -> Result(List(#(String, Int)), String),
  )
}

/// The only supported listener is loopback; deliberately no bind-address
/// argument. The key must be supplied by the operator's environment.
pub fn serve_with(port: Int, backend: Backend) -> Result(String, String) {
  use key <- result.try(management_key())
  case port > 0 && port < 65_536 {
    False -> Error("invalid management port")
    True -> {
      let builder =
        mist.new(fn(req) {
          let response = case mist.read_body(req, max_body_limit: 65_536) {
            Ok(req) -> handle(req, key, port, backend)
            Error(_) -> reply(413, "request body too large")
          }
          response
          |> response.map(bytes_tree.from_string)
          |> response.map(mist.Bytes)
        })
        |> mist.bind("127.0.0.1")
        |> mist.port(port)
      case mist.start(builder) {
        Ok(_) -> {
          // The returned listener is supervised by mist. The CLI command is
          // intentionally long-running, as with the other server commands.
          process_forever()
          Ok("management stopped")
        }
        Error(_) -> Error("management listener failed")
      }
    }
  }
}

@external(erlang, "mimic_management_ffi", "management_key")
fn management_key() -> Result(String, String)

@external(erlang, "mimic_management_ffi", "equal")
fn constant_time_equal(a: String, b: String) -> Bool

@external(erlang, "mimic_management_ffi", "process_forever")
fn process_forever() -> Nil

@external(erlang, "mimic_management_ffi", "asset")
fn asset(name: String) -> Result(String, String)

pub fn handle(
  req: Request(BitArray),
  key: String,
  port: Int,
  backend: Backend,
) -> Response(String) {
  let path = req.path
  case allowed_host(req.host) && safe_path(path) {
    False -> reply(400, "invalid host or path")
    True ->
      case req.method, path {
        Get, "/" -> static_asset("index.html", "text/html; charset=utf-8")
        Get, "/panel.js" ->
          static_asset("panel.js", "text/javascript; charset=utf-8")
        Get, "/panel.css" ->
          static_asset("panel.css", "text/css; charset=utf-8")
        _, _ ->
          case string.starts_with(path, "/api/") {
            False -> reply(404, "not found")
            True ->
              case authorized(req, key) {
                False -> reply(401, "unauthorized")
                True ->
                  case valid_origin(req, port) {
                    False -> reply(403, "origin denied")
                    True -> api(req, backend)
                  }
              }
          }
      }
  }
}

fn allowed_host(host: String) -> Bool {
  host == "127.0.0.1" || host == "localhost"
}

fn safe_path(path: String) -> Bool {
  !string.contains(path, "%")
  && !string.contains(path, "..")
  && !string.contains(path, "//")
  && !string.contains(path, "\\")
  && string.byte_size(path) <= 256
}

fn authorized(req: Request(BitArray), key: String) -> Bool {
  case request.get_header(req, "authorization") {
    Ok(value) -> constant_time_equal(value, "Bearer " <> key)
    Error(_) -> False
  }
}

fn valid_origin(req: Request(BitArray), port: Int) -> Bool {
  case request.get_header(req, "origin") {
    Error(_) -> True
    Ok(origin) ->
      origin == "http://127.0.0.1:" <> int.to_string(port)
      || origin == "http://localhost:" <> int.to_string(port)
  }
}

fn json_content(req: Request(BitArray)) -> Bool {
  case request.get_header(req, "content-type") {
    Ok(value) -> value == "application/json"
    Error(_) -> False
  }
}

fn api(req: Request(BitArray), backend: Backend) -> Response(String) {
  let segments = string.split(req.path, "/")
  case req.method, segments {
    Get, ["", "api", "health"] ->
      data(200, json.object([#("ok", json.bool(True))]))
    Get, ["", "api", "metrics"] ->
      reply(200, observability.metrics())
      |> response.set_header("content-type", "text/plain; charset=utf-8")
    Get, ["", "api", "personas", provider, "active"] ->
      case valid_id(provider) {
        False -> reply(400, "invalid provider")
        True ->
          case backend.active_persona(provider) {
            Ok(digest) ->
              data(
                200,
                json.object([
                  #("provider", json.string(provider)),
                  #("digest", json.string(digest)),
                ]),
              )
            Error(_) -> reply(404, "not found")
          }
      }
    Put, ["", "api", "personas", provider, "drafts"] ->
      case valid_id(provider) {
        False -> reply(400, "invalid provider")
        True ->
          write(req, ["content"], fn() {
            let decoder = {
              use content <- decode.field("content", decode.string)
              decode.success(content)
            }
            case json.parse_bits(req.body, decoder) {
              Ok(content) ->
                case
                  string.byte_size(content) > 0
                  && string.byte_size(content) <= 60_000
                {
                  True ->
                    case backend.create_persona(provider, content) {
                      Ok(digest) ->
                        data(
                          201,
                          json.object([#("digest", json.string(digest))]),
                        )
                      Error(_) -> reply(422, "invalid persona draft")
                    }
                  False -> reply(400, "invalid persona draft")
                }
              _ -> reply(400, "invalid persona draft")
            }
          })
      }
    Post, ["", "api", "promotions"] ->
      write(req, ["run_id", "signature"], fn() {
        let decoder = {
          use run_id <- decode.field("run_id", decode.string)
          use signature <- decode.field("signature", decode.string)
          decode.success(#(run_id, signature))
        }
        case json.parse_bits(req.body, decoder) {
          Ok(#(run_id, signature)) ->
            case valid_id(run_id) && signature != "" {
              True ->
                case backend.promote(run_id, signature) {
                  Ok(_) ->
                    data(200, json.object([#("promoted", json.bool(True))]))
                  Error(_) -> reply(422, "promotion rejected")
                }
              False -> reply(400, "invalid promotion")
            }
          _ -> reply(400, "invalid promotion")
        }
      })
    Get, ["", "api", "credentials"] ->
      case backend.credentials() {
        Ok(items) ->
          data(
            200,
            json.array(items, fn(item) {
              json.object([
                #("id", json.string(item.id)),
                #("expires_at_ms", json.int(item.expires_at_ms)),
              ])
            }),
          )
        Error(_) -> reply(503, "metadata unavailable")
      }
    Post, ["", "api", "credentials"] ->
      write(req, ["id", "access_token", "refresh_token", "expires_at_ms"], fn() {
        let decoder = {
          use id <- decode.field("id", decode.string)
          use access <- decode.field("access_token", decode.string)
          use refresh <- decode.field("refresh_token", decode.string)
          use expiry <- decode.field("expires_at_ms", decode.int)
          decode.success(CredentialInput(id, access, refresh, expiry))
        }
        case json.parse_bits(req.body, decoder) {
          Ok(input) ->
            case
              valid_id(input.id)
              && input.access_token != ""
              && input.refresh_token != ""
              && input.id != input.access_token
              && input.id != input.refresh_token
              && input.expires_at_ms > 0
            {
              True ->
                case backend.create_credential(input) {
                  Ok(_) ->
                    data(201, json.object([#("created", json.bool(True))]))
                  Error(_) -> reply(422, "credential rejected")
                }
              False -> reply(400, "invalid credential")
            }
          _ -> reply(400, "invalid credential")
        }
      })
    Delete, ["", "api", "credentials", id] ->
      case valid_id(id) {
        False -> reply(400, "invalid credential id")
        True ->
          case backend.delete_credential(id) {
            Ok(_) -> data(200, json.object([#("deleted", json.bool(True))]))
            Error(_) -> reply(404, "not found")
          }
      }
    Get, ["", "api", "keys"] ->
      case backend.keys() {
        Ok(ids) ->
          data(
            200,
            json.array(ids, fn(id) { json.object([#("id", json.string(id))]) }),
          )
        Error(_) -> reply(503, "metadata unavailable")
      }
    Post, ["", "api", "keys"] ->
      write(req, ["id", "token"], fn() {
        let decoder = {
          use id <- decode.field("id", decode.string)
          use token <- decode.field("token", decode.string)
          decode.success(#(id, token))
        }
        case json.parse_bits(req.body, decoder) {
          Ok(#(id, token)) ->
            case valid_id(id) && id != token && string.byte_size(token) >= 32 {
              True ->
                case backend.create_key(id, token) {
                  Ok(_) ->
                    data(201, json.object([#("created", json.bool(True))]))
                  Error(_) -> reply(422, "key rejected")
                }
              False -> reply(400, "invalid key")
            }
          _ -> reply(400, "invalid key")
        }
      })
    Delete, ["", "api", "keys", id] ->
      case valid_id(id) {
        False -> reply(400, "invalid key id")
        True ->
          case backend.delete_key(id) {
            Ok(_) -> data(200, json.object([#("deleted", json.bool(True))]))
            Error(_) -> reply(404, "not found")
          }
      }
    Get, ["", "api", "quotas"] -> view(backend.quotas())
    Get, ["", "api", "drift"] -> view(backend.drift())
    _, _ -> reply(404, "not found")
  }
}

fn view(value: Result(List(#(String, Int)), String)) -> Response(String) {
  case value {
    Ok(items) ->
      data(
        200,
        json.array(items, fn(item) {
          let #(id, value) = item
          json.object([#("id", json.string(id)), #("value", json.int(value))])
        }),
      )
    Error(_) -> reply(503, "view unavailable")
  }
}

fn write(
  req: Request(BitArray),
  allowed_fields: List(String),
  f: fn() -> Response(String),
) -> Response(String) {
  case json_content(req) && bit_array.byte_size(req.body) <= 65_536 {
    True ->
      case
        json.parse_bits(req.body, decode.dict(decode.string, decode.dynamic))
      {
        Ok(fields) ->
          case
            list.all(dict.keys(fields), fn(key) {
              list.contains(allowed_fields, key)
            })
          {
            True -> f()
            False -> reply(400, "unknown field")
          }
        Error(_) -> reply(400, "invalid JSON object")
      }
    False -> reply(415, "application/json required")
  }
}

pub fn valid_id(id: String) -> Bool {
  string.byte_size(id) > 0
  && string.byte_size(id) <= 64
  && list.all(string.to_graphemes(id), fn(char) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      char,
    )
  })
}

fn static_asset(name: String, content_type: String) -> Response(String) {
  case asset(name) {
    Ok(body) ->
      reply(200, body) |> response.set_header("content-type", content_type)
    Error(_) -> reply(503, "panel unavailable")
  }
}

fn data(status: Int, value: json.Json) -> Response(String) {
  reply(status, json.to_string(value))
  |> response.set_header("content-type", "application/json; charset=utf-8")
}

fn reply(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_body(body)
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  )
  |> response.set_header("content-type", "text/plain; charset=utf-8")
}

/// Parent integration passes the real backend to `serve_with`. An unwired CLI
/// refuses to start rather than offering a misleading disconnected CRUD store.
pub fn cli(_args: List(String)) -> Result(String, String) {
  Error(
    "management backend not wired; call serve_with with Workshop/auth/ingress adapters",
  )
}
