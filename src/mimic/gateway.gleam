import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/auth
import mimic/auth/runtime as credential
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/dialect/openai
import mimic/dialect/responses
import mimic/gateway/codex_http
import mimic/gateway/config.{type Config}
import mimic/gateway/enrollment
import mimic/gateway/refresh
import mimic/gateway/websocket
import mimic/ingress/keys
import mimic/ir
import mimic/protocol/chat/stream as chat_stream
import mimic/protocol/responses/http as responses_http
import mimic/protocol/responses/stream as responses_stream
import mimic/providers/claude/adapter as claude_adapter
import mimic/providers/claude/http as claude_http
import mimic/providers/claude/json_guard as strict_json
import mimic/providers/claude/login as claude_login
import mimic/providers/claude/transport as claude_transport
import mimic/providers/codex/adapter as codex
import mimic/providers/codex/json_guard as request_json
import mimic/providers/codex/models
import mimic/providers/codex/request as codex_request
import mimic/providers/codex/response as codex_response
import mimic/providers/contracts
import mimic/providers/devin/auth as devin_auth
import mimic/providers/devin/bridge as devin
import mimic/providers/kimi/adapter as kimi
import mimic/providers/kimi/models as kimi_models
import mimic/providers/kimi/oauth as kimi_oauth
import mimic/providers/kimi/request as kimi_request
import mimic/providers/kimi_compat/request as kimi_compat
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/providers/xai/adapter as xai
import mimic/providers/xai/endpoint as xai_endpoint
import mimic/providers/xai/models as xai_models
import mist
import simplifile

pub opaque type Server {
  Server(port: Int, pid: process.Pid, services: Services)
}

type Services {
  Services(engine: runtime.Runtime, continuation: Option(codex_http.State))
}

type Tick {
  Tick
}

type CodexStream {
  CodexStream(
    opened: runtime.Response,
    prepared: codex_request.Prepared,
    subject: process.Subject(Tick),
    adopted: Bool,
  )
}

type NativeStream {
  NativeStream(opened: runtime.Response, adopted: Bool)
}

type ClaudeStream {
  ClaudeStream(opened: runtime.Response, adopted: Bool)
}

pub fn port(server: Server) -> Int {
  server.port
}

pub fn load(path: String) -> Result(Config, String) {
  use source <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { "cannot read gateway config" }),
  )
  config.decode(source)
}

