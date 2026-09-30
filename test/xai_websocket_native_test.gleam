/// Synthetic real loopback WS/WSS. No xAI service or real credential involved.
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/xai/endpoint
import mimic/providers/xai/models
import mimic/providers/xai_websocket as xai
import mimic/recorder/tls
import mist

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn ca_directory() -> String

@external(erlang, "mimic_xai_native_test_ffi", "leaf")
fn leaf(
  cert: String,
  key: String,
) -> Result(#(String, #(String, String)), String)

@external(erlang, "mimic_xai_native_test_ffi", "cleanup")
fn cleanup(temp: String) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn state_directory() -> String

const create = "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"input\":[],\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"function\",\"name\":\"run\",\"parameters\":{\"type\":\"object\"}}]}]}"

const follow = "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"previous_response_id\":\"resp_synthetic_0\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_synthetic\",\"output\":\"synthetic result\"}]}"

const orphan = "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"previous_response_id\":\"resp_synthetic_0\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"wrong\",\"output\":\"synthetic result\"}]}"

const added = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item_synthetic\",\"call_id\":\"call_synthetic\",\"name\":\"shell__run\",\"arguments\":\"\",\"status\":\"in_progress\"}}"

const arguments_done = "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"item_synthetic\",\"arguments\":\"{\\\"text\\\":\\\"shell__run\\\"}\"}"

const item_done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item_synthetic\",\"call_id\":\"call_synthetic\",\"name\":\"shell__run\",\"arguments\":\"{\\\"text\\\":\\\"shell__run\\\"}\",\"status\":\"completed\"}}"

fn created(index: Int) {
  "{\"type\":\"response.created\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_"
  <> int.to_string(index)
  <> "\",\"status\":\"in_progress\",\"output\":[]}}"
}

fn completed(index: Int) {
  let output = case index {
    0 ->
      "[{\"type\":\"function_call\",\"id\":\"item_synthetic\",\"call_id\":\"call_synthetic\",\"name\":\"shell__run\",\"arguments\":\"{\\\"text\\\":\\\"shell__run\\\"}\",\"status\":\"completed\"}]"
    _ -> "[]"
  }
  "{\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"id\":\"resp_synthetic_"
  <> int.to_string(index)
  <> "\",\"model\":\"grok-4.7\",\"status\":\"completed\",\"output\":"
  <> output
  <> ",\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"total_tokens\":5}}}"
}

pub fn peer(cert: Option(#(String, String)), mode: String) {
  let malformed = mode == "malformed"
  let started = process.new_subject()
  let observed = process.new_subject()
  let closed = process.new_subject()
  let handler = fn(req) {
    let assert Ok(auth) = request.get_header(req, "authorization")
    process.send(observed, auth)
    process.send(observed, req.path)
    mist.websocket(
      req,
      fn(index, message, connection) {
        case message {
          mist.Text(body) -> {
            process.send(observed, body)
            let assert Ok(_) = mist.send_text_frame(connection, created(index))
            let assert Ok(_) =
              mist.send_text_frame(connection, "{\"type\":\"keepalive\"}")
            case index == 0 && !malformed {
              True ->
                list.each([added, arguments_done, item_done], fn(event) {
                  let event = case mode == "identity" && event == item_done {
                    True -> string.replace(event, "shell__run", "other__run")
                    False -> event
                  }
                  let assert Ok(_) = mist.send_text_frame(connection, event)
                  Nil
                })
              False -> Nil
            }
            let terminal = case malformed {
              True -> "{\"type\":\"response.completed\",\"type\":\"error\"}"
              False -> completed(index)
            }
            let assert Ok(_) = mist.send_text_frame(connection, terminal)
            mist.continue(index + 1)
          }
          _ -> mist.continue(index)
        }
      },
      fn(_) { #(0, None) },
      fn(_) { process.send(closed, Nil) },
    )
  }
  let builder =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(started, port) })
  let builder = case cert {
    None -> builder
    Some(#(cert, key)) -> mist.with_tls(builder, cert, key)
  }
  let assert Ok(server) = mist.start(builder)
  let assert Ok(port) = process.receive(started, 5000)
  let scheme = case cert {
    None -> "http://"
    Some(_) -> "https://"
  }
  #(server, scheme <> "127.0.0.1:" <> int.to_string(port), observed, closed)
}

fn context(origin: String, mode: endpoint.Mode) {
  let #(name, material) = case mode {
    endpoint.ApiKey -> #("api_key", c.ApiKey("synthetic-api-key"))
    endpoint.DeviceOAuth -> #(
      "oauth",
      c.OAuth(
        c.OAuthData(
          auth.Credential(
            "synthetic-oauth",
            "synthetic-refresh",
            9_000_000_000_000,
          ),
          [#("token_endpoint", "https://auth.x.ai/synthetic-token")],
        ),
      ),
    )
  }
  c.Context(
    "xai",
    name,
    "synthetic-a",
    origin,
    "opaque-account-session",
    material,
  )
}

pub fn req(mode: String, body: String) {
  c.Request(
    "xai",
    mode,
    "grok-4.7",
    "responses",
    "responses/websocket",
    c.Streaming,
    [c.WebSocket, c.Tools],
    "client-session",
    None,
    body,
  )
}

fn next(
  adapter: c.SessionAdapter(xai.Handle),
  handle: xai.Handle,
  attempts: Int,
) {
  let assert Ok(#(message, handle)) = adapter.receive(handle)
  case message, attempts {
    Some(message), _ -> #(message, handle)
    None, n if n > 0 -> next(adapter, handle, n - 1)
    _, _ -> panic as "synthetic xAI peer did not send expected message"
  }
}

fn terminal(adapter, handle) {
  let #(first, handle) = next(adapter, handle, 100)
  let assert Ok(first) = ir.parse(first)
  ir.string_field(first, "type") |> should.equal(Ok("response.created"))
  let #(keepalive, handle) = next(adapter, handle, 100)
  let assert Ok(keepalive) = ir.parse(keepalive)
  ir.string_field(keepalive, "type") |> should.equal(Ok("keepalive"))
  until_terminal(adapter, handle, 10)
}

fn until_terminal(adapter, handle, remaining) {
  let #(message, handle) = next(adapter, handle, 100)
  let assert Ok(document) = ir.parse(message)
  case ir.string_field(document, "type"), remaining {
    Ok("response.completed"), _ -> #(message, handle)
    _, n if n > 0 -> until_terminal(adapter, handle, n - 1)
    _, _ -> panic as "synthetic xAI peer did not complete"
  }
}

pub fn physical_ws_wss_api_key_oauth_tools_continuation_test() {
  let assert Ok(certificate) = tls.generate_ca(ca_directory())
  let assert Ok(#(temp, server_certificate)) =
    leaf(certificate.0, certificate.1)
  list.each([None, Some(server_certificate)], fn(cert) {
    list.each([endpoint.ApiKey, endpoint.DeviceOAuth], fn(mode) {
      let #(server, origin, observed, closed) = peer(cert, "normal")
      let ctx = context(origin, mode)
      let config =
        endpoint.Config(
          ..endpoint.defaults(mode),
          websockets: True,
          policy: case cert {
            None -> endpoint.LocalMock
            Some(_) -> endpoint.VerifiedTls
          },
        )
      let ca = case cert {
        None -> None
        Some(_) -> Some(certificate.0)
      }
      let adapter = xai.selected_adapter("tenant-synthetic", config, ca)
      adapter.open(
        ctx,
        c.Request(..req(ctx.auth_mode, create), operation: "responses"),
      )
      |> should.be_error
      process.receive(observed, 0) |> should.be_error
      let assert Ok(opened) = adapter.open(ctx, req(ctx.auth_mode, create))
      opened.status |> should.equal(101)
      process.receive(observed, 1000)
      |> should.equal(
        Ok(case mode {
          endpoint.ApiKey -> "Bearer synthetic-api-key"
          endpoint.DeviceOAuth -> "Bearer synthetic-oauth"
        }),
      )
      process.receive(observed, 1000) |> should.equal(Ok("/v1/responses"))
      let assert Ok(handle) =
        adapter.send(opened.handle, req(ctx.auth_mode, create))
      let assert Ok(sent) = process.receive(observed, 1000)
      let assert Ok(sent) = ir.parse(sent)
      let assert Some(ir.Array([tool])) = ir.field(sent, "tools")
      ir.string_field(tool, "name") |> should.equal(Ok("shell__run"))
      ir.field(sent, "store") |> should.equal(Some(ir.Boolean(True)))
      let #(done, handle) = terminal(adapter, handle)
      let assert Ok(done) = ir.parse(done)
      let assert Some(response) = ir.field(done, "response")
      let assert Some(ir.Array([call])) = ir.field(response, "output")
      ir.string_field(call, "name") |> should.equal(Ok("run"))
      ir.string_field(call, "namespace") |> should.equal(Ok("shell"))
      ir.string_field(call, "arguments")
      |> should.equal(Ok("{\"text\":\"shell__run\"}"))
      let assert Some(usage) = ir.field(response, "usage")
      ir.field(usage, "total_tokens") |> should.equal(Some(ir.Integer(5)))
      // No bytes are sent for orphan results or client/account/model changes.
      adapter.send(handle, req(ctx.auth_mode, orphan)) |> should.be_error
      adapter.send(
        handle,
        c.Request(..req(ctx.auth_mode, follow), session: "other"),
      )
      |> should.be_error
      adapter.send(
        handle,
        c.Request(..req(ctx.auth_mode, follow), pinned_account: Some("other")),
      )
      |> should.be_error
      process.receive(observed, 0) |> should.be_error
      let assert Ok(handle) = adapter.send(handle, req(ctx.auth_mode, follow))
      let assert Ok(sent) = process.receive(observed, 1000)
      let assert Ok(sent) = ir.parse(sent)
      ir.string_field(sent, "previous_response_id")
      |> should.equal(Ok("resp_synthetic_0"))
      let #(_, handle) = terminal(adapter, handle)
      adapter.cancel(handle)
      process.receive(closed, 1000) |> should.be_ok
      // A fresh physical connection cannot accept an old receipt.
      adapter.open(ctx, req(ctx.auth_mode, follow)) |> should.be_error
      process.receive(observed, 0) |> should.be_error
      process.unlink(server.pid)
      process.send_exit(server.pid)
    })
  })
  cleanup(temp)
}

pub fn malformed_ws_event_and_cross_origin_fail_closed_test() {
  let #(server, origin, observed, closed) = peer(None, "malformed")
  let ctx = context(origin, endpoint.ApiKey)
  let config =
    endpoint.Config(
      ..endpoint.defaults(endpoint.ApiKey),
      websockets: True,
      websocket_base: Some(origin <> "/v1"),
      policy: endpoint.LocalMock,
    )
  let adapter = xai.adapter("tenant", config, None)
  adapter.open(
    c.Context(..ctx, origin: "http://127.0.0.1:1"),
    req("api_key", create),
  )
  |> should.be_error
  let assert Ok(opened) = adapter.open(ctx, req("api_key", create))
  let assert Ok(handle) = adapter.send(opened.handle, req("api_key", create))
  let #(_, handle) = next(adapter, handle, 100)
  let #(_, handle) = next(adapter, handle, 100)
  let assert Error(error) = receive_error(adapter, handle, 100)
  error.delivery |> should.equal(c.Started)
  adapter.cancel(handle)
  process.receive(closed, 1000) |> should.be_ok
  list.each([0, 1, 2], fn(_) { process.receive(observed, 1000) |> should.be_ok })
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

fn receive_error(adapter: c.SessionAdapter(xai.Handle), handle, attempts) {
  case adapter.receive(handle) {
    Ok(#(None, handle)) if attempts > 0 ->
      receive_error(adapter, handle, attempts - 1)
    result -> result
  }
}

pub fn runtime_rotation_invalidates_physical_xai_socket_test() {
  list.each([endpoint.ApiKey, endpoint.DeviceOAuth], fn(mode) {
    let #(server, origin, observed, closed) = peer(None, "normal")
    let ctx = context(origin, mode)
    let assert Ok(store) = storage.new(state_directory())
    let key = credentials.key("xai", ctx.auth_mode, ctx.account)
    runtime_store.save(store, key, ctx.credential) |> should.be_ok
    let policy = case mode {
      endpoint.ApiKey -> credentials.StaticKey
      endpoint.DeviceOAuth ->
        credentials.Refreshable(
          c.Refresh(fn(_, _) {
            panic as "fresh synthetic token must not refresh"
          }),
        )
    }
    let config =
      endpoint.Config(
        ..endpoint.defaults(mode),
        websockets: True,
        policy: endpoint.LocalMock,
      )
    let assert Ok(model) = models.registration_for("grok-4.7", config)
    let assert Ok(catalog) = registry.new([model])
    let assert Ok(pool) =
      runtime.start(store, catalog, [
        runtime.Account(
          "xai",
          ctx.auth_mode,
          ctx.account,
          origin,
          fleet.LocalLoopback,
          1,
          ["grok-4.7"],
          policy,
        ),
      ])
    let adapter = xai.selected_adapter("synthetic-tenant", config, None)
    let request =
      c.Request(..req(ctx.auth_mode, create), operation: "responses/websocket")
    let assert Ok(session) = runtime.open_session(pool, adapter, request)
    runtime.session_send(session, request) |> should.be_ok
    drain_session(session, 100)
    list.each([0, 1, 2], fn(_) {
      process.receive(observed, 1000) |> should.be_ok
    })
    let rotated = case ctx.credential {
      c.ApiKey(_) -> c.ApiKey("synthetic-rotated")
      c.OAuth(data) ->
        c.OAuth(
          c.OAuthData(
            ..data,
            credential: auth.Credential(
              ..data.credential,
              access_token: "synthetic-rotated",
            ),
          ),
        )
      _ -> panic as "unexpected synthetic material"
    }
    runtime_store.save(store, key, rotated) |> should.be_ok
    runtime.session_send(
      session,
      c.Request(..req(ctx.auth_mode, follow), operation: "responses/websocket"),
    )
    |> should.be_error
    process.receive(closed, 1000) |> should.be_ok
    process.receive(observed, 0) |> should.be_error
    runtime.active_leases(pool) |> should.equal(Ok(0))
    runtime.stop(pool) |> should.be_ok
    process.unlink(server.pid)
    process.send_exit(server.pid)
  })
}

pub fn wire_identity_cannot_change_between_namespaces_test() {
  let #(server, origin, _, closed) = peer(None, "identity")
  let ctx = context(origin, endpoint.ApiKey)
  let config =
    endpoint.Config(
      ..endpoint.defaults(endpoint.ApiKey),
      websockets: True,
      policy: endpoint.LocalMock,
    )
  let adapter = xai.selected_adapter("tenant", config, None)
  let body =
    "{\"type\":\"response.create\",\"model\":\"grok-4.7\",\"input\":[],\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"function\",\"name\":\"run\"}]},{\"type\":\"namespace\",\"name\":\"other\",\"tools\":[{\"type\":\"function\",\"name\":\"run\"}]}]}"
  let request = req("api_key", body)
  let assert Ok(opened) = adapter.open(ctx, request)
  let assert Ok(handle) = adapter.send(opened.handle, request)
  let #(_, handle) = next(adapter, handle, 100)
  let #(_, handle) = next(adapter, handle, 100)
  let #(added, handle) = next(adapter, handle, 100)
  let assert Ok(added) = ir.parse(added)
  let assert Some(item) = ir.field(added, "item")
  ir.string_field(item, "name") |> should.equal(Ok("run"))
  ir.string_field(item, "namespace") |> should.equal(Ok("shell"))
  let #(_, handle) = next(adapter, handle, 100)
  let assert Error(error) = receive_error(adapter, handle, 100)
  error.delivery |> should.equal(c.Started)
  adapter.cancel(handle)
  process.receive(closed, 1000) |> should.be_ok
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

pub fn drain_session(session, attempts) {
  let assert Ok(message) = runtime.session_poll(session)
  case message, attempts {
    Some(message), n if n > 0 -> {
      let assert Ok(document) = ir.parse(message)
      case ir.string_field(document, "type") {
        Ok("response.completed") -> Nil
        _ -> drain_session(session, n - 1)
      }
    }
    None, n if n > 0 -> drain_session(session, n - 1)
    _, _ -> panic as "synthetic runtime xAI session did not complete"
  }
}

pub fn main() {
  physical_ws_wss_api_key_oauth_tools_continuation_test()
  malformed_ws_event_and_cross_origin_fail_closed_test()
  runtime_rotation_invalidates_physical_xai_socket_test()
  wire_identity_cannot_change_between_namespaces_test()
  io.println(
    "xAI synthetic WS/WSS adapter scenarios passed; no gateway or live-provider claim",
  )
}
