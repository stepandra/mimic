/// Actual gateway.start routes and synthetic loopback wire observations.
/// main is the native/default gate. coordinator is deliberately a separate
/// acceptance entrypoint for the parent's real root policy/config patch.
import claude_f09_test as f09
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/egress
import mimic/gateway
import mimic/gateway/config
import mimic/ir
import mimic/providers/claude/cache
import mimic/providers/claude/policy
import mimic/providers/claude/request
import mimic/types.{type Header, Capture, Header, Transport}

type Fixture

@external(erlang, "mimic_claude_429_test_ffi", "start")
fn upstream(responses: List(BitArray)) -> Fixture

@external(erlang, "mimic_claude_429_test_ffi", "port")
fn upstream_port(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_429_test_ffi", "requests")
fn observations(fixture: Fixture) -> List(String)

@external(erlang, "mimic_claude_429_test_ffi", "stop")
fn stop_upstream(fixture: Fixture) -> Nil

@external(erlang, "mimic_gateway_test_ffi", "directory")
fn directory() -> String

@external(erlang, "mimic_gateway_test_ffi", "private_file")
fn private_file(dir: String, name: String, content: String) -> String

@external(erlang, "mimic_gateway_ffi", "identity")
fn client_identity(secret: String) -> String

const client = "synthetic-f09-client-123456789"

const other = "synthetic-f09-other-client-123456789"

const minimal = "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}]}"

const count = "{\"input_tokens\":137,\"future\":\"synthetic-endpoint-response\"}"

const message = "{\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"synthetic-endpoint-response\"}]}"

pub fn main() {
  run_goldens(False)
  route_matrix(False)
  client_isolation()
  invalid_layout_routes(False)
  io.println(
    "PASS F09 actual native/default gateway; synthetic, not CPA/native/live",
  )
}

/// Running on the old root MUST fail: no adapter closure substitutes for
/// actual config.decode, gateway.start, selected account and endpoint handling.
pub fn coordinator() {
  run_goldens(True)
  configured_auth_beta_positions()
  route_matrix(True)
  forbidden_operator_headers()
  selected_account_routes()
  invalid_layout_routes(True)
  io.println("PASS F09 actual configured gateway matrix")
}

fn run_goldens(configured: Bool) {
  let cases =
    f09.goldens()
    |> list.filter(fn(g) { configured || g.selected == policy.native() })
  list.each(cases, fn(golden) {
    // Each fixed expectation is authored for one auth mode. Changing auth can
    // preserve an existing OAuth beta in place, not simply insert it at the
    // front. Cross-auth coverage uses independent explicit vectors below.
    list.each([golden.auth], fn(auth) {
      case
        golden.selected.cache == policy.ApprovedOneHour && auth == "api_key"
      {
        True -> Nil
        False -> {
          let ops = case golden.operation {
            request.Messages(_) -> [
              request.Messages(False),
              request.Messages(True),
            ]
            _ -> [request.CountTokens]
          }
          list.each(ops, fn(op) {
            let #(fixture, server) =
              start(auth, golden.source, op, case configured {
                True -> policy_json(golden.selected, golden.headers)
                False -> ""
              })
            let reply =
              send(
                gateway.port(server),
                op,
                mode_body(golden.source, op),
                True,
                client,
              )
            reply.status |> should.equal(200)
            assert_reply(reply.body, op, field(parse(golden.source), "model"))
            let assert [raw] = observations(fixture)
            let body = parse(raw_body(raw))
            equivalent(
              policy.remove(policy.remove(body, "stream"), "metadata"),
              policy.remove(
                policy.remove(parse(golden.body), "stream"),
                "metadata",
              ),
            )
            |> should.be_true
            assert_identity(raw, body, auth, op, "account", client)
            assert_unapproved_hints(raw)
            case configured {
              True -> {
                beta(raw) |> should.equal(golden.beta)
                list.each(golden.headers, fn(h) {
                  case string.lowercase(h.name) == "anthropic-beta" {
                    True -> Nil
                    False ->
                      string.contains(raw, h.name <> ": " <> h.value)
                      |> should.be_true
                  }
                })
              }
              False -> Nil
            }
            close(fixture, server)
            io.println(
              "F09 golden route: "
              <> golden.id
              <> "/"
              <> auth
              <> "/"
              <> op_name(op),
            )
          })
        }
      }
    })
  })
}

fn configured_auth_beta_positions() {
  let assert Ok(golden) =
    list.find(f09.goldens(), fn(golden) {
      golden.id == "header-before-body-dedup-api-key"
    })
  list.each(
    [
      #("api_key", "claude-code-20250219,future-a,effort-2025-11-24,future-b"),
      #(
        "oauth",
        "claude-code-20250219,future-a,oauth-2025-04-20,effort-2025-11-24,future-b",
      ),
    ],
    fn(vector) {
      list.each([request.Messages(False), request.Messages(True)], fn(op) {
        let #(fixture, server) =
          start(
            vector.0,
            golden.source,
            op,
            policy_json(golden.selected, golden.headers),
          )
        let reply =
          send(
            gateway.port(server),
            op,
            mode_body(golden.source, op),
            True,
            client,
          )
        reply.status |> should.equal(200)
        let assert [raw] = observations(fixture)
        beta(raw) |> should.equal(vector.1)
        assert_identity(
          raw,
          parse(raw_body(raw)),
          vector.0,
          op,
          "account",
          client,
        )
        assert_unapproved_hints(raw)
        close(fixture, server)
      })
    },
  )
}