/// The CLI never takes credential values as argv, nor returns them as output.
/// Operators create private 0600 files outside the checkout and pre-create a
/// 0700 state directory. Runtime records use runtime_store, not legacy auth.
pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["serve", path] -> {
      use settings <- result.try(load(path))
      use _ <- result.try(install_signal())
      case start(settings) {
        Error(error) -> {
          restore_signal()
          Error(error)
        }
        Ok(server) -> {
          let outcome = await_signal()
          let stopped = stop(server)
          restore_signal()
          use _ <- result.try(outcome)
          use _ <- result.try(stopped)
          Ok("gateway stopped")
        }
      }
    }
    ["credential", "login", path, account_id, private_identity_path] -> {
      use settings <- result.try(load(path))
      use account <- result.try(configured_account(settings, account_id))
      use store <- result.try(storage.new(settings.state_dir) |> sanitized)
      use source <- result.try(private_text(private_identity_path))
      use identity <- result.try(strict_json.parse(source) |> sanitized)
      let key = credential.key(account.provider, account.auth_mode, account.id)
      use _ <- result.try(
        case account.oauth {
          Some(config.ClaudeOAuth(oauth)) ->
            claude_login.run(
              oauth,
              store,
              key,
              identity,
              120_000,
              io.println,
              refresh.claude,
            )
          Some(config.KimiOAuth(oauth)) ->
            enrollment.kimi(oauth, store, key, identity, io.println)
          _ -> Error("configured Claude or Kimi OAuth account required")
        }
        |> sanitized,
      )
      Ok("credential stored")
    }
    ["credential", "import", path, account_id, private_path] -> {
      use settings <- result.try(load(path))
      use account <- result.try(configured_account(settings, account_id))
      use store <- result.try(storage.new(settings.state_dir) |> sanitized)
      use source <- result.try(private_text(private_path))
      use body <- result.try(strict_json.parse(source) |> sanitized)
      use material <- result.try(case account.provider, account.auth_mode {
        "claude", "oauth" -> claude_adapter.import_oauth(body) |> sanitized
        "kimi", "oauth" -> {
          use oauth <- result.try(case account.oauth {
            Some(config.KimiOAuth(settings)) -> Ok(settings)
            _ -> Error("configured Kimi OAuth account required")
          })
          use device <- result.try(
            ir.string_field(body, "device_id") |> sanitized,
          )
          use access <- result.try(
            ir.string_field(body, "access_token") |> sanitized,
          )
          use refresh <- result.try(
            ir.string_field(body, "refresh_token") |> sanitized,
          )
          use expires <- result.try(
            ir.required(body, "expires_at_ms")
            |> result.try(ir.as_int)
            |> sanitized,
          )
          kimi_oauth.import_material(
            kimi_oauth.Config(..oauth, device_id: device),
            auth.Credential(access, refresh, expires),
          )
          |> sanitized
        }
        "claude", "api_key"
        | "xai", "api_key"
        | "kimi", "api_key"
        | "openai-compatible-kimi", "api_key"
        ->
          ir.string_field(body, "api_key")
          |> sanitized
          |> result.try(fn(secret) {
            case secret != "" {
              True -> Ok(contracts.ApiKey(secret))
              False -> Error("invalid private credential")
            }
          })
        "codex", "oauth" -> {
          use access <- result.try(
            ir.string_field(body, "access_token") |> sanitized,
          )
          use refresh <- result.try(
            ir.string_field(body, "refresh_token") |> sanitized,
          )
          use expires <- result.try(
            ir.required(body, "expires_at_ms")
            |> result.try(ir.as_int)
            |> sanitized,
          )
          use upstream_account <- result.try(
            ir.string_field(body, "chatgpt_account_id") |> sanitized,
          )
          case
            access != ""
            && refresh != ""
            && upstream_account != ""
            && expires > 0
          {
            True ->
              Ok(
                contracts.OAuth(
                  contracts.OAuthData(
                    auth.Credential(access, refresh, expires),
                    [#("chatgpt_account_id", upstream_account)],
                  ),
                ),
              )
            False -> Error("invalid private credential")
          }
        }
        "devin", "session_token" ->
          ir.string_field(body, "session_token")
          |> sanitized
          |> result.try(fn(raw) {
            devin_auth.format_session_token(raw)
            |> sanitized
            |> result.map(fn(token) { contracts.SessionToken(token, []) })
          })
        _, _ -> Error("unsupported credential mode")
      })
      use _ <- result.try(
        runtime_store.save(
          store,
          credential.key(account.provider, account.auth_mode, account.id),
          material,
        )
        |> sanitized,
      )
      Ok("credential imported")
    }
    ["credential", "status", path, account_id] -> {
      use settings <- result.try(load(path))
      use account <- result.try(configured_account(settings, account_id))
      use store <- result.try(storage.new(settings.state_dir) |> sanitized)
      use metadata <- result.try(
        runtime_store.metadata(
          store,
          credential.key(account.provider, account.auth_mode, account.id),
        )
        |> sanitized,
      )
      Ok(
        "credential configured: " <> account.id <> " (" <> metadata.kind <> ")",
      )
    }
    ["credential", "delete", path, account_id] -> {
      use settings <- result.try(load(path))
      use account <- result.try(configured_account(settings, account_id))
      use store <- result.try(storage.new(settings.state_dir) |> sanitized)
      use _ <- result.try(
        runtime_store.delete(
          store,
          credential.key(account.provider, account.auth_mode, account.id),
        )
        |> sanitized,
      )
      Ok("credential deleted")
    }
    ["key", "import", path, key_id, private_path] -> {
      use settings <- result.try(load(path))
      use secret <- result.try(private_text(private_path))
      let secret = string.trim_end(secret)
      use _ <- result.try(
        keys.create(settings.state_dir, key_id, secret) |> sanitized,
      )
      Ok("client key imported")
    }
    ["key", "revoke", path, key_id] -> {
      use settings <- result.try(load(path))
      use _ <- result.try(keys.revoke(settings.state_dir, key_id) |> sanitized)
      Ok("client key revoked")
    }
    _ ->
      Error(
        "Usage: providers serve <config> | credential import/login/status/delete <config> <account-id> [private-json-path] | key import/revoke <config> <key-id> [private-text-path]",
      )
  }
}

fn configured_account(
  config: Config,
  id: String,
) -> Result(config.Account, String) {
  case list.filter(config.accounts, fn(a) { a.id == id }) {
    [account] -> Ok(account)
    _ -> Error("account is not uniquely configured")
  }
}

fn private_text(path: String) -> Result(String, String) {
  use bytes <- result.try(private_read(path) |> sanitized)
  bit_array.to_string(bytes) |> sanitized
}

