/// Synthetic local TLS upstream, real egress/runtime/pump. No provider calls.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request as http_request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/egress
import mimic/fleet
import mimic/ir
import mimic/protocol/responses/http as lifecycle
import mimic/providers/claude/adapter
import mimic/providers/claude/cache
import mimic/providers/claude/client_profile
import mimic/providers/claude/http
import mimic/providers/claude/identity
import mimic/providers/claude/policy
import mimic/providers/claude/request
import mimic/providers/claude/stream
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/recorder/tls
import mimic/types.{Header}
import mist
import simplifile

type Fixture

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_start")
fn fixture(
  cert: String,
  key: String,
  response: BitArray,
) -> Result(Fixture, String)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_port")
fn port(fixture: Fixture) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_requests")
fn requests(fixture: Fixture) -> List(String)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_closed")
fn closed(fixture: Fixture) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_stop")
fn stop(fixture: Fixture) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn ca_directory() -> String

fn source() {
  let assert Ok(source) =
    simplifile.read("test/fixtures/claude/policy_v1/tool_thinking.sse")
  source
}

pub fn local_auth_model_kind_normalization_wire_matrix_test() {
  let started = process.new_subject()
  let observed = process.new_subject()
  let handler = fn(req: http_request.Request(BitArray)) {
    process.send(observed, #(req.path, req.headers, req.body))
    response.new(200)
    |> response.set_header("content-type", "application/json")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string("{\"input_tokens\":7}")),
    )
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
    |> mist.read_request_body(
      bytes_limit: 8192,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(started, 5000)
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let assert Ok(client) = egress.start(origin)
  list.each(
    [
      "claude-haiku-4-5",
      "claude-opus-4-6",
      "claude-sonnet-5",
      "future-synthetic",
    ],
    fn(model) {
      list.each(
        [request.ApiKey("synthetic-key"), request.OAuth("synthetic-access")],
        fn(credential) {
          list.each(
            [policy.NativeMessages, policy.TranslatedMessages],
            fn(input) {
              list.each(
                [request.Messages(False), request.CountTokens],
                fn(operation) {
                  let source =
                    "{\"model\":\""
                    <> model
                    <> "\",\"system\":\"synthetic\",\"temperature\":1,\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"λ\",\"signature\":\"synthetic-signature\"},{\"type\":\"tool_use\",\"id\":\"synthetic-call\",\"name\":\"synthetic_tool\",\"input\":{}}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"synthetic-call\",\"content\":\"synthetic-result\",\"future\":true}]}],\"tools\":[{\"name\":\"synthetic_tool\",\"input_schema\":{\"type\":\"object\"}}]}"
                  let selected =
                    policy.Policy(
                      input,
                      policy.Conversation,
                      case input, credential {
                        policy.NativeMessages, _ -> policy.PreserveCache
                        _, request.OAuth(_) -> policy.ApprovedOneHour
                        _, _ -> policy.DefaultFiveMinutes
                      },
                    )
                  let id =
                    Some(request.Identity(
                      "synthetic-session",
                      "synthetic-request",
                      Some(identity.Account(
                        string.repeat("a", 64),
                        "synthetic-account",
                      )),
                    ))
                  let assert Ok(capture) =
                    request.prepare_with_policy(
                      origin,
                      credential,
                      operation,
                      [],
                      id,
                      source,
                      selected,
                    )
                  let assert Ok(reply) = egress.send(client, capture)
                  reply.body |> should.equal("{\"input_tokens\":7}")
                  let assert Ok(#(path, headers, bytes)) =
                    process.receive(observed, 5000)
                  path
                  |> should.equal(case operation {
                    request.CountTokens -> "/v1/messages/count_tokens"
                    _ -> "/v1/messages"
                  })
                  let assert Ok(body) = bit_array.to_string(bytes)
                  let assert Ok(body) = ir.parse(body)
                  ir.string_field(body, "model") |> should.equal(Ok(model))
                  let one_hour = case input, credential, operation {
                    policy.TranslatedMessages,
                      request.OAuth(_),
                      request.Messages(_)
                    -> True
                    _, _, _ -> False
                  }
                  cache.validate(body)
                  |> should.equal(
                    Ok(cache.Summary(
                      case input, operation {
                        policy.TranslatedMessages, request.Messages(_) -> 2
                        _, _ -> 0
                      },
                      one_hour,
                    )),
                  )
                  let beta =
                    list.key_find(headers, "anthropic-beta")
                    |> result.unwrap("")
                  string.contains(beta, "extended-cache-ttl-2025-04-11")
                  |> should.equal(one_hour)
                  let assert Some(ir.Array([assistant, user])) =
                    ir.field(body, "messages")
                  let assert Some(ir.Array([thinking, tool])) =
                    ir.field(assistant, "content")
                  ir.string_field(thinking, "signature")
                  |> should.equal(Ok("synthetic-signature"))
                  ir.string_field(tool, "id")
                  |> should.equal(Ok("synthetic-call"))
                  let assert Some(ir.Array([tool_result])) =
                    ir.field(user, "content")
                  ir.field(tool_result, "future")
                  |> should.equal(Some(ir.Boolean(True)))
                  ir.string_field(tool_result, "content")
                  |> should.equal(Ok("synthetic-result"))
                  ir.field(body, "temperature")
                  |> should.equal(case input {
                    policy.NativeMessages -> Some(ir.Integer(1))
                    _ -> None
                  })
                  case credential {
                    request.ApiKey(_) -> {
                      list.key_find(headers, "x-api-key")
                      |> should.equal(Ok("synthetic-key"))
                      list.key_find(headers, "authorization") |> should.be_error
                      ir.field(body, "metadata") |> should.equal(None)
                    }
                    request.OAuth(_) -> {
                      list.key_find(headers, "authorization")
                      |> should.equal(Ok("Bearer synthetic-access"))
                      list.key_find(headers, "x-api-key") |> should.be_error
                      case operation {
                        request.CountTokens ->
                          ir.field(body, "metadata") |> should.equal(None)
                        _ ->
                          ir.field(body, "metadata") |> should.not_equal(None)
                      }
                    }
                  }
                },
              )
            },
          )
        },
      )
    },
  )
  egress.close(client) |> should.be_ok
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

pub fn every_byte_split_tools_thinking_usage_and_malformed_prefix_test() {
  let source = source()
  let bytes = bit_array.from_string(source)
  boundaries(bit_array.byte_size(bytes), fn(split) {
    let assert Ok(a) = bit_array.slice(bytes, 0, split)
    let assert Ok(b) =
      bit_array.slice(bytes, split, bit_array.byte_size(bytes) - split)
    let first = http.feed_partial(http.new(), a)
    let assert Ok(state) = first.next
    let second = http.feed_partial(state, b)
    let assert Ok(state) = second.next
    string.join(list.append(first.frames, second.frames), "")
    |> should.equal(source)
    http.finish(state) |> should.equal(Ok(stream.Completed))
  })
  // A valid nonterminal prefix is delivered even if the same read has bad JSON.
  let prefix =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}\n\n"
  let malformed = prefix <> "data: {bad}\n\n"
  let bytes = bit_array.from_string(malformed)
  boundaries(bit_array.byte_size(bytes), fn(split) {
    let assert Ok(a) = bit_array.slice(bytes, 0, split)
    let assert Ok(b) =
      bit_array.slice(bytes, split, bit_array.byte_size(bytes) - split)
    let first = http.feed_partial(http.new(), a)
    let frames = case first.next {
      Error(_) -> first.frames
      Ok(state) -> {
        let second = http.feed_partial(state, b)
        second.next |> should.be_error
        list.append(first.frames, second.frames)
      }
    }
    string.join(frames, "") |> should.equal(prefix)
  })
  let assert Ok(#(observed, _)) = stream.feed(stream.new(), source)
  stream.usage(observed)
  |> should.equal(stream.Usage(Some(10), Some(9), Some(2), Some(3)))
}

pub fn real_tls_byte_chunks_terminal_error_cancel_cleanup_once_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let prefix =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{}}}\n\n"
  let error =
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"synthetic\"}}\n\n"
  list.each(
    [
      #(source(), False, Ok(stream.Completed)),
      #(prefix <> error, False, Ok(stream.Failed(stream.Overloaded))),
      #(prefix <> "data: {bad}\n\n", False, Error("malformed")),
      #(prefix, True, Error("cancelled")),
    ],
    fn(scenario) {
      // One-byte HTTP chunks include splits inside UTF-8 and every SSE delimiter.
      let wire = chunked(bit_array.from_string(scenario.0))
      let assert Ok(fixture) = fixture(cert, key, wire)
      let origin = "https://127.0.0.1:" <> int.to_string(port(fixture))
      let assert Ok(store) = storage.new(directory())
      credentials.save_api_key(
        store,
        credentials.key("claude", "api_key", "a"),
        "synthetic-key",
      )
      |> should.be_ok
      let assert Ok(registry) =
        registry.new([
          registry.Model(
            "claude",
            "claude-opus-4-6",
            ["api_key"],
            ["claude"],
            ["messages"],
            [contracts.Stream],
          ),
        ])
      let assert Ok(runtime) =
        runtime.start(store, registry, [
          runtime.Account(
            "claude",
            "api_key",
            "a",
            origin,
            fleet.OperatorHttps,
            1,
            ["claude-opus-4-6"],
            credentials.StaticKey,
          ),
        ])
      let prepare = fn(context, req) {
        let assert Ok(profile) =
          client_profile.from_operator(context, [
            Header("User-Agent", "synthetic-approved-client"),
            Header("X-Claude-Code-Agent-Type", "synthetic-agent"),
          ])
        adapter.prepare_with_policy(
          context,
          req,
          policy.Policy(
            policy.TranslatedMessages,
            policy.Conversation,
            policy.DefaultFiveMinutes,
          ),
          profile,
        )
      }
      let base = transport.http(prepare, adapter.rejection, Some(cert))
      let cleanup = process.new_subject()
      let counted =
        contracts.Adapter(..base, cancel: fn(handle) {
          process.send(cleanup, Nil)
          base.cancel(handle)
        })
      let req =
        contracts.Request(
          "claude",
          "api_key",
          "claude-opus-4-6",
          "claude",
          "messages",
          contracts.Streaming,
          [],
          "synthetic-session",
          None,
          "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"synthetic-call\",\"content\":\"λ\"}]}],\"stream\":true}",
        )
      let assert Ok(opened) = runtime.open(runtime, counted, req)
      let output = process.new_subject()
      let outcome =
        http.run(opened, fn(frame) {
          process.send(output, frame)
          Ok(case scenario.1 {
            True -> lifecycle.Cancel
            False -> lifecycle.Continue
          })
        })
      case scenario.2 {
        Ok(status) -> outcome |> should.equal(Ok(status))
        Error(_) -> {
          outcome |> should.be_error
          Nil
        }
      }
      let delivered = collect(output, [])
      case scenario.2 {
        Ok(_) -> string.join(delivered, "") |> should.equal(scenario.0)
        Error(_) -> delivered |> should.equal([prefix])
      }
      runtime.cancel(opened.stream)
      process.receive(cleanup, 5000) |> should.equal(Ok(Nil))
      process.receive(cleanup, 20) |> should.be_error
      runtime.active_leases(runtime) |> should.equal(Ok(0))
      await_closed(fixture, 100)
      closed(fixture) |> should.equal(1)
      let assert [sent] = requests(fixture)
      string.contains(sent, "x-api-key: synthetic-key") |> should.be_true
      string.contains(sent, "User-Agent: synthetic-approved-client")
      |> should.be_true
      string.contains(sent, "X-Claude-Code-Agent-Type: synthetic-agent")
      |> should.be_true
      string.contains(sent, "\"cache_control\":{\"type\":\"ephemeral\"}")
      |> should.be_true
      string.contains(sent, "tool_result") |> should.be_true
      runtime.stop(runtime) |> should.be_ok
      stop(fixture)
    },
  )
}

fn chunked(bytes: BitArray) -> BitArray {
  let data = byte_chunks(bytes)
  // The fixture keeps the socket open, so only terminal/cancel can finish.
  <<
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
    data:bits,
  >>
}

fn byte_chunks(bytes: BitArray) -> BitArray {
  case bytes {
    <<byte, rest:bits>> -> <<
      "1\r\n":utf8,
      byte,
      "\r\n":utf8,
      byte_chunks(rest):bits,
    >>
    _ -> <<>>
  }
}

fn collect(subject, acc) {
  case process.receive(subject, 0) {
    Ok(frame) -> collect(subject, [frame, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn boundaries(index: Int, check: fn(Int) -> Nil) {
  check(index)
  case index {
    0 -> Nil
    _ -> boundaries(index - 1, check)
  }
}

fn await_closed(fixture, remaining) {
  case closed(fixture), remaining {
    1, _ -> Nil
    _, 0 -> should.fail()
    _, _ -> {
      process.sleep(10)
      await_closed(fixture, remaining - 1)
    }
  }
}