/// Endpoint × selected auth × caller/approved hints × turn × cache.
/// Fixed expectations are not generated by request.prepare under test.
fn route_matrix(configured: Bool) {
  let source =
    "{\"model\":\"claude-opus-4-6\",\"system\":\"synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}],\"temperature\":0.4,\"top_p\":0.2,\"top_k\":3,\"thinking\":{\"type\":\"adaptive\"},\"tool_choice\":{\"type\":\"tool\",\"name\":\"synthetic\"},\"output_config\":{\"effort\":\"high\",\"future\":7},\"betas\":[\"future-body\"],\"max_tokens\":20,\"metadata\":{\"future\":true},\"context_management\":{},\"diagnostics\":{}}"
  let turns = case configured {
    True -> [policy.Conversation, policy.Subagent, policy.Helper]
    False -> [policy.Conversation]
  }
  let caches = case configured {
    True -> [
      policy.PreserveCache,
      policy.DefaultFiveMinutes,
      policy.ApprovedOneHour,
    ]
    False -> [policy.PreserveCache]
  }
  list.each(["api_key", "oauth"], fn(auth) {
    list.each(operations(), fn(op) {
      list.each([False, True], fn(hints) {
        list.each(turns, fn(turn) {
          list.each(caches, fn(cache_) {
            let selected =
              policy.Policy(
                case configured {
                  True -> policy.TranslatedMessages
                  False -> policy.NativeMessages
                },
                turn,
                cache_,
              )
            let headers = case configured && hints {
              True -> [
                Header("X-Claude-Code-Agent-Type", "synthetic-approved"),
                Header("anthropic-beta", "future-approved"),
              ]
              False -> []
            }
            let fixture = upstream([upstream_response(op, "claude-opus-4-6")])
            let decoded =
              setup(auth, source, upstream_port(fixture), case configured {
                True -> policy_json(selected, headers)
                False -> ""
              })
            case
              configured
              && cache_ == policy.ApprovedOneHour
              && { auth == "api_key" || turn == policy.Helper }
            {
              True -> {
                decoded |> should.be_error
                observations(fixture) |> should.equal([])
              }
              False -> {
                let assert Ok(settings) = decoded
                let assert Ok(server) = gateway.start(settings)
                let reply =
                  send(
                    gateway.port(server),
                    op,
                    mode_body(source, op),
                    hints,
                    client,
                  )
                reply.status |> should.equal(200)
                assert_reply(reply.body, op, "claude-opus-4-6")
                let assert [raw] = observations(fixture)
                let body = parse(raw_body(raw))
                assert_identity(raw, body, auth, op, "account", client)
                assert_unapproved_hints(raw)
                let prefix = case op, configured {
                  request.CountTokens, True ->
                    "claude-code-20250219,"
                    <> case auth {
                      "oauth" -> "oauth-2025-04-20,"
                      _ -> ""
                    }
                    <> "interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01,"
                  _, _ ->
                    case auth {
                      "oauth" -> "oauth-2025-04-20,"
                      _ -> ""
                    }
                }
                beta(raw)
                |> should.equal(
                  prefix
                  <> case configured && hints {
                    True -> "future-approved,"
                    False -> ""
                  }
                  <> "future-body"
                  <> case op, configured, cache_ {
                    request.CountTokens, False, _ ->
                      ",token-counting-2024-11-01"
                    request.Messages(_), True, policy.ApprovedOneHour ->
                      ",extended-cache-ttl-2025-04-11"
                    _, _, _ -> ""
                  },
                )
                let generated =
                  configured
                  && cache_ != policy.PreserveCache
                  && op != request.CountTokens
                cache.validate(body)
                |> should.equal(
                  Ok(cache.Summary(
                    case generated {
                      True -> 2
                      False -> 0
                    },
                    generated && cache_ == policy.ApprovedOneHour,
                  )),
                )
                case op {
                  request.CountTokens -> {
                    list.each(
                      [
                        "stream",
                        "max_tokens",
                        "metadata",
                        "context_management",
                        "diagnostics",
                      ],
                      fn(key) { ir.field(body, key) |> should.equal(None) },
                    )
                    list.each(
                      [
                        "thinking",
                        "tool_choice",
                        "output_config",
                        "temperature",
                        "top_p",
                        "top_k",
                      ],
                      fn(key) {
                        equivalent_field(body, parse(source), key)
                        |> should.be_true
                      },
                    )
                  }
                  _ -> {
                    ir.field(body, "thinking") |> should.equal(None)
                    ir.field(body, "temperature")
                    |> should.equal(case configured {
                      True -> None
                      False -> Some(ir.Decimal(0.4))
                    })
                    ir.field(body, "top_p") |> should.equal(None)
                    ir.field(body, "top_k") |> should.equal(Some(ir.Integer(3)))
                    let assert Ok(output) = ir.required(body, "output_config")
                    ir.field(output, "effort") |> should.equal(None)
                    ir.field(output, "future")
                    |> should.equal(Some(ir.Integer(7)))
                  }
                }
                gateway.stop(server) |> should.be_ok
              }
            }
            stop_upstream(fixture)
            io.println(
              "F09 matrix route: "
              <> auth
              <> "/"
              <> op_name(op)
              <> "/"
              <> turn_name(turn)
              <> "/"
              <> cache_name(cache_),
            )
          })
        })
      })
    })
  })
}

