import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri
import gleeunit
import gleeunit/should
import mimic/auth
import mimic/auth/crypto
import mimic/auth/storage
import mimic/auth/worker
import mist

pub fn main() {
  gleeunit.main()
}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn test_directory() -> String

@external(erlang, "mimic_auth_test_ffi", "mode")
fn mode(path: String) -> Int

@external(erlang, "mimic_auth_test_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "mimic_auth_test_ffi", "make_symlink")
fn make_symlink(target: String, link: String) -> Nil

fn config(port: Int) -> auth.Config {
  let endpoint = "http://127.0.0.1:" <> int.to_string(port)
  auth.claude_config(
    "synthetic-client",
    endpoint <> "/authorize",
    endpoint <> "/token",
    "http://127.0.0.1:9222/callback",
  )
}

pub fn pkce_state_and_storage_test() {
  crypto.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  |> should.equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  let assert Ok(login) =
    auth.begin_login(config(12_345), "synthetic-credential")
  login.url |> string.contains("code_challenge_method=S256") |> should.be_true
  login.url |> string.contains("state=" <> login.state) |> should.be_true
  let assert Ok(store) = storage.new(test_directory())
  let credential =
    auth.Credential("synthetic-access", "synthetic-refresh", 123_456)
  auth.save(store, "../unsafe-id", credential) |> should.equal(Ok(Nil))
  auth.load(store, "../unsafe-id") |> should.equal(Ok(credential))
  let assert Ok(metadata) = auth.list_metadata(store)
  metadata |> should.equal([auth.CredentialMetadata("../unsafe-id", 123_456)])
  mode(store.directory) |> should.equal(448)
  let filename =
    "credential-"
    <> bit_array.base64_url_encode(bit_array.from_string("../unsafe-id"), False)
    <> ".json"
  mode(store.directory <> "/" <> filename) |> should.equal(384)
  auth.delete(store, "../unsafe-id") |> should.equal(Ok(Nil))
  auth.list_metadata(store) |> should.equal(Ok([]))
}

pub fn symlink_target_is_rejected_test() {
  let assert Ok(store) = storage.new(test_directory())
  let name =
    "credential-"
    <> bit_array.base64_url_encode(bit_array.from_string("link"), False)
    <> ".json"
  make_symlink(store.directory <> "/target", store.directory <> "/" <> name)
  auth.save(store, "link", auth.Credential("synthetic", "synthetic", 0))
  |> should.equal(Error("Credential write failed"))
  auth.load(store, "link")
  |> should.equal(Error("Credential read failed"))
}

pub fn local_mock_oauth_refresh_test() {
  let port_reply = process.new_subject()
  let refresh_called = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    let body = case bit_array.to_string(req.body) {
      Ok(body) -> body
      Error(_) -> ""
    }
    let pairs = case uri.parse_query(body) {
      Ok(pairs) -> pairs
      Error(_) -> []
    }
    let grant = list.key_find(pairs, "grant_type")
    case grant {
      Ok("authorization_code") -> {
        case list.key_find(pairs, "code_verifier") {
          Ok(verifier) if verifier != "" ->
            response.new(200)
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string(
                "{\"access_token\":\"synthetic-1\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":1}",
              )),
            )
          _ ->
            response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
        }
      }
      Ok("refresh_token") -> {
        process.send(refresh_called, Nil)
        case list.key_find(pairs, "refresh_token") {
          Ok("invalid") ->
            response.new(401)
            |> response.set_body(mist.Bytes(bytes_tree.new()))
          _ ->
            response.new(200)
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string(
                "{\"access_token\":\"synthetic-2\",\"expires_in\":3600}",
              )),
            )
        }
      }
      _ -> response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(port_reply, port) })
    |> mist.read_request_body(
      bytes_limit: 4096,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(port_reply, 5000)
  let assert Ok(store) = storage.new(test_directory())
  let cfg = config(port)
  let assert Ok(login) = auth.begin_login(cfg, "synthetic")
  auth.complete_login(cfg, store, login, "wrong-state", "synthetic-code", 1000)
  |> should.equal(Error("OAuth state mismatch or missing code"))
  let assert Ok(first) =
    auth.complete_login(cfg, store, login, login.state, "synthetic-code", 1000)
  first.access_token |> should.equal("synthetic-1")
  let assert Ok(refreshed_worker) = worker.start(cfg, store, "synthetic", first)
  let replies = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(replies, worker.get(refreshed_worker, 3000))
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(replies, worker.get(refreshed_worker, 3000))
    })
  let assert Ok(Ok(second)) = process.receive(replies, 5000)
  let assert Ok(Ok(same_result)) = process.receive(replies, 5000)
  same_result |> should.equal(second)
  second.access_token |> should.equal("synthetic-2")
  second.refresh_token |> should.equal("synthetic-refresh")
  process.receive(refresh_called, 5000) |> should.equal(Ok(Nil))
  process.receive(refresh_called, 100) |> should.equal(Error(Nil))
  let assert Ok(third) = worker.get(refreshed_worker, 3000)
  third |> should.equal(second)
  auth.load(store, "synthetic") |> should.equal(Ok(second))
  let rejected = auth.Credential("expired", "invalid", 0)
  let assert Ok(blocked_worker) =
    worker.start(cfg, store, "blocked-synthetic", rejected)
  worker.get(blocked_worker, 3000)
  |> should.equal(Error("OAuth refresh requires reauthorization"))
  process.receive(refresh_called, 5000) |> should.equal(Ok(Nil))
  worker.get(blocked_worker, 4000)
  |> should.equal(Error("OAuth refresh requires reauthorization"))
  process.receive(refresh_called, 100) |> should.equal(Error(Nil))
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