pub fn start(config: Config) -> Result(Server, String) {
  use store <- result.try(storage.new(config.state_dir) |> sanitized)
  use registrations <- result.try(registrations(config))
  use registry <- result.try(registry.new(registrations) |> sanitized)
  use engine <- result.try(
    runtime.start(store, registry, config.runtime_accounts(config)) |> sanitized,
  )
  use continuation <- result.try(case config.codex_http_continuation {
    False -> Ok(None)
    True ->
      case codex_http.start() {
        Ok(cache) -> Ok(Some(cache))
        Error(_) -> {
          let _ = runtime.stop(engine)
          Error("gateway continuation cache unavailable")
        }
      }
  })
  let services = Services(engine, continuation)
  let ready = process.new_subject()
  let listener =
    mist.new(fn(req) { handle(req, config, services) })
    |> mist.port(config.listen_port)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
  case mist.start(listener) {
    Error(_) -> {
      let _ = stop_services(services)
      Error("gateway listener failed")
    }
    Ok(server) ->
      case process.receive(ready, 5000) {
        Ok(actual) -> {
          process.unlink(server.pid)
          Ok(Server(actual, server.pid, services))
        }
        Error(_) -> {
          process.unlink(server.pid)
          process.send_exit(server.pid)
          let _ = stop_services(services)
          Error("gateway listener failed")
        }
      }
  }
}

pub fn stop(server: Server) -> Result(Nil, String) {
  process.send_exit(server.pid)
  stop_services(server.services)
}

fn stop_services(services: Services) -> Result(Nil, String) {
  // Run both cleanups even if one fails. The runtime closes outstanding
  // upstream leases; cache shutdown prevents any later receipt publication.
  let engine = runtime.stop(services.engine) |> sanitized
  let cache = case services.continuation {
    None -> Ok(Nil)
    Some(state) -> codex_http.stop(state) |> sanitized
  }
  use _ <- result.try(engine)
  cache
}