fn forbidden_operator_headers() {
  let bad =
    list.map(
      [
        "Authorization",
        "x-api-key",
        "Host",
        "Content-Length",
        "Content-Type",
        "Accept",
        "Accept-Encoding",
        "Connection",
        "Transfer-Encoding",
        "Cookie",
        "X-Claude-Code-Session-Id",
        "x-client-request-id",
      ],
      fn(name) { [Header(name, "synthetic-forbidden")] },
    )
  let bad =
    list.append(bad, [
      [Header("User-Agent", "a"), Header("user-agent", "b")],
      [Header("User-Agent", "synthetic\r\nInjected: true")],
      [Header("User-Agent", "synthetic\u{007f}")],
    ])
  list.each(["api_key", "oauth"], fn(auth) {
    list.each(bad, fn(headers) {
      let fixture =
        upstream([upstream_response(request.CountTokens, "claude-opus-4-6")])
      setup(
        auth,
        minimal,
        upstream_port(fixture),
        policy_json(policy.native(), headers),
      )
      |> should.be_error
      observations(fixture) |> should.equal([])
      stop_upstream(fixture)
    })
  })
}

/// Two same-model accounts with distinct origins/profile/policy and credentials.
/// Third request is sticky to A; second authenticated client selects B.
fn selected_account_routes() {
  list.each(["api_key", "oauth"], fn(auth) {
    list.each(operations(), fn(op) {
      let a = upstream([upstream_response(op, "claude-opus-4-6")])
      let b = upstream([upstream_response(op, "claude-opus-4-6")])
      let dir = directory()
      let source =
        "{\"model\":\"claude-opus-4-6\",\"system\":\"synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"λ\"}],\"temperature\":0.4}"
      let entries =
        list.map([#("a", a), #("b", b)], fn(pair) {
          account_json(
            auth,
            pair.0,
            upstream_port(pair.1),
            "claude-opus-4-6",
            policy_json(
              case pair.0 {
                "a" -> policy.native()
                _ ->
                  policy.Policy(
                    policy.TranslatedMessages,
                    policy.Conversation,
                    policy.DefaultFiveMinutes,
                  )
              },
              [Header("X-App", "synthetic-profile-" <> pair.0)],
            ),
          )
        })
      let json = settings_json(dir, entries)
      let assert Ok(settings) = config.decode(json)
      let path = private_file(dir, "config.json", json)
      list.each(["a", "b"], fn(id) { import_credential(dir, path, auth, id) })
      import_key(dir, path, "client", client)
      import_key(dir, path, "other", other)
      let assert Ok(server) = gateway.start(settings)
      list.each([client, other, client], fn(key) {
        send(gateway.port(server), op, mode_body(source, op), True, key).status
        |> should.equal(200)
      })
      let assert [first, third] = observations(a)
      let assert [second] = observations(b)
      list.each(
        [#("a", first, client), #("b", second, other), #("a", third, client)],
        fn(row) {
          let body = parse(raw_body(row.1))
          assert_identity(row.1, body, auth, op, row.0, row.2)
          header(row.1, "x-app") |> should.equal("synthetic-profile-" <> row.0)
          cache.validate(body)
          |> should.equal(
            Ok(cache.Summary(
              case row.0, op {
                "b", request.Messages(_) -> 2
                _, _ -> 0
              },
              False,
            )),
          )
          ir.field(body, "temperature")
          |> should.equal(case row.0, op {
            "b", request.Messages(_) -> None
            _, _ -> Some(ir.Decimal(0.4))
          })
        },
      )
      header(first, "x-claude-code-session-id")
      |> should.equal(header(third, "x-claude-code-session-id"))
      header(first, "x-claude-code-session-id")
      |> should.not_equal(header(second, "x-claude-code-session-id"))
      header(first, "x-client-request-id")
      |> should.not_equal(header(third, "x-client-request-id"))
      gateway.stop(server) |> should.be_ok
      stop_upstream(a)
      stop_upstream(b)
      io.println("F09 selected-account route: " <> auth <> "/" <> op_name(op))
    })
  })
}

fn client_isolation() {
  list.each(["api_key", "oauth"], fn(auth) {
    let fixture =
      upstream([upstream_response(request.Messages(False), "claude-opus-4-6")])
    let assert Ok(settings) = setup(auth, minimal, upstream_port(fixture), "")
    import_key(
      settings.state_dir,
      settings.state_dir <> "/config.json",
      "other",
      other,
    )
    let assert Ok(server) = gateway.start(settings)
    list.each([client, other, client], fn(key) {
      send(gateway.port(server), request.Messages(False), minimal, True, key).status
      |> should.equal(200)
    })
    let assert [first, second, third] = observations(fixture)
    list.each([#(first, client), #(second, other), #(third, client)], fn(row) {
      assert_identity(
        row.0,
        parse(raw_body(row.0)),
        auth,
        request.Messages(False),
        "account",
        row.1,
      )
    })
    header(first, "x-claude-code-session-id")
    |> should.equal(header(third, "x-claude-code-session-id"))
    header(first, "x-claude-code-session-id")
    |> should.not_equal(header(second, "x-claude-code-session-id"))
    header(first, "x-client-request-id")
    |> should.not_equal(header(third, "x-client-request-id"))
    close(fixture, server)
  })
}

fn invalid_layout_routes(helper: Bool) {
  let short = "{\"type\":\"text\",\"cache_control\":{\"type\":\"ephemeral\"}}"
  let long =
    "{\"type\":\"text\",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}}"
  let layouts = case helper {
    True -> ["\"system\":[" <> long <> "]"]
    False -> [
      "\"tools\":[" <> short <> "],\"system\":[" <> long <> "]",
      "\"system\":[" <> string.join(list.repeat(short, 5), ",") <> "]",
      "\"system\":[{\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"2h\"}}]",
      "\"system\":{\"cache_control\":{\"type\":\"ephemeral\"}}",
      "\"cache_control\":{\"type\":\"ephemeral\"}",
    ]
  }
  list.each(["api_key", "oauth"], fn(auth) {
    list.each(operations(), fn(op) {
      let #(fixture, server) =
        start(auth, minimal, op, case helper {
          True ->
            policy_json(
              policy.Policy(
                policy.TranslatedMessages,
                policy.Helper,
                policy.DefaultFiveMinutes,
              ),
              [],
            )
          False -> ""
        })
      list.each(layouts, fn(layout) {
        let source = string.drop_end(minimal, 1) <> "," <> layout <> "}"
        send(gateway.port(server), op, mode_body(source, op), True, client).status
        |> should.equal(503)
        observations(fixture) |> should.equal([])
      })
      close(fixture, server)
    })
  })
}

fn start(auth, source, op, extra) {
  let fixture = upstream([upstream_response(op, field(parse(source), "model"))])
  let assert Ok(settings) = setup(auth, source, upstream_port(fixture), extra)
  let assert Ok(server) = gateway.start(settings)
  #(fixture, server)
}

fn setup(auth, source, port, extra) {
  let dir = directory()
  let json =
    settings_json(dir, [
      account_json(auth, "account", port, field(parse(source), "model"), extra),
    ])
  use decoded <- result.try(config.decode(json))
  let path = private_file(dir, "config.json", json)
  import_credential(dir, path, auth, "account")
  import_key(dir, path, "client", client)
  Ok(decoded)
}

fn settings_json(dir, entries) {
  "{\"version\":1,\"state_dir\":\""
  <> dir
  <> "\",\"listen_port\":0,\"accounts\":["
  <> string.join(entries, ",")
  <> "]}"
}

fn account_json(auth, id, port, model, extra) {
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  "{\"provider\":\"claude\",\"auth_mode\":\""
  <> auth
  <> "\",\"id\":\""
  <> id
  <> "\",\"origin\":\""
  <> origin
  <> "\",\"models\":["
  <> ir.stringify(ir.String(model))
  <> "]"
  <> case auth {
    "oauth" ->
      ",\"oauth\":{\"client_id\":\"synthetic-client\",\"authorize_url\":\""
      <> origin
      <> "/authorize\",\"token_url\":\""
      <> origin
      <> "/token\",\"redirect_uri\":\"http://127.0.0.1:9876/callback\"}"
    _ -> ""
  }
  <> extra
  <> "}"
}

fn import_credential(dir, path, auth, id) {
  let #(token, account, device) = case id {
    "account" -> #(
      "synthetic-access",
      "synthetic-account",
      string.repeat("a", 64),
    )
    _ -> #(
      "synthetic-" <> id,
      "synthetic-account-" <> id,
      string.repeat(id, 64),
    )
  }
  let grant = case auth {
    "oauth" ->
      "{\"access_token\":\""
      <> token
      <> "\",\"refresh_token\":\"synthetic-refresh\",\"expires_at_ms\":4102444800000,\"device_id\":\""
      <> device
      <> "\",\"account_uuid\":\""
      <> account
      <> "\"}"
    _ ->
      "{\"api_key\":\""
      <> case id {
        "account" -> "synthetic-key"
        _ -> token
      }
      <> "\"}"
  }
  let credential = private_file(dir, id <> ".json", grant)
  gateway.cli(["credential", "import", path, id, credential]) |> should.be_ok
}

