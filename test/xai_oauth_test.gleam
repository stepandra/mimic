import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/uri
import gleeunit/should
import mimic/auth
import mimic/providers/xai/endpoint
import mimic/providers/xai/oauth
import mist

fn config() {
  oauth.Config("http://127.0.0.1:8765/discovery", endpoint.LocalMock)
}

fn discovery() {
  oauth.Discovery("http://127.0.0.1:8765/device", "http://127.0.0.1:8765/token")
}

fn reply(status: Int, body: String) {
  response.new(status) |> response.set_body(body) |> Ok
}

fn device_body(verification: String) {
  json.object([
    #("device_code", json.string("synthetic-device-private")),
    #("user_code", json.string("SYNTHETIC")),
    #("verification_uri", json.string(verification)),
    #("expires_in", json.int(600)),
  ])
  |> json.to_string
}

fn device() {
  let assert Ok(device) =
    oauth.start(
      config(),
      discovery(),
      fn(_) { reply(200, device_body("http://127.0.0.1:8765/verify")) },
      1000,
    )
  device
}

pub fn poll_timing_cancel_and_expiry_test() {
  let cfg = config()
  let device = device()
  let calls = process.new_subject()
  let send = fn(_) {
    process.send(calls, Nil)
    reply(400, "{\"error\":\"authorization_pending\"}")
  }
  let assert Ok(oauth.Pending(pending, wait)) =
    oauth.poll(cfg, device, send, 1000, False)
  wait |> should.equal(5000)
  process.receive(calls, 100) |> should.equal(Ok(Nil))
  let assert Ok(oauth.Pending(_, wait)) =
    oauth.poll(cfg, pending, send, 2000, False)
  wait |> should.equal(4000)
  process.receive(calls, 0) |> should.be_error
  let slow = fn(_) { reply(400, "{\"error\":\"slow_down\"}") }
  let assert Ok(oauth.Pending(slower, wait)) =
    oauth.poll(cfg, pending, slow, 6000, False)
  wait |> should.equal(10_000)
  oauth.poll(cfg, slower, send, 16_000, True)
  |> should.equal(Error("xAI device authorization cancelled"))
  oauth.poll(cfg, slower, send, 601_000, False)
  |> should.equal(Error("xAI device authorization expired"))
  process.receive(calls, 0) |> should.be_error
}

pub fn oauth_errors_do_not_echo_secrets_test() {
  let cfg = config()
  let device = device()
  oauth.poll(
    cfg,
    device,
    fn(_) {
      reply(
        400,
        "{\"error\":\"access_denied\",\"error_description\":\"private\"}",
      )
    },
    1000,
    False,
  )
  |> should.equal(Error("xAI device authorization denied"))
  oauth.poll(
    cfg,
    device,
    fn(_) { Error("transport error with private device code") },
    1000,
    False,
  )
  |> should.equal(Error("xAI OAuth transport unavailable"))
  oauth.refresh(
    cfg,
    discovery().token_endpoint,
    auth.Credential("synthetic-access", "synthetic-refresh", 0),
    fn(_) {
      reply(
        400,
        "{\"error\":\"invalid_grant\",\"error_description\":\"private\"}",
      )
    },
    1000,
  )
  |> should.equal(Error("xAI refresh requires reauthorization"))
}

pub fn unsafe_discovery_and_redirects_test() {
  oauth.discover(config(), fn(_) {
    reply(
      200,
      "{\"device_authorization_endpoint\":\"http://127.0.0.1:8765/device\",\"token_endpoint\":\"https://evil.example/token\"}",
    )
  })
  |> should.be_error
  oauth.discover(config(), fn(_) {
    reply(
      302,
      "{\"device_authorization_endpoint\":\"http://127.0.0.1:8765/device\",\"token_endpoint\":\"http://127.0.0.1:8765/token\"}",
    )
  })
  |> should.be_error
}

/// Real loopback HTTP calls; fake clock keeps this scenario fast and
/// deterministic. Every credential/code here is explicitly synthetic.
pub fn loopback_discovery_device_token_refresh_test() {
  let started = process.new_subject()
  let calls = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    let assert Ok(host) = request.get_header(req, "host")
    let origin = "http://" <> host
    let body = case bit_array.to_string(req.body) {
      Ok(body) -> body
      Error(_) -> ""
    }
    let form = uri.parse_query(body)
    process.send(calls, #(req.path, form))
    let payload = case req.path {
      "/discovery" ->
        json.object([
          #("device_authorization_endpoint", json.string(origin <> "/device")),
          #("token_endpoint", json.string(origin <> "/token")),
        ])
        |> json.to_string
      "/device" -> device_body(origin <> "/verify")
      "/token" ->
        case form {
          Ok(form) ->
            case list.key_find(form, "grant_type") {
              Ok("refresh_token") ->
                "{\"access_token\":\"synthetic-refreshed\",\"expires_in\":3600}"
              _ ->
                "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"token_type\":\"Bearer\",\"expires_in\":600}"
            }
          _ -> "{}"
        }
      _ -> "{}"
    }
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string(payload)))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
    |> mist.read_request_body(
      bytes_limit: 4096,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(started, 5000)
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let cfg = oauth.Config(origin <> "/discovery", endpoint.LocalMock)
  let assert Ok(discovered) = oauth.discover(cfg, oauth.http_send)
  let assert Ok(device) = oauth.start(cfg, discovered, oauth.http_send, 1000)
  oauth.user_prompt(device) |> should.equal(#("SYNTHETIC", origin <> "/verify"))
  let assert Ok(oauth.Authorized(credential)) =
    oauth.poll(cfg, device, oauth.http_send, 1000, False)
  credential
  |> should.equal(auth.Credential(
    "synthetic-access",
    "synthetic-refresh",
    601_000,
  ))
  let assert Ok(refreshed) =
    oauth.refresh(
      cfg,
      discovered.token_endpoint,
      credential,
      oauth.http_send,
      2000,
    )
  refreshed
  |> should.equal(auth.Credential(
    "synthetic-refreshed",
    "synthetic-refresh",
    3_602_000,
  ))
  let assert Ok(#("/discovery", _)) = process.receive(calls, 1000)
  let assert Ok(#("/device", Ok(form))) = process.receive(calls, 1000)
  list.key_find(form, "client_id") |> should.equal(Ok(oauth.client_id))
  list.key_find(form, "scope") |> should.equal(Ok(oauth.scope))
  let assert Ok(#("/token", Ok(form))) = process.receive(calls, 1000)
  list.key_find(form, "grant_type") |> should.equal(Ok(oauth.device_grant))
  let assert Ok(#("/token", Ok(form))) = process.receive(calls, 1000)
  list.key_find(form, "grant_type") |> should.equal(Ok("refresh_token"))
  list.key_find(form, "refresh_token") |> should.equal(Ok("synthetic-refresh"))
  process.unlink(server.pid)
  process.send_exit(server.pid)
}
