import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/gateway
import mimic/gateway/config
import mimic/ingress/keys
import mimic/ir
import mimic/providers/codex/fixtures
import mimic/providers/codex/models
import mimic/providers/contracts
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb

@external(erlang, "mimic_gateway_test_ffi", "directory")
fn directory() -> String

@external(erlang, "mimic_gateway_test_ffi", "upstream")
fn upstream(media: String, body: String) -> #(Int, process.Pid)

@external(erlang, "mimic_gateway_test_ffi", "upstream")
fn upstream_binary(media: String, body: BitArray) -> #(Int, process.Pid)

@external(erlang, "mimic_gateway_test_ffi", "stop")
fn stop_upstream(pid: process.Pid) -> Nil

@external(erlang, "mimic_gateway_test_ffi", "request")
fn request(
  port: Int,
  method: String,
  path: String,
  key: String,
  body: String,
) -> String

@external(erlang, "mimic_gateway_test_ffi", "observations")
fn observations(pid: process.Pid) -> List(String)

@external(erlang, "mimic_gateway_test_ffi", "private_file")
fn private_file(directory: String, name: String, contents: String) -> String

@external(erlang, "mimic_gateway_test_ffi", "symlink")
fn symlink(target: String, link: String) -> Nil

const key = "synthetic-client-secret-123456789"

fn account(provider: String, mode: String, model: String, port: Int) -> String {
  json.object([
    #("provider", json.string(provider)),
    #("auth_mode", json.string(mode)),
    #("id", json.string("synthetic-account")),
    #("origin", json.string("http://127.0.0.1:" <> int.to_string(port))),
    #("models", json.array([model], json.string)),
  ])
  |> json.to_string
}

fn setup(
  provider: String,
  mode: String,
  model: String,
  upstream_port: Int,
) -> #(String, gateway.Server) {
  let state = directory()
  let assert Ok(store) = storage.new(state)
  let material = case provider {
    "codex" ->
      contracts.OAuth(
        contracts.OAuthData(
          auth.Credential(
            "synthetic-access",
            "synthetic-refresh",
            9_000_000_000_000,
          ),
          [#("chatgpt_account_id", "synthetic-chatgpt-account")],
        ),
      )
    "devin" -> contracts.SessionToken("synthetic-session-token", [])
    _ -> contracts.ApiKey("synthetic-provider-key")
  }
  runtime_store.save(
    store,
    credentials.key(provider, mode, "synthetic-account"),
    material,
  )
  |> should.be_ok
  keys.create(state, "client", key) |> should.be_ok
  let catalog = case provider {
    "codex" -> {
      let assert Ok(model) = models.lookup(models.pinned(), "gpt-5.5")
      ",\"codex_catalog\":{\"models\":[" <> ir.stringify(model.raw) <> "]}"
    }
    _ -> ""
  }
  let source =
    "{\"version\":1,\"state_dir\":\""
    <> state
    <> "\",\"listen_port\":0,\"accounts\":["
    <> account(provider, mode, model, upstream_port)
    <> "]"
    <> catalog
    <> "}"
  let assert Ok(settings) = config.decode(source)
  let assert Ok(server) = gateway.start(settings)
  #(state, server)
}

pub fn authenticated_claude_http_and_revocation_test() {
  let #(upstream_port, upstream_pid) =
    upstream("application/json", "{\"type\":\"message\",\"content\":[]}")
  let #(state, server) =
    setup("claude", "api_key", "synthetic-claude", upstream_port)
  let port = gateway.port(server)
  let body =
    "{\"model\":\"synthetic-claude\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":16}"
  let unauthorized = request(port, "POST", "/v1/messages", "", body)
  string.contains(unauthorized, "401") |> should.be_true
  let models = request(port, "GET", "/v1/models", key, "")
  string.contains(models, "synthetic-claude") |> should.be_true
  let response = request(port, "POST", "/v1/messages", key, body)
  string.contains(response, "\"type\":\"message\"") |> should.be_true
  let ambiguous =
    request(
      port,
      "POST",
      "/v1/messages",
      key,
      "{\"model\":\"synthetic-claude\",\"mo\\u0064el\":\"synthetic-claude\",\"messages\":[]}",
    )
  string.contains(ambiguous, "400") |> should.be_true
  let seen = observations(upstream_pid)
  list.length(seen) |> should.equal(1)
  string.contains(
    list.first(seen) |> should.be_ok,
    "x-api-key: synthetic-provider-key",
  )
  |> should.be_true
  keys.revoke(state, "client") |> should.be_ok
  let revoked = request(port, "POST", "/v1/messages", key, body)
  string.contains(revoked, "401") |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(1)
  gateway.stop(server) |> should.be_ok
  stop_upstream(upstream_pid)
}