fn import_key(dir, path, id, key) {
  let file = private_file(dir, id <> ".key", key)
  gateway.cli(["key", "import", path, id, file]) |> should.be_ok
}

fn send(port, op, body, hints, key) {
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(client_) = egress.start(origin)
  let capture =
    Capture(
      "claude",
      "synthetic-f09-downstream",
      origin,
      "request",
      "POST",
      case op {
        request.CountTokens -> "/v1/messages/count_tokens"
        _ -> "/v1/messages"
      },
      "HTTP/1.1",
      list.append(
        [
          Header("Host", "127.0.0.1:" <> int.to_string(port)),
          Header("Authorization", "Bearer " <> key),
          Header("Content-Type", "application/json"),
          Header("x-client-request-id", "synthetic-unapproved-request"),
          Header("Content-Length", int.to_string(string.byte_size(body))),
        ],
        case hints {
          True -> [
            Header("User-Agent", "synthetic-unapproved-client"),
            Header("X-Claude-Code-Agent-Type", "synthetic-unapproved-helper"),
            Header("X-Claude-Code-Request-Class", "synthetic-unapproved-class"),
            Header("X-Claude-Code-Session-Id", "synthetic-unapproved-session"),
            Header("anthropic-beta", "synthetic-unapproved-beta"),
          ]
          False -> []
        },
      ),
      body,
      Transport("http/1.1", None),
    )
  let assert Ok(reply) = egress.send(client_, capture)
  egress.close(client_) |> should.be_ok
  reply
}

