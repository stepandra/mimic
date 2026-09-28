/// Synthetic localhost tests of the actual gateway, plus exhaustive split tests.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credential
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/gateway
import mimic/gateway/config
import mimic/providers/claude/http
import mimic/providers/claude/json_guard
import mimic/providers/claude/stream
import mimic/providers/contracts

@external(erlang, "mimic_gateway_test_ffi", "directory")
fn directory() -> String

@external(erlang, "mimic_gateway_test_ffi", "private_file")
fn private_file(directory: String, name: String, contents: String) -> String

@external(erlang, "mimic_gateway_test_ffi", "upstream")
fn upstream(media: String, body: String) -> #(Int, process.Pid)

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

@external(erlang, "mimic_gateway_test_ffi", "stop")
fn stop_upstream(pid: process.Pid) -> Nil

const client = "synthetic-http-client-123456789"

const model = "synthetic-claude"

const start = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"synthetic\",\"usage\":{\"input_tokens\":3}}}\n\n"

const delta = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"你好🌍\"}}\n\n"

const stop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

pub fn main() {
  every_byte_boundary_preserves_native_prefix_and_terminal_test()
  utf8_limits_crlf_disconnect_and_remote_error_test()
  actual_mist_claude_sse_api_key_and_oauth_test()
  actual_mist_refresh_persists_rotated_identity_and_restart_test()
  actual_mist_ambiguous_refresh_fences_restart_before_provider_io_test()
  actual_mist_valid_prefix_before_malformed_and_disconnect_test()
  large_native_messages_are_not_limited_by_oauth_json_budget_test()
  comment_heavy_event_uses_bounded_linear_accounting_test()
  inference_and_oauth_exact_byte_budgets_stay_separate_test()
  io.println(
    "PASS: synthetic Claude byte boundaries and actual gateway SSE/OAuth",
  )
}

pub fn large_native_messages_are_not_limited_by_oauth_json_budget_test() {
  let text = string.repeat("x", 70_000)
  let event =
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\""
    <> text
    <> "\"}}\n\n"
  let bytes = start <> event <> stop
  let batch = http.feed_partial(http.new(), bit_array.from_string(bytes))
  string.join(batch.frames, "") |> should.equal(bytes)
  let assert Ok(state) = batch.next
  http.finish(state) |> should.equal(Ok(stream.Completed))
  let body =
    "{\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\""
    <> text
    <> "\"}]}"
  let #(port, pid) = upstream("application/json", body)
  let #(_, settings) = setup("api_key", port, port, 1)
  let assert Ok(server) = gateway.start(settings)
  let response =
    request(
      gateway.port(server),
      "POST",
      "/v1/messages",
      client,
      message(False),
    )
  string.contains(response, body) |> should.be_true
  gateway.stop(server) |> should.be_ok
  stop_upstream(pid)
}

pub fn comment_heavy_event_uses_bounded_linear_accounting_test() {
  let comments = string.repeat(":x\n", 40_000) <> "\n"
  let batch =
    http.feed_partial(http.new(), bit_array.from_string(comments <> source()))
  string.join(batch.frames, "") |> should.equal(comments <> source())
  let assert Ok(state) = batch.next
  http.finish(state) |> should.equal(Ok(stream.Completed))
}

pub fn inference_and_oauth_exact_byte_budgets_stay_separate_test() {
  let native = "{\"x\":\"" <> string.repeat("x", 8_388_608 - 8) <> "\"}"
  json_guard.parse_native(native, 8_388_608) |> should.be_ok
  json_guard.parse_native(native <> " ", 8_388_608) |> should.be_error
  json_guard.parse(native) |> should.be_error
  let prefix = "event: ping\ndata: {\"type\":\"ping\",\"padding\":\""
  let suffix = "\"}\n\n"
  let count = 1_048_576 - string.byte_size(prefix) - string.byte_size(suffix)
  let event = prefix <> string.repeat("x", count) <> suffix
  let batch = http.feed_partial(http.new(), bit_array.from_string(event))
  batch.frames |> should.equal([event])
  batch.next |> should.be_ok
  let oversized = prefix <> string.repeat("x", count + 1) <> suffix
  let batch = http.feed_partial(http.new(), bit_array.from_string(oversized))
  batch.frames |> should.equal([])
  batch.next |> should.be_error
}

fn source() -> String {
  start <> delta <> stop
}

fn fold_chunks(
  chunks: List(BitArray),
) -> #(List(String), Result(http.State, String)) {
  list.fold(chunks, #([], Ok(http.new())), fn(acc, chunk) {
    case acc.1 {
      Error(_) -> acc
      Ok(state) -> {
        let batch = http.feed_partial(state, chunk)
        #(list.append(acc.0, batch.frames), batch.next)
      }
    }
  })
}