fn registrations(config: Config) -> Result(List(registry.Model), String) {
  let pairs =
    config.accounts
    |> list.flat_map(fn(a) { list.map(a.models, fn(id) { #(a.provider, id) }) })
    |> list.unique
  list.try_map(pairs, fn(pair) {
    case pair {
      #("claude", model) ->
        Ok(
          registry.Model(
            "claude",
            model,
            ["api_key", "oauth"],
            ["messages"],
            ["messages", "messages/count_tokens"],
            [contracts.Buffer, contracts.Stream],
          ),
        )
      #("codex", model) -> {
        use catalog <- result.try(case config.codex_catalog {
          Some(value) -> Ok(value)
          None -> Error("Codex catalog required")
        })
        use entry <- result.try(models.lookup(catalog, model) |> sanitized)
        use registered <- result.try(codex.registration(entry) |> sanitized)
        Ok(
          registry.Model(
            ..registered,
            capabilities: case config.codex_websocket {
              True -> [contracts.WebSocket, ..registered.capabilities]
              False -> registered.capabilities
            },
          ),
        )
      }
      #("devin", _) -> list.first(devin.models()) |> sanitized
      #("xai", model) ->
        xai_models.registration_for(
          model,
          xai_endpoint.defaults(xai_endpoint.ApiKey),
        )
        |> sanitized
      #("kimi", model) -> kimi_models.registration(model) |> sanitized
      #("openai-compatible-kimi", model) ->
        kimi_compat.registration(model) |> sanitized
      _ -> Error("unsupported provider")
    }
  })
}

fn handle(
  req: Request(mist.Connection),
  config: Config,
  services: Services,
) -> Response(mist.ResponseData) {
  // Authorization is checked before model lookup, body parsing or any runtime
  // acquisition. The client never controls origin, account, or auth mode.
  case bearer(req) {
    Error(_) -> reject(401, "unauthorized")
    Ok(secret) ->
      case keys.verify(config.state_dir, secret) {
        Ok(True) -> route(req, config, services, verified_identity(secret))
        _ -> reject(401, "unauthorized")
      }
  }
}

fn route(
  req: Request(mist.Connection),
  config: Config,
  services: Services,
  identity: String,
) -> Response(mist.ResponseData) {
  case req.method, req.path, req.query {
    Get, "/v1/responses", None if config.codex_websocket -> {
      let assert Some(catalog) = config.codex_catalog
      let enabled =
        config.accounts
        |> list.filter(fn(account) { account.provider == "codex" })
        |> list.flat_map(fn(account) { account.models })
        |> list.unique
      let state_dir = config.state_dir
      // Retain only the private verification inputs, not the HTTP request or
      // coalesced frame buffer. Every subsequent inference rechecks this key.
      let authorized = case bearer(req) {
        Ok(secret) -> fn() { keys.verify(state_dir, secret) == Ok(True) }
        Error(_) -> fn() { False }
      }
      websocket.upgrade_authenticated(
        req,
        services.engine,
        identity,
        websocket.Settings(
          catalog,
          config.codex_user_agent,
          enabled,
          None,
          authorized,
        ),
      )
    }
    Get, "/v1/models", None -> {
      let ids =
        config.accounts
        |> list.flat_map(fn(a) { a.models })
        |> list.unique
      data(
        200,
        json.object([
          #("object", json.string("list")),
          #(
            "data",
            json.array(ids, fn(id) {
              json.object([
                #("id", json.string(id)),
                #("object", json.string("model")),
              ])
            }),
          ),
        ]),
      )
    }
    Post, "/v1/messages", None ->
      with_body(req, fn(body) {
        dispatch(req, config, services, identity, body, "messages", "messages")
      })
    Post, "/v1/messages/count_tokens", None ->
      with_body(req, fn(body) {
        dispatch(
          req,
          config,
          services,
          identity,
          body,
          "claude",
          "messages/count_tokens",
        )
      })
    Post, "/v1/responses", None ->
      with_body(req, fn(body) {
        dispatch(
          req,
          config,
          services,
          identity,
          body,
          "responses",
          "responses",
        )
      })
    Post, "/v1/responses/compact", None ->
      with_body(req, fn(body) {
        dispatch(
          req,
          config,
          services,
          identity,
          body,
          "responses",
          "responses/compact",
        )
      })
    Post, "/v1/chat/completions", None ->
      with_body(req, fn(body) {
        dispatch(
          req,
          config,
          services,
          identity,
          body,
          "chat",
          "chat/completions",
        )
      })
    _, _, _ -> reject(404, "unsupported endpoint")
  }
}

fn with_body(
  req: Request(mist.Connection),
  next: fn(String) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case
    request_header(req, "content-type"),
    request_header(req, "content-encoding")
  {
    Ok("application/json"), Error(_) | Ok("application/json"), Ok("identity") ->
      case mist.read_body(req, max_body_limit: 1_048_576) {
        Ok(read) ->
          case bit_array.to_string(read.body) {
            Ok(body) -> next(body)
            Error(_) -> reject(400, "invalid request body")
          }
        Error(_) -> reject(413, "invalid request body")
      }
    _, _ -> reject(415, "unsupported content encoding or type")
  }
}

fn dispatch(
  req: Request(mist.Connection),
  config: Config,
  services: Services,
  identity: String,
  body: String,
  provider: String,
  operation: String,
) -> Response(mist.ResponseData) {
  let engine = services.engine
  case request_json.parse(body) {
    Error(_) -> reject(400, "invalid JSON")
    Ok(value) ->
      case ir.string_field(value, "model") {
        Error(_) -> reject(400, "model required")
        Ok(model) ->
          case
            list.find(config.accounts, fn(a) {
              {
                a.provider == provider
                || {
                  provider == "messages"
                  && { a.provider == "claude" || a.provider == "kimi" }
                }
                || {
                  provider == "chat"
                  && {
                    a.provider == "kimi"
                    || a.provider == "devin"
                    || a.provider == "openai-compatible-kimi"
                  }
                }
                || {
                  provider == "responses"
                  && {
                    a.provider == "codex"
                    || a.provider == "xai"
                    || a.provider == "kimi"
                  }
                }
              }
              && list.contains(a.models, model)
            })
          {
            Error(_) -> reject(422, "unsupported model")
            Ok(account) -> {
              let provider = account.provider
              let operation = case provider {
                "devin" -> "generate"
                _ -> operation
              }
              let stream = ir.field(value, "stream") == Some(ir.Boolean(True))
              let mode = case stream {
                True -> contracts.Streaming
                False -> contracts.Buffered
              }
              let session = identity <> ":" <> request_session(req)
              let request =
                contracts.Request(
                  provider,
                  account.auth_mode,
                  model,
                  case provider {
                    "claude" -> "messages"
                    "devin" -> "openai-chat"
                    "kimi" if operation == "messages" -> "anthropic"
                    "kimi" if operation == "chat/completions" -> "chat"
                    "openai-compatible-kimi" -> "chat"
                    _ -> "responses"
                  },
                  operation,
                  mode,
                  [],
                  session,
                  None,
                  body,
                )
              case provider, operation, stream {
                "claude", "messages", _
                | "claude", "messages/count_tokens", False
                -> serve_claude(req, engine, request, stream)
                "codex", "responses", _ | "codex", "responses/compact", False ->
                  serve_codex(req, config, services, identity, request, stream)
                "xai", "responses", _ | "xai", "responses/compact", False ->
                  serve_xai(req, engine, request, stream)
                "kimi", "responses", _
                | "kimi", "chat/completions", _
                | "kimi", "messages", False
                -> serve_kimi(req, config, engine, request, stream)
                "openai-compatible-kimi", "chat/completions", False ->
                  serve_kimi_compat(config, engine, request)
                "devin", "generate", False ->
                  case devin.execute(engine, None, request) {
                    Ok(body) -> reply(200, body, "application/json")
                    Error(_) -> reject(503, "provider unavailable")
                  }
                _, _, _ -> reject(422, "unsupported provider operation")
              }
            }
          }
      }
  }
}

fn serve_claude(
  incoming: Request(mist.Connection),
  engine: runtime.Runtime,
  req: contracts.Request,
  streaming: Bool,
) -> Response(mist.ResponseData) {
  let adapter = claude_transport.http(claude_adapter.prepare, None)
  case runtime.open(engine, adapter, req) {
    Error(_) -> reject(503, "provider unavailable")
    Ok(opened) ->
      case streaming {
        True ->
          case responses_http.open_sse(opened.status, opened.headers) {
            Ok(_) -> stream_claude(incoming, opened)
            Error(_) -> {
              runtime.cancel(opened.stream)
              reject(502, "invalid upstream response")
            }
          }
        False ->
          case opened.status >= 200 && opened.status < 300 {
            False -> {
              runtime.cancel(opened.stream)
              reject(502, "upstream rejected request")
            }
            True ->
              case
                read_all(opened.stream, [], 0)
                |> result.try(bit_array.to_string)
              {
                Error(_) -> reject(502, "invalid upstream response")
                Ok(body) ->
                  case strict_json.parse_native(body, 8_388_608) {
                    Error(_) -> reject(502, "invalid upstream response")
                    Ok(_) -> reply(200, body, "application/json")
                  }
              }
          }
      }
  }
}

fn stream_claude(
  req: Request(mist.Connection),
  opened: runtime.Response,
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: req,
    response: Response(200, [#("content-type", "text/event-stream")], ""),
    init: fn(subject) {
      let adopted = case runtime.adopt(opened.stream) {
        Ok(_) -> True
        Error(_) -> {
          runtime.cancel(opened.stream)
          False
        }
      }
      process.send(subject, Tick)
      ClaudeStream(opened, adopted)
    },
    loop: fn(state, _, connection) {
      case state.adopted {
        False -> mist.chunk_stop_abnormal("upstream ownership unavailable")
        True ->
          case
            claude_http.run(state.opened, fn(frame) {
              mist.send_chunk(connection, bit_array.from_string(frame))
              |> result.map(fn(_) { responses_http.Continue })
              |> result.replace_error("downstream closed")
            })
          {
            Ok(_) -> mist.chunk_stop()
            Error(_) -> mist.chunk_stop_abnormal("upstream stream failed")
          }
      }
    },
  )
}

fn serve_codex(
  incoming: Request(mist.Connection),
  config: Config,
  services: Services,
  identity: String,
  request: contracts.Request,
  streaming: Bool,
) -> Response(mist.ResponseData) {
  // Reject an unavailable continuation before runtime acquisition can refresh
  // credentials or contact an upstream. Headerless and compact stay stateless.
  let hint = case services.continuation, request.operation {
    Some(_), "responses" -> codex_session_hint(incoming)
    _, _ -> Ok(None)
  }
  case request_json.parse(request.body), hint {
    Ok(body), Ok(hint) ->
      case services.continuation, hint, request.operation {
        Some(state), Some(session), "responses" -> {
          let assert Some(catalog) = config.codex_catalog
          codex_http.serve(
            incoming,
            services.engine,
            state,
            codex.Config(identity, config.codex_user_agent, True, catalog, None),
            contracts.Request(..request, session: identity <> ":" <> session),
            streaming,
          )
        }
        _, _, _ ->
          case ir.field(body, "previous_response_id") {
            Some(_) -> reject(409, "HTTP continuation unavailable")
            None ->
              serve_codex_stateless(
                incoming,
                config,
                services.engine,
                identity,
                request,
                streaming,
              )
          }
      }
    _, _ -> reject(400, "invalid Codex request or session hint")
  }
}

fn serve_codex_stateless(
  req: Request(mist.Connection),
  config: Config,
  engine: runtime.Runtime,
  identity: String,
  request: contracts.Request,
  streaming: Bool,
) -> Response(mist.ResponseData) {
  let assert Some(catalog) = config.codex_catalog
  let plans = process.new_subject()
  let adapter_config =
    codex.Config(identity, config.codex_user_agent, True, catalog, None)
  let adapter =
    transport.http(
      fn(context, request) {
        use prepared <- result.try(codex.prepare_native(
          adapter_config,
          context,
          request,
        ))
        process.send(plans, #(context.account, prepared))
        codex.capture(context, request, prepared)
      },
      codex.rejection,
      None,
    )
  case runtime.open(engine, adapter, request) {
    Error(_) -> reject(503, "provider unavailable")
    Ok(opened) ->
      case match_plan(plans, opened.account, 0) {
        Error(_) -> {
          runtime.cancel(opened.stream)
          reject(502, "provider plan unavailable")
        }
        Ok(prepared) ->
          case request.operation, streaming {
            "responses", True ->
              case responses_http.open_sse(opened.status, opened.headers) {
                Error(_) -> {
                  runtime.cancel(opened.stream)
                  reject(502, "invalid upstream response")
                }
                Ok(_) -> stream_codex(req, opened, prepared)
              }
            "responses", False ->
              case codex_response.consume(opened, prepared) {
                Ok(codex_response.Completed(completion)) ->
                  reply(
                    200,
                    responses.encode_response(completion.response),
                    "application/json",
                  )
                Ok(codex_response.Unsuccessful(response)) ->
                  reply(
                    200,
                    responses.encode_response(response),
                    "application/json",
                  )
                _ -> reject(502, "invalid upstream response")
              }
            "responses/compact", False ->
              case read_all(opened.stream, [], 0) {
                Error(_) -> reject(502, "invalid upstream response")
                Ok(body) ->
                  case bit_array.to_string(body) {
                    Error(_) -> reject(502, "invalid upstream response")
                    Ok(text) ->
                      case
                        opened.status >= 200 && opened.status < 300,
                        responses.decode_compact_response(text)
                      {
                        True, Ok(document) ->
                          reply(
                            200,
                            responses.encode_compact_response(document),
                            "application/json",
                          )
                        _, _ -> reject(502, "invalid upstream response")
                      }
                  }
              }
            _, _ -> {
              runtime.cancel(opened.stream)
              reject(422, "unsupported operation")
            }
          }
      }
  }
}

fn serve_xai(
  req: Request(mist.Connection),
  engine: runtime.Runtime,
  request: contracts.Request,
  streaming: Bool,
) -> Response(mist.ResponseData) {
  // Both origin and credential belong to the runtime-selected account.
  // Capturing the first configured origin here breaks multi-account fallback.
  let native =
    xai.selected_http(xai_endpoint.defaults(xai_endpoint.ApiKey), None)
  let adapter =
    contracts.Adapter(..native, open: fn(context: contracts.Context, request) {
      let policy = case string.starts_with(context.origin, "http://") {
        True -> xai_endpoint.LocalMock
        False -> xai_endpoint.VerifiedTls
      }
      let settings =
        xai_endpoint.Config(
          xai_endpoint.ApiKey,
          True,
          False,
          Some(context.origin <> "/v1"),
          Some(context.origin <> "/v1"),
          None,
          policy,
        )
      // Keep restoration refs on the selected native handle. The legacy raw
      // Capture hook cannot safely restore namespaced/colliding tool names.
      xai.selected_http(settings, None).open(context, request)
    })
  case runtime.open(engine, adapter, request) {
    Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, _))
    | Error(contracts.Failure(
        contracts.InvalidConfiguration,
        contracts.NotSent,
        _,
      )) -> reject(422, "unsupported xAI request")
    Error(_) -> reject(503, "provider unavailable")
    Ok(opened) ->
      case streaming {
        True ->
          case responses_http.open_sse(opened.status, opened.headers) {
            Ok(_) -> stream_native(req, opened, xai.run)
            Error(_) -> {
              runtime.cancel(opened.stream)
              reject(502, "invalid upstream response")
            }
          }
        False ->
          case xai.collect(opened, request.operation) {
            Error(_) -> reject(502, "invalid upstream response")
            Ok(result) ->
              case bit_array.to_string(result.body) {
                Ok(body) -> reply(200, body, "application/json")
                Error(_) -> reject(502, "invalid upstream response")
              }
          }
      }
  }
}

fn serve_kimi(
  req: Request(mist.Connection),
  config: Config,
  engine: runtime.Runtime,
  request: contracts.Request,
  streaming: Bool,
) -> Response(mist.ResponseData) {
  let adapter =
    kimi_request.http_at(
      fn(context) { selected_base_path(config, context) },
      None,
    )
  case runtime.open(engine, adapter, request) {
    Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, _))
    | Error(contracts.Failure(
        contracts.InvalidConfiguration,
        contracts.NotSent,
        _,
      )) -> reject(422, "unsupported Kimi request")
    Error(_) -> reject(503, "provider unavailable")
    Ok(opened) ->
      case streaming {
        True ->
          case responses_http.open_sse(opened.status, opened.headers) {
            Ok(_) ->
              case request.operation {
                "chat/completions" ->
                  stream_encoded(req, opened, fn(response, emit) {
                    kimi.run_chat_for(response, request, fn(event) {
                      emit(chat_stream.encode_event(event))
                    })
                    |> result.map(fn(_) { Nil })
                  })
                _ ->
                  stream_native(req, opened, fn(response, emit) {
                    kimi.run_for(response, request, emit)
                  })
              }
            Error(_) -> {
              runtime.cancel(opened.stream)
              reject(502, "invalid upstream response")
            }
          }
        False ->
          case kimi.collect_for(opened, request) {
            Error(_) -> reject(502, "invalid upstream response")
            Ok(result) ->
              case bit_array.to_string(result.body) {
                Ok(body) -> reply(200, body, "application/json")
                Error(_) -> reject(502, "invalid upstream response")
              }
          }
      }
  }
}

