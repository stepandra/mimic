/// Synthetic loopback tests of the helper, not root gateway configuration or
/// native sparse-lite fidelity. Test routes stand in for authenticated scope.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response.{Response}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/gateway/codex_http
import mimic/providers/codex/adapter
import mimic/providers/codex/fixtures
import mimic/providers/codex/models
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mist

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_gateway_codex_http_test_ffi", "upstream")
fn upstream(bodies: List(String)) -> #(Int, process.Pid)

@external(erlang, "mimic_gateway_codex_http_test_ffi", "observations")
fn observations(pid: process.Pid) -> List(String)

@external(erlang, "mimic_gateway_codex_http_test_ffi", "stop")
fn stop_upstream(pid: process.Pid) -> Nil

@external(erlang, "mimic_gateway_codex_http_test_ffi", "request")
fn request(
  port: Int,
  method: String,
  path: String,
  key: String,
  body: String,
) -> String

fn credential(token: String) -> contracts.AuthMaterial {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(token, "synthetic-refresh", 9_000_000_000_000),
      [#("chatgpt_account_id", "synthetic-chatgpt-account")],
    ),
  )
}

fn setup(
  bodies: List(String),
) -> #(
  Int,
  process.Pid,
  process.Pid,
  runtime.Runtime,
  codex_http.State,
  storage.Store,
) {
  let #(upstream_port, upstream_pid) = upstream(bodies)
  let assert Ok(store) = storage.new(directory())
  runtime_store.save(
    store,
    credentials.key("codex", "oauth", "synthetic-account"),
    credential("synthetic-access"),
  )
  |> should.be_ok
  let catalog = models.pinned()
  let assert Ok(model) = models.lookup(catalog, "gpt-5.5")
  let assert Ok(registration) = adapter.registration(model)
  let assert Ok(registry) = registry.new([registration])
  let assert Ok(engine) =
    runtime.start(store, registry, [
      runtime.Account(
        "codex",
        "oauth",
        "synthetic-account",
        "http://127.0.0.1:" <> int.to_string(upstream_port),
        fleet.LocalLoopback,
        8,
        ["gpt-5.5"],
        credentials.Refreshable(
          contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
        ),
      ),
    ])
  let assert Ok(state) = codex_http.start()
  let ready = process.new_subject()
  let listener =
    mist.new(fn(incoming) {
      case mist.read_body(incoming, max_body_limit: 1_048_576) {
        Error(_) ->
          Response(413, [], mist.Bytes(bytes_tree.from_string("invalid")))
        Ok(read) -> {
          let assert Ok(body) = bit_array.to_string(read.body)
          // These fixed test routes simulate server-authenticated tenant and
          // stable session; no client header grants scope to the helper.
          let tenant = case incoming.path {
            "/other-tenant" -> "other-tenant"
            _ -> "tenant"
          }
          let session = case incoming.path {
            "/other-session" -> "other-session"
            _ -> "stable-session"
          }
          let model = case incoming.path {
            "/other-model" -> "other-model"
            _ -> "gpt-5.5"
          }
          let streaming = string.contains(body, "\"stream\":true")
          codex_http.serve(
            incoming,
            engine,
            state,
            adapter.Config(tenant, "synthetic-client", True, catalog, None),
            contracts.Request(
              "codex",
              "oauth",
              model,
              "responses",
              "responses",
              case streaming {
                True -> contracts.Streaming
                False -> contracts.Buffered
              },
              [],
              tenant <> ":" <> session,
              None,
              body,
            ),
            streaming,
          )
        }
      }
    })
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
  let assert Ok(server) = mist.start(listener)
  let assert Ok(port) = process.receive(ready, 5000)
  process.unlink(server.pid)
  #(port, server.pid, upstream_pid, engine, state, store)
}

fn cleanup(
  server: process.Pid,
  upstream_pid: process.Pid,
  engine: runtime.Runtime,
  state: codex_http.State,
) {
  process.send_exit(server)
  codex_http.stop(state) |> should.be_ok
  runtime.stop(engine) |> should.be_ok
  stop_upstream(upstream_pid)
}

fn next_sse() -> String {
  "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_next\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
  <> "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_next\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n"
}