pub fn refresh_backoff_test() {
  worker.backoff(1) |> should.equal(5000)
  worker.backoff(2) |> should.equal(10_000)
  worker.backoff(100) |> should.equal(300_000)
}

pub fn callback_only_timeout_rejects_duplicates_and_closes_listener_test() {
  let port = free_port()
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let cfg = auth.Config(..config(1), redirect_uri: origin <> "/callback")
  let assert Ok(login) = auth.begin_login(cfg, "synthetic")
  let seen = process.new_subject()
  auth.await_callback(cfg, login, 500, fn(_) {
    let assert Ok(duplicate) =
      request.to(
        origin
        <> "/callback?state="
        <> login.state
        <> "&state="
        <> login.state
        <> "&code=synthetic",
      )
    let assert Ok(wrong) =
      request.to(origin <> "/callback?state=wrong&code=synthetic")
    let assert Ok(a) = httpc.send(duplicate)
    let assert Ok(b) = httpc.send(wrong)
    process.send(seen, #(a.status, b.status))
  })
  |> should.equal(Error("OAuth callback timed out"))
  process.receive(seen, 1000) |> should.equal(Ok(#(400, 400)))
  // Token endpoint is unreachable; callback-only never invokes transport.
  process.sleep(20)
  let assert Ok(closed) = request.to(origin <> "/callback")
  httpc.send(closed) |> should.be_error
}

pub fn loopback_callback_state_path_and_token_exchange_test() {
  let token_port = process.new_subject()
  let token_request = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    let body = case bit_array.to_string(req.body) {
      Ok(body) -> body
      Error(_) -> ""
    }
    process.send(token_request, body)
    response.new(200)
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string(
        "{\"access_token\":\"synthetic-callback\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600}",
      )),
    )
  }
  let assert Ok(token_server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(token_port, port) })
    |> mist.read_request_body(
      bytes_limit: 4096,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(token_port, 5000)
  let callback_port = free_port()
  let cfg =
    auth.claude_config(
      "synthetic-client",
      "http://127.0.0.1:" <> int.to_string(port) <> "/authorize",
      "http://127.0.0.1:" <> int.to_string(port) <> "/token",
      "http://127.0.0.1:" <> int.to_string(callback_port) <> "/callback",
    )
  let assert Ok(store) = storage.new(test_directory())
  let callback_status = process.new_subject()
  let announce = fn(url) {
    let assert Ok(uri.Uri(query: Some(query), ..)) = uri.parse(url)
    let assert Ok(pairs) = uri.parse_query(query)
    let assert Ok(state) = list.key_find(pairs, "state")
    let origin = "http://127.0.0.1:" <> int.to_string(callback_port)
    let _ =
      process.spawn_unlinked(fn() {
        let assert Ok(wrong_path) =
          request.to(
            origin <> "/other?state=" <> state <> "&code=synthetic-code",
          )
        let assert Ok(wrong_state) =
          request.to(origin <> "/callback?state=wrong&code=synthetic-code")
        let assert Ok(valid) =
          request.to(
            origin <> "/callback?state=" <> state <> "&code=synthetic-code",
          )
        let assert Ok(a) = httpc.send(wrong_path)
        let assert Ok(b) = httpc.send(wrong_state)
        let assert Ok(c) = httpc.send(valid)
        process.send(callback_status, #(a.status, b.status, c.status))
      })
    Nil
  }
  let assert Ok(credential) =
    auth.login_with_callback(cfg, store, "cli-synthetic", 5000, announce)
  credential.access_token |> should.equal("synthetic-callback")
  let assert Ok(statuses) = process.receive(callback_status, 5000)
  statuses |> should.equal(#(400, 400, 200))
  let assert Ok(token_body) = process.receive(token_request, 5000)
  token_body |> string.contains("code_verifier=") |> should.be_true
  auth.load(store, "cli-synthetic") |> should.equal(Ok(credential))
  process.unlink(token_server.pid)
  process.send_exit(token_server.pid)
}