fn selected_base_path(
  config: Config,
  context: contracts.Context,
) -> Result(String, contracts.Failure) {
  configured_account(config, context.account)
  |> result.map(fn(account) { account.base_path })
  |> result.map_error(fn(_) {
    contracts.Failure(contracts.InvalidConfiguration, contracts.NotSent, None)
  })
}

/// Generic Kimi is a separate API-key/native-Chat provider. It must not pass
/// through native Kimi model restoration, thinking policy or device identity.
fn serve_kimi_compat(
  config: Config,
  engine: runtime.Runtime,
  request: contracts.Request,
) -> Response(mist.ResponseData) {
  let adapter =
    kimi_compat.http_at(
      fn(context) { selected_base_path(config, context) },
      None,
    )
  case runtime.execute(engine, adapter, request) {
    Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, _))
    | Error(contracts.Failure(
        contracts.InvalidConfiguration,
        contracts.NotSent,
        _,
      )) -> reject(422, "unsupported generic Kimi request")
    Error(_) -> reject(503, "provider unavailable")
    Ok(opened) -> {
      let media =
        list.filter(opened.headers, fn(h) {
          string.lowercase(h.name) == "content-type"
        })
      let encoding =
        list.filter(opened.headers, fn(h) {
          string.lowercase(h.name) == "content-encoding"
        })
      let valid_media = case media {
        [media] ->
          case
            string.split(media.value, ";")
            |> list.map(fn(part) { string.lowercase(string.trim(part)) })
          {
            ["application/json"] | ["application/json", "charset=utf-8"] -> True
            _ -> False
          }
        _ -> False
      }
      let valid_encoding = case encoding {
        [] -> True
        [encoding] ->
          string.lowercase(string.trim(encoding.value)) == "identity"
        _ -> False
      }
      case
        valid_media
        && valid_encoding
        && opened.status >= 200
        && opened.status < 300
      {
        False -> reject(502, "invalid upstream response")
        True ->
          case bit_array.to_string(opened.body) {
            Error(_) -> reject(502, "invalid upstream response")
            Ok(body) ->
              case openai.decode_response(body) {
                Ok(decoded) if decoded.model == request.model ->
                  reply(opened.status, body, "application/json")
                _ -> reject(502, "invalid upstream response")
              }
          }
      }
    }
  }
}