pub fn every_byte_boundary_preserves_native_prefix_and_terminal_test() {
  let good = bit_array.from_string(source())
  list.each(indices(good), fn(index) {
    let assert Ok(a) = bit_array.slice(good, 0, index)
    let assert Ok(b) =
      bit_array.slice(good, index, bit_array.byte_size(good) - index)
    let #(frames, next) = fold_chunks([a, b])
    string.join(frames, "") |> should.equal(source())
    let assert Ok(state) = next
    http.finish(state) |> should.equal(Ok(stream.Completed))
  })
  let bad =
    bit_array.from_string(
      start <> delta <> "event: message_delta\ndata: {not-json}\n\n",
    )
  list.each(indices(bad), fn(index) {
    let assert Ok(a) = bit_array.slice(bad, 0, index)
    let assert Ok(b) =
      bit_array.slice(bad, index, bit_array.byte_size(bad) - index)
    let #(frames, next) = fold_chunks([a, b])
    string.join(frames, "") |> should.equal(start <> delta)
    next |> should.be_error
  })
}

fn indices(bytes: BitArray) -> List(Int) {
  list.repeat(Nil, bit_array.byte_size(bytes) + 1)
  |> list.index_map(fn(_, index) { index })
}

pub fn utf8_limits_crlf_disconnect_and_remote_error_test() {
  let #(bom_frames, bom_state) =
    bit_array.from_string("\u{FEFF}" <> source())
    |> byte_chunks([])
    |> fold_chunks
  string.join(bom_frames, "") |> should.equal(source())
  let assert Ok(bom_state) = bom_state
  http.finish(bom_state) |> should.equal(Ok(stream.Completed))
  let prefix = bit_array.from_string(start)
  let invalid = <<prefix:bits, "data: ":utf8, 255, 10, 10>>
  let batch = http.feed_partial(http.new(), invalid)
  batch.frames |> should.equal([start])
  batch.next |> should.be_error
  let batch =
    http.feed_partial(
      http.new(),
      bit_array.from_string(start <> string.repeat("a", 1_048_577)),
    )
  batch.frames |> should.equal([start])
  batch.next |> should.be_error
  let #(frames, next) =
    source()
    |> string.replace("\n", "\r\n")
    |> bit_array.from_string
    |> byte_chunks([])
    |> fold_chunks
  string.join(frames, "") |> should.equal(source())
  let assert Ok(state) = next
  http.finish(state) |> should.equal(Ok(stream.Completed))
  let batch = http.feed_partial(http.new(), bit_array.from_string(start))
  let assert Ok(state) = batch.next
  http.finish(state) |> should.be_error
  let terminal =
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}\n\n"
  let batch =
    http.feed_partial(
      http.new(),
      bit_array.from_string(start <> terminal <> "bad trailing bytes"),
    )
  batch.frames |> should.equal([start, terminal])
  let assert Ok(state) = batch.next
  http.finish(state) |> should.equal(Ok(stream.Failed(stream.Overloaded)))
}

fn byte_chunks(bytes: BitArray, reversed: List(BitArray)) -> List(BitArray) {
  case bytes {
    <<byte, rest:bits>> -> byte_chunks(rest, [<<byte>>, ..reversed])
    _ -> list.reverse(reversed)
  }
}

fn setup(
  mode: String,
  upstream_port: Int,
  token_port: Int,
  expires: Int,
) -> #(String, config.Config) {
  let dir = directory()
  let origin = "http://127.0.0.1:" <> int.to_string(upstream_port)
  let token_origin = "http://127.0.0.1:" <> int.to_string(token_port)
  let oauth = case mode {
    "oauth" ->
      ",\"oauth\":{\"client_id\":\"synthetic-client\",\"authorize_url\":\""
      <> token_origin
      <> "/authorize\",\"token_url\":\""
      <> token_origin
      <> "/token\",\"redirect_uri\":\"http://127.0.0.1:9876/callback\"}"
    _ -> ""
  }
  let settings =
    "{\"version\":1,\"state_dir\":\""
    <> dir
    <> "\",\"listen_port\":0,\"accounts\":[{\"provider\":\"claude\",\"auth_mode\":\""
    <> mode
    <> "\",\"id\":\"account\",\"origin\":\""
    <> origin
    <> "\",\"models\":[\""
    <> model
    <> "\"]"
    <> oauth
    <> "}]}"
  let path = private_file(dir, "config.json", settings)
  let grant = case mode {
    "oauth" ->
      json.object([
        #("access_token", json.string("synthetic-old-access")),
        #("refresh_token", json.string("synthetic-old-refresh")),
        #("expires_at_ms", json.int(expires)),
        #("account_uuid", json.string("synthetic-account")),
        #("organization_uuid", json.string("synthetic-org")),
        #("device_id", json.string(string.repeat("a", 64))),
      ])
      |> json.to_string
    _ -> "{\"api_key\":\"synthetic-claude-key\"}"
  }
  let private = private_file(dir, "credential.json", grant)
  gateway.cli(["credential", "import", path, "account", private])
  |> should.be_ok
  let key = private_file(dir, "key", client)
  gateway.cli(["key", "import", path, "client", key]) |> should.be_ok
  let assert Ok(settings) = config.decode(settings)
  #(dir, settings)
}