fn close(fixture, server) {
  gateway.stop(server) |> should.be_ok
  stop_upstream(fixture)
}

fn upstream_response(op, model) {
  let body = case op {
    request.Messages(True) ->
      "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":"
      <> ir.stringify(ir.String(model))
      <> ",\"usage\":{\"input_tokens\":7}}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    request.CountTokens -> count
    _ -> message
  }
  bit_array.from_string(
    "HTTP/1.1 200 OK\r\nContent-Type: "
    <> case op {
      request.Messages(True) -> "text/event-stream"
      _ -> "application/json"
    }
    <> "\r\nContent-Length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\n\r\n"
    <> body,
  )
}

fn assert_reply(body, op, model) {
  case op {
    request.CountTokens -> body |> should.equal(count)
    request.Messages(False) -> body |> should.equal(message)
    request.Messages(True) -> {
      string.contains(body, "message_start") |> should.be_true
      string.contains(body, "message_stop") |> should.be_true
      string.contains(body, "\"model\":" <> ir.stringify(ir.String(model)))
      |> should.be_true
    }
  }
}

fn assert_identity(raw, body, auth, op, id, key) {
  let session = header(raw, "x-claude-code-session-id")
  let assert ir.Array([ir.String(account), ir.String(correlation)]) =
    parse(session)
  parse(account)
  |> should.equal(
    ir.Array([ir.String("claude"), ir.String(auth), ir.String(id)]),
  )
  correlation
  |> should.equal(client_identity(key) <> ":synthetic-unapproved-request")
  header(raw, "x-client-request-id") |> should.not_equal("")
  let token = case id {
    "account" -> "synthetic-access"
    _ -> "synthetic-" <> id
  }
  case auth {
    "api_key" -> {
      header(raw, "x-api-key")
      |> should.equal(case id {
        "account" -> "synthetic-key"
        _ -> token
      })
      header(raw, "authorization") |> should.equal("")
    }
    _ -> {
      header(raw, "authorization") |> should.equal("Bearer " <> token)
      header(raw, "x-api-key") |> should.equal("")
      case op {
        request.CountTokens -> ir.field(body, "metadata") |> should.equal(None)
        _ -> {
          let assert Ok(metadata) = ir.required(body, "metadata")
          let user = parse(field(metadata, "user_id"))
          field(user, "session_id") |> should.equal(session)
          field(user, "account_uuid")
          |> should.equal(case id {
            "account" -> "synthetic-account"
            _ -> "synthetic-account-" <> id
          })
          field(user, "device_id")
          |> should.equal(string.repeat(
            case id {
              "account" -> "a"
              _ -> id
            },
            64,
          ))
        }
      }
    }
  }
  header(raw, "content-length")
  |> should.equal(int.to_string(string.byte_size(raw_body(raw))))
  string.contains(raw, key) |> should.be_false
}