fn stream_native(
  req: Request(mist.Connection),
  opened: runtime.Response,
  run: fn(
    runtime.Response,
    fn(responses_stream.Event) -> Result(responses_http.Control, String),
  ) -> Result(responses_stream.Outcome, contracts.Failure),
) -> Response(mist.ResponseData) {
  stream_encoded(req, opened, fn(response, emit) {
    run(response, fn(event) { emit(responses_stream.encode_event(event)) })
    |> result.map(fn(_) { Nil })
  })
}

/// One Mist ownership handoff for native SSE codecs. Provider runners retain
/// byte framing, valid-prefix/error semantics and exactly-once cancellation.
fn stream_encoded(
  req: Request(mist.Connection),
  opened: runtime.Response,
  run: fn(
    runtime.Response,
    fn(String) -> Result(responses_http.Control, String),
  ) -> Result(Nil, contracts.Failure),
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: req,
    response: Response(200, [#("content-type", "text/event-stream")], ""),
    init: fn(subject) {
      let adopted = case runtime.adopt(opened.stream) {
        Ok(_) -> True
        Error(_) -> {
          runtime.cancel(opened.stream)
          False
        }
      }
      process.send(subject, Tick)
      NativeStream(opened, adopted)
    },
    loop: fn(state, _, connection) {
      case state.adopted {
        False -> mist.chunk_stop_abnormal("upstream ownership unavailable")
        True ->
          case
            run(state.opened, fn(frame) {
              case mist.send_chunk(connection, bit_array.from_string(frame)) {
                Ok(_) -> Ok(responses_http.Continue)
                Error(_) -> Error("downstream closed")
              }
            })
          {
            Ok(_) -> mist.chunk_stop()
            Error(_) -> mist.chunk_stop_abnormal("upstream stream failed")
          }
      }
    },
  )
}

fn match_plan(
  plans: process.Subject(#(String, codex_request.Prepared)),
  account: String,
  attempts: Int,
) -> Result(codex_request.Prepared, Nil) {
  case attempts >= 64 {
    True -> Error(Nil)
    False ->
      case process.receive(plans, 1000) {
        Ok(#(id, prepared)) if id == account -> Ok(prepared)
        Ok(_) -> match_plan(plans, account, attempts + 1)
        Error(_) -> Error(Nil)
      }
  }
}

fn stream_codex(
  req: Request(mist.Connection),
  opened: runtime.Response,
  prepared: codex_request.Prepared,
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: req,
    response: Response(200, [#("content-type", "text/event-stream")], ""),
    init: fn(subject) {
      // The request handler is about to exit; transfer ownership synchronously
      // before it does. A failed transfer cannot authorize a pull or replay.
      let adopted = case runtime.adopt(opened.stream) {
        Ok(_) -> True
        Error(_) -> {
          runtime.cancel(opened.stream)
          False
        }
      }
      process.send(subject, Tick)
      CodexStream(opened, prepared, subject, adopted)
    },
    loop: fn(state, _, connection) {
      case state.adopted {
        False -> mist.chunk_stop_abnormal("upstream ownership unavailable")
        True ->
          case
            codex_response.forward(state.opened, state.prepared, fn(event) {
              case
                mist.send_chunk(
                  connection,
                  bit_array.from_string(responses_stream.encode_event(event)),
                )
              {
                Ok(_) -> Ok(responses_http.Continue)
                Error(_) -> Error("downstream closed")
              }
            })
          {
            Ok(_) -> mist.chunk_stop()
            Error(_) -> mist.chunk_stop_abnormal("upstream stream failed")
          }
      }
    },
  )
}

fn read_all(
  stream: runtime.Stream,
  chunks: List(BitArray),
  size: Int,
) -> Result(BitArray, Nil) {
  case runtime.next(stream) {
    Error(_) -> {
      runtime.cancel(stream)
      Error(Nil)
    }
    Ok(None) -> Ok(bit_array.concat(list.reverse(chunks)))
    Ok(Some(bytes)) ->
      case size + bit_array.byte_size(bytes) <= 8_388_608 {
        True ->
          read_all(stream, [bytes, ..chunks], size + bit_array.byte_size(bytes))
        False -> {
          runtime.cancel(stream)
          Error(Nil)
        }
      }
  }
}

fn bearer(req: Request(mist.Connection)) -> Result(String, Nil) {
  case request_header(req, "authorization") {
    Ok(value) ->
      case string.split_once(value, "Bearer ") {
        Ok(#("", secret)) ->
          case secret != "" && !string.contains(secret, " ") {
            True -> Ok(secret)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn request_header(
  req: Request(mist.Connection),
  name: String,
) -> Result(String, Nil) {
  case list.filter(req.headers, fn(h) { string.lowercase(h.0) == name }) {
    [#(_, value)] -> Ok(value)
    _ -> Error(Nil)
  }
}

fn request_session(req: Request(mist.Connection)) -> String {
  case request_header(req, "x-client-request-id") {
    Ok(value) ->
      case
        value != ""
        && string.byte_size(value) < 129
        && !string.contains(value, "\r")
        && !string.contains(value, "\n")
      {
        True -> value
        False -> fresh_id()
      }
    _ -> fresh_id()
  }
}

fn codex_session_hint(
  req: Request(mist.Connection),
) -> Result(Option(String), Nil) {
  use thread <- result.try(checked_session_header(req, "thread-id"))
  use request_id <- result.try(checked_session_header(
    req,
    "x-client-request-id",
  ))
  // A thread identity wins over a per-request tracing identity when both are
  // supplied. Neither is authority without the authenticated tenant and the
  // provider's current account/revision/model/origin scope.
  case thread {
    Some(_) -> Ok(thread)
    None -> Ok(request_id)
  }
}

fn checked_session_header(
  req: Request(mist.Connection),
  name: String,
) -> Result(Option(String), Nil) {
  case list.filter(req.headers, fn(h) { string.lowercase(h.0) == name }) {
    [] -> Ok(None)
    [#(_, value)] ->
      case
        value != ""
        && string.byte_size(value) <= 128
        && string.trim(value) == value
        && !string.contains(value, "\r")
        && !string.contains(value, "\n")
        && !string.contains(value, "\u{0000}")
      {
        True -> Ok(Some(value))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn reject(status: Int, message: String) -> Response(mist.ResponseData) {
  reply(
    status,
    json.object([#("error", json.string(message))]) |> json.to_string,
    "application/json",
  )
}

fn data(status: Int, body: json.Json) -> Response(mist.ResponseData) {
  reply(status, json.to_string(body), "application/json")
}

fn reply(
  status: Int,
  body: String,
  content_type: String,
) -> Response(mist.ResponseData) {
  Response(
    status,
    [#("content-type", content_type)],
    mist.Bytes(bytes_tree.from_string(body)),
  )
}

fn sanitized(value: Result(a, e)) -> Result(a, String) {
  case value {
    Ok(v) -> Ok(v)
    Error(_) -> Error("gateway configuration or private state unavailable")
  }
}

@external(erlang, "mimic_gateway_ffi", "identity")
fn verified_identity(secret: String) -> String

@external(erlang, "mimic_gateway_ffi", "fresh_id")
fn fresh_id() -> String

@external(erlang, "mimic_gateway_ffi", "private_read")
fn private_read(path: String) -> Result(BitArray, String)

@external(erlang, "mimic_gateway_ffi", "await_signal")
fn await_signal() -> Result(Nil, String)

@external(erlang, "mimic_gateway_ffi", "install_signal")
fn install_signal() -> Result(Nil, String)

@external(erlang, "mimic_gateway_ffi", "restore_signal")
fn restore_signal() -> Nil