fn followup(streaming: Bool) -> String {
  string.drop_end(fixtures.continuation, 1)
  <> case streaming {
    True -> ",\"stream\":true}"
    False -> "}"
  }
}

pub fn completed_receipt_replays_history_and_scopes_before_upstream_test() {
  let #(port, server, upstream_pid, engine, state, _) =
    setup([fixtures.sse(), next_sse()])
  let first = request(port, "POST", "/", "", fixtures.request)
  string.contains(first, "\"id\":\"resp_synthetic\"") |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(1)
  list.each(["/other-tenant", "/other-session", "/other-model"], fn(route) {
    let denied = request(port, "POST", route, "", followup(False))
    string.contains(denied, "422") |> should.be_true
  })
  list.length(observations(upstream_pid)) |> should.equal(1)
  let second = request(port, "POST", "/", "", followup(False))
  string.contains(second, "\"id\":\"resp_next\"") |> should.be_true
  let sent = observations(upstream_pid)
  list.length(sent) |> should.equal(2)
  let assert Ok(last) = list.last(sent)
  string.contains(last, "Run synthetic lookup") |> should.be_true
  string.contains(last, "synthetic-opaque-not-a-signature") |> should.be_true
  string.contains(last, "synthetic-result") |> should.be_true
  string.contains(last, "\"previous_response_id\"") |> should.be_false
  cleanup(server, upstream_pid, engine, state)
}

pub fn streaming_receipt_adopts_and_credential_replacement_denies_test() {
  let #(port, server, upstream_pid, engine, state, store) =
    setup([fixtures.sse(), next_sse()])
  let streamed =
    request(
      port,
      "POST",
      "/",
      "",
      "{\"model\":\"gpt-5.5\",\"input\":\"hello\",\"stream\":true}",
    )
  string.contains(streamed, "event: response.completed") |> should.be_true
  let prior = request(port, "POST", "/", "", followup(False))
  string.contains(prior, "\"id\":\"resp_next\"") |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(2)
  runtime_store.save(
    store,
    credentials.key("codex", "oauth", "synthetic-account"),
    credential("synthetic-access"),
  )
  |> should.be_ok
  let denied = request(port, "POST", "/", "", followup(False))
  string.contains(denied, "422") |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(2)
  cleanup(server, upstream_pid, engine, state)
}

pub fn incomplete_and_trailing_invalid_stream_never_publish_test() {
  let incomplete =
    "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_synthetic\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    <> "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_synthetic\",\"object\":\"response\",\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"synthetic-limit\"}}}\n\n"
  let #(port, server, upstream_pid, engine, state, _) =
    setup([incomplete, fixtures.sse() <> "data: {bad}\n\n"])
  let received = request(port, "POST", "/", "", fixtures.request)
  string.contains(received, "\"status\":\"incomplete\"") |> should.be_true
  string.contains(received, "synthetic-limit") |> should.be_true
  request(port, "POST", "/", "", followup(False))
  |> string.contains("422")
  |> should.be_true
  let malformed = request(port, "POST", "/", "", fixtures.request)
  string.contains(malformed, "502") |> should.be_true
  request(port, "POST", "/", "", followup(False))
  |> string.contains("422")
  |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(2)
  cleanup(server, upstream_pid, engine, state)
}

pub fn stop_and_restart_discards_receipts_test() {
  let #(port, server, upstream_pid, engine, state, _) = setup([fixtures.sse()])
  request(port, "POST", "/", "", fixtures.request)
  |> string.contains("\"id\":\"resp_synthetic\"")
  |> should.be_true
  codex_http.stop(state) |> should.be_ok
  request(port, "POST", "/", "", followup(False))
  |> string.contains("422")
  |> should.be_true
  list.length(observations(upstream_pid)) |> should.equal(1)
  let assert Ok(fresh) = codex_http.start()
  // A new State has no receipt even if the old response id is known.
  // The next root gateway listener will receive fresh instead of state.
  codex_http.stop(fresh) |> should.be_ok
  process.send_exit(server)
  runtime.stop(engine) |> should.be_ok
  stop_upstream(upstream_pid)
}