fn assert_unapproved_hints(raw) {
  list.each(
    [
      #("user-agent", "synthetic-unapproved-client"),
      #("x-claude-code-agent-type", "synthetic-unapproved-helper"),
      #("x-claude-code-request-class", "synthetic-unapproved-class"),
      #("x-client-request-id", "synthetic-unapproved-request"),
      #("x-claude-code-session-id", "synthetic-unapproved-session"),
    ],
    fn(pair) { header(raw, pair.0) |> should.not_equal(pair.1) },
  )
  string.contains(beta(raw), "synthetic-unapproved-beta") |> should.be_false
}

fn header(raw, name) {
  let assert [headers, ..] = string.split(raw, "\r\n\r\n")
  headers
  |> string.split("\r\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, ": ") {
      Ok(#(key, value)) ->
        case string.lowercase(key) == name {
          True -> Ok(value)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

fn beta(raw) {
  header(raw, "anthropic-beta")
}

fn raw_body(raw) {
  let assert Ok(#(_, body)) = string.split_once(raw, "\r\n\r\n")
  body
}

fn mode_body(source, op) {
  case op {
    request.Messages(True) ->
      ir.stringify(policy.set(parse(source), "stream", ir.Boolean(True)))
    _ -> source
  }
}

fn policy_json(selected: policy.Policy, headers: List(Header)) {
  ",\"claude_policy\":{\"input\":\""
  <> case selected.input {
    policy.NativeMessages -> "native"
    _ -> "translated"
  }
  <> "\",\"turn\":\""
  <> turn_name(selected.turn)
  <> "\",\"cache\":\""
  <> cache_name(selected.cache)
  <> "\"},\"claude_client_headers\":"
  <> ir.stringify(
    ir.Array(
      list.map(headers, fn(h) {
        ir.Array([ir.String(h.name), ir.String(h.value)])
      }),
    ),
  )
}

fn turn_name(turn) {
  case turn {
    policy.Conversation -> "conversation"
    policy.Subagent -> "subagent"
    policy.Helper -> "helper"
  }
}

fn cache_name(cache_) {
  case cache_ {
    policy.PreserveCache -> "preserve"
    policy.DefaultFiveMinutes -> "5m"
    policy.ApprovedOneHour -> "1h"
  }
}

fn op_name(op) {
  case op {
    request.Messages(False) -> "messages"
    request.Messages(True) -> "sse"
    request.CountTokens -> "count"
  }
}

fn operations() {
  [request.Messages(False), request.Messages(True), request.CountTokens]
}

fn parse(source) {
  let assert Ok(body) = ir.parse(source)
  body
}

fn field(body, key) {
  let assert Ok(value) = ir.string_field(body, key)
  value
}

fn equivalent_field(a, b, key) {
  case ir.field(a, key), ir.field(b, key) {
    Some(a), Some(b) -> equivalent(a, b)
    None, None -> True
    _, _ -> False
  }
}

fn equivalent(a, b) {
  case a, b {
    ir.Object(a), ir.Object(b) ->
      list.length(a) == list.length(b)
      && list.all(a, fn(pair) {
        case list.key_find(b, pair.0) {
          Ok(value) -> equivalent(pair.1, value)
          _ -> False
        }
      })
    ir.Array(a), ir.Array(b) ->
      list.length(a) == list.length(b)
      && list.all(list.zip(a, b), fn(pair) { equivalent(pair.0, pair.1) })
    _, _ -> a == b
  }
}