pub fn codex_buffered_and_streaming_sse_over_real_mist_test() {
  let #(upstream_port, upstream_pid) =
    upstream("text/event-stream", fixtures.sse())
  let #(_, server) = setup("codex", "oauth", "gpt-5.5", upstream_port)
  let port = gateway.port(server)
  let buffered = request(port, "POST", "/v1/responses", key, fixtures.request)
  string.contains(buffered, "\"id\":\"resp_synthetic\"") |> should.be_true
  string.contains(buffered, "event:") |> should.be_false
  let streaming =
    request(
      port,
      "POST",
      "/v1/responses",
      key,
      "{\"model\":\"gpt-5.5\",\"input\":\"hello\",\"stream\":true}",
    )
  string.contains(streaming, "event: response.completed") |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(2)
  gateway.stop(server) |> should.be_ok
  stop_upstream(upstream_pid)
}

pub fn ambiguous_models_and_unimplemented_modes_fail_before_io_test() {
  let invalid =
    "{\"version\":1,\"state_dir\":\"/tmp/private\",\"listen_port\":0,\"accounts\":["
    <> account("xai", "oauth", "grok", 1)
    <> "]}"
  case config.decode(invalid) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
  let ambiguous =
    "{\"version\":1,\"state_dir\":\"/tmp/private\",\"st\\u0061te_dir\":\"/tmp/other\",\"listen_port\":0,\"accounts\":[]}"
  case config.decode(ambiguous) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}