fn message(streaming: Bool) -> String {
  "{\"model\":\""
  <> model
  <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":10,\"stream\":"
  <> case streaming {
    True -> "true}"
    False -> "false}"
  }
}

pub fn actual_mist_claude_sse_api_key_and_oauth_test() {
  list.each(["api_key", "oauth"], fn(mode) {
    let #(port, pid) = upstream("text/event-stream", source())
    let #(_, settings) = setup(mode, port, port, 9_000_000_000_000)
    let assert Ok(server) = gateway.start(settings)
    let reply =
      request(
        gateway.port(server),
        "POST",
        "/v1/messages",
        client,
        message(True),
      )
    string.contains(reply, "200") |> should.be_true
    string.contains(reply, start) |> should.be_true
    string.contains(reply, delta) |> should.be_true
    string.contains(reply, stop) |> should.be_true
    let assert [observed] = observations(pid)
    string.contains(observed, "Host: 127.0.0.1:" <> int.to_string(port))
    |> should.be_true
    string.contains(observed, client) |> should.be_false
    string.contains(observed, case mode {
      "oauth" -> "Authorization: Bearer synthetic-old-access"
      _ -> "x-api-key: synthetic-claude-key"
    })
    |> should.be_true
    gateway.stop(server) |> should.be_ok
    stop_upstream(pid)
  })
}

pub fn actual_mist_refresh_persists_rotated_identity_and_restart_test() {
  let #(port, pid) = upstream("text/event-stream", source())
  let #(token_port, token_pid) =
    upstream(
      "application/json",
      "{\"access_token\":\"synthetic-new-access\",\"refresh_token\":\"synthetic-new-refresh\",\"expires_in\":3600}",
    )
  let #(dir, settings) = setup("oauth", port, token_port, 1)
  list.each([1, 2], fn(_) {
    let assert Ok(server) = gateway.start(settings)
    let response =
      request(
        gateway.port(server),
        "POST",
        "/v1/messages",
        client,
        message(True),
      )
    string.contains(response, stop) |> should.be_true
    gateway.stop(server) |> should.be_ok
  })
  list.length(observations(token_pid)) |> should.equal(1)
  let assert Ok(store) = storage.new(dir)
  let assert Ok(contracts.OAuth(grant)) =
    runtime_store.load(store, credential.key("claude", "oauth", "account"))
  grant.credential.access_token |> should.equal("synthetic-new-access")
  list.key_find(grant.private_metadata, "account_uuid")
  |> should.equal(Ok("synthetic-account"))
  list.key_find(grant.private_metadata, "organization_uuid")
  |> should.equal(Ok("synthetic-org"))
  list.key_find(grant.private_metadata, "device_id")
  |> should.equal(Ok(string.repeat("a", 64)))
  list.each(observations(pid), fn(observed) {
    string.contains(observed, "Authorization: Bearer synthetic-new-access")
    |> should.be_true
  })
  stop_upstream(pid)
  stop_upstream(token_pid)
}

pub fn actual_mist_ambiguous_refresh_fences_restart_before_provider_io_test() {
  let #(port, pid) = upstream("text/event-stream", source())
  let #(token_port, token_pid) =
    upstream(
      "application/json",
      "{\"access_token\":\"synthetic-a\",\"access_token\":\"synthetic-b\",\"expires_in\":3600}",
    )
  let #(dir, settings) = setup("oauth", port, token_port, 1)
  list.each([1, 2], fn(_) {
    let assert Ok(server) = gateway.start(settings)
    let response =
      request(
        gateway.port(server),
        "POST",
        "/v1/messages",
        client,
        message(True),
      )
    string.contains(response, "503") |> should.be_true
    gateway.stop(server) |> should.be_ok
  })
  list.length(observations(token_pid)) |> should.equal(1)
  observations(pid) |> should.equal([])
  let assert Ok(store) = storage.new(dir)
  runtime_store.refresh_status(
    store,
    credential.key("claude", "oauth", "account"),
  )
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  stop_upstream(pid)
  stop_upstream(token_pid)
}

pub fn actual_mist_valid_prefix_before_malformed_and_disconnect_test() {
  list.each([start <> delta <> "data: {bad}\n\n", start <> delta], fn(bytes) {
    let #(port, pid) = upstream("text/event-stream", bytes)
    let #(_, settings) = setup("api_key", port, port, 1)
    let assert Ok(server) = gateway.start(settings)
    let response =
      request(
        gateway.port(server),
        "POST",
        "/v1/messages",
        client,
        message(True),
      )
    string.contains(response, start) |> should.be_true
    string.contains(response, delta) |> should.be_true
    string.contains(response, stop) |> should.be_false
    string.contains(response, "0\r\n\r\n") |> should.be_false
    list.length(observations(pid)) |> should.equal(1)
    gateway.stop(server) |> should.be_ok
    stop_upstream(pid)
  })
}