pub fn private_import_rejects_ambiguous_credentials_and_symlinks_test() {
  let dir = directory()
  let settings =
    private_file(
      dir,
      "providers.json",
      "{\"version\":1,\"state_dir\":\""
        <> dir
        <> "\",\"listen_port\":0,\"accounts\":["
        <> account("claude", "api_key", "synthetic-claude", 1)
        <> "]}",
    )
  let duplicate =
    private_file(
      dir,
      "duplicate.json",
      "{\"api_key\":\"synthetic-one\",\"api_\\u006bey\":\"synthetic-two\"}",
    )
  case
    gateway.cli([
      "credential",
      "import",
      settings,
      "synthetic-account",
      duplicate,
    ])
  {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
  let good = private_file(dir, "good.json", "{\"api_key\":\"synthetic-one\"}")
  let link = dir <> "/link.json"
  symlink(good, link)
  case
    gateway.cli(["credential", "import", settings, "synthetic-account", link])
  {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
  gateway.cli(["credential", "import", settings, "synthetic-account", good])
  |> should.be_ok
  let assert Ok(status) =
    gateway.cli(["credential", "status", settings, "synthetic-account"])
  string.contains(status, "api_key") |> should.be_true
  gateway.cli(["credential", "delete", settings, "synthetic-account"])
  |> should.be_ok
}

pub fn codex_valid_sse_prefix_before_malformed_aborts_chunked_test() {
  let malformed =
    "event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_synthetic\",\"object\":\"response\",\"model\":\"gpt-5.5\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    <> "event: response.completed\ndata: {}\n\n"
  let #(upstream_port, upstream_pid) = upstream("text/event-stream", malformed)
  let #(_, server) = setup("codex", "oauth", "gpt-5.5", upstream_port)
  let result =
    request(
      gateway.port(server),
      "POST",
      "/v1/responses",
      key,
      "{\"model\":\"gpt-5.5\",\"input\":\"hello\",\"stream\":true}",
    )
  string.contains(result, "event: response.created") |> should.be_true
  string.contains(result, "event: response.completed") |> should.be_false
  string.contains(result, "\r\n0\r\n\r\n") |> should.be_false
  list.length(observations(upstream_pid)) |> should.equal(1)
  gateway.stop(server) |> should.be_ok
  stop_upstream(upstream_pid)
}

pub fn devin_experimental_buffered_chat_real_mist_test() {
  let payload =
    pb.encode([
      pb.text(3, "synthetic reply"),
      pb.message(7, [pb.Varint(2, 4), pb.Varint(3, 2)]),
      pb.Varint(5, 2),
    ])
  let wire = <<{ connect.envelope(payload) }:bits, 2, 2:32-big, "{}":utf8>>
  let #(upstream_port, upstream_pid) =
    upstream_binary("application/connect+proto", wire)
  let #(_, server) =
    setup("devin", "session_token", "devin/swe-1-7", upstream_port)
  let body =
    "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic hello\"}]}"
  let result =
    request(gateway.port(server), "POST", "/v1/chat/completions", key, body)
  string.contains(result, "synthetic reply") |> should.be_true
  // F23 now admits Chat SSE. Keep the no-I/O denial on unsupported Responses;
  // dedicated F23 socket/root tests cover successful Chat streaming.
  let unsupported =
    request(
      gateway.port(server),
      "POST",
      "/v1/responses",
      key,
      "{\"model\":\"devin/swe-1-7\",\"input\":\"hello\",\"stream\":true}",
    )
  string.contains(unsupported, "422") |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(1)
  gateway.stop(server) |> should.be_ok
  stop_upstream(upstream_pid)
}

pub fn xai_buffered_sse_stream_and_compact_real_mist_test() {
  let sse =
    "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_xai\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    <> "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_xai\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"total_tokens\":5}}}\n\n"
  let #(upstream_port, upstream_pid) = upstream("text/event-stream", sse)
  let #(_, server) = setup("xai", "api_key", "grok-4.7", upstream_port)
  let body = "{\"model\":\"grok-4.7\",\"input\":\"synthetic hello\"}"
  let buffered =
    request(gateway.port(server), "POST", "/v1/responses", key, body)
  string.contains(buffered, "\"id\":\"resp_synthetic_xai\"") |> should.be_true
  string.contains(buffered, "event:") |> should.be_false
  let streamed =
    request(
      gateway.port(server),
      "POST",
      "/v1/responses",
      key,
      "{\"model\":\"grok-4.7\",\"input\":\"synthetic hello\",\"stream\":true}",
    )
  string.contains(streamed, "event: response.completed") |> should.be_true
  let seen = observations(upstream_pid)
  list.length(seen) |> should.equal(2)
  string.contains(
    list.first(seen) |> should.be_ok,
    "POST /v1/responses HTTP/1.1",
  )
  |> should.be_true
  gateway.stop(server) |> should.be_ok
  stop_upstream(upstream_pid)

  let #(compact_port, compact_pid) =
    upstream(
      "application/json",
      "{\"object\":\"response.compaction\",\"id\":\"cmp_synthetic\",\"output\":[]}",
    )
  let #(_, compact_server) = setup("xai", "api_key", "grok-4.7", compact_port)
  let compact =
    request(
      gateway.port(compact_server),
      "POST",
      "/v1/responses/compact",
      key,
      body,
    )
  string.contains(compact, "\"id\":\"cmp_synthetic\"") |> should.be_true
  list.length(observations(compact_pid)) |> should.equal(1)
  gateway.stop(compact_server) |> should.be_ok
  stop_upstream(compact_pid)
}

pub fn xai_origin_is_bound_after_runtime_account_selection_test() {
  let body =
    "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_selected\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    <> "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"id\":\"resp_selected\",\"status\":\"completed\",\"output\":[]}}\n\n"
  let #(upstream_port, upstream_pid) = upstream("text/event-stream", body)
  let state = directory()
  let assert Ok(store) = storage.new(state)
  runtime_store.save(
    store,
    credentials.key("xai", "api_key", "synthetic-account"),
    contracts.ApiKey("synthetic-selected-key"),
  )
  |> should.be_ok
  keys.create(state, "client", key) |> should.be_ok
  let missing =
    account("xai", "api_key", "grok-4.7", 1)
    |> string.replace("synthetic-account", "missing-credential")
  let source =
    "{\"version\":1,\"state_dir\":\""
    <> state
    <> "\",\"listen_port\":0,\"accounts\":["
    <> missing
    <> ","
    <> account("xai", "api_key", "grok-4.7", upstream_port)
    <> "]}"
  let assert Ok(settings) = config.decode(source)
  let assert Ok(server) = gateway.start(settings)
  let result =
    request(
      gateway.port(server),
      "POST",
      "/v1/responses",
      key,
      "{\"model\":\"grok-4.7\",\"input\":\"synthetic hello\"}",
    )
  let seen = observations(upstream_pid)
  gateway.stop(server) |> should.be_ok
  stop_upstream(upstream_pid)
  string.starts_with(result, "HTTP/1.1 200") |> should.be_true
  list.length(seen) |> should.equal(1)
  let assert Ok(raw) = list.first(seen)
  string.contains(raw, "Host: 127.0.0.1:" <> int.to_string(upstream_port))
  |> should.be_true
  string.contains(raw, "Authorization: Bearer synthetic-selected-key")
  |> should.be_true
}
