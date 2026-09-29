import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/fleet
import mimic/providers/contracts as c
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/providers/xai/oauth
import mimic/types
import mist

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn test_directory() -> String

fn req() {
  c.Request(
    "xai",
    "api_key",
    "grok-4.7",
    "responses",
    "responses",
    c.Streaming,
    [],
    "synthetic-session",
    None,
    "{\"model\":\"grok-4.7\",\"input\":\"hello\",\"stream\":true}",
  )
}

pub fn bridge_rejects_origin_mode_model_mismatch_test() {
  let context =
    c.Context(
      "xai",
      "api_key",
      "synthetic",
      "https://api.x.ai",
      "scoped-session",
      c.ApiKey("synthetic-key"),
    )
  let config = endpoint.defaults(endpoint.ApiKey)
  let assert Ok(capture) = bridge.prepare(config, context, req())
  list.contains(capture.headers, types.Header("Host", "api.x.ai"))
  |> should.be_true
  capture.target |> should.equal("/v1/responses")
  bridge.prepare(
    config,
    c.Context(..context, origin: "https://evil.invalid"),
    req(),
  )
  |> should.be_error
  bridge.prepare(config, context, c.Request(..req(), model: "grok-4.6"))
  |> should.be_error
  bridge.prepare(
    config,
    c.Context(
      ..context,
      credential: c.OAuth(
        c.OAuthData(auth.Credential("synthetic", "synthetic", 0), []),
      ),
    ),
    req(),
  )
  |> should.be_error
  bridge.prepare(config, context, c.Request(..req(), protocol: "chat"))
  |> should.be_error
  bridge.prepare(config, context, c.Request(..req(), required: [c.WebSocket]))
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  bridge.prepare(
    config,
    context,
    c.Request(
      ..req(),
      body: "{\"model\":\"grok-4.7\",\"input\":\"hello\",\"stream\":true,\"previous_response_id\":\"resp_synthetic\"}",
    ),
  )
  |> should.be_error
  bridge.prepare(
    config,
    context,
    c.Request(
      ..req(),
      body: "{\"model\":\"grok-4.7\",\"input\":\"hello\",\"stream\":true,\"tools\":[]}",
    ),
  )
  |> should.be_ok
}

pub fn refresh_private_metadata_is_preserved_test() {
  let config =
    oauth.Config("http://127.0.0.1:8765/discovery", endpoint.LocalMock)
  let discovery =
    oauth.Discovery(
      "http://127.0.0.1:8765/device",
      "http://127.0.0.1:8765/token",
    )
  let credential = auth.Credential("synthetic", "synthetic-refresh", 0)
  let assert Ok(c.OAuth(material)) =
    bridge.oauth_material(config, discovery, credential)
  let material =
    c.OAuthData(
      ..material,
      private_metadata: list.append(material.private_metadata, [
        #("approved_identity", "synthetic"),
      ]),
    )
  let c.Refresh(refresh) =
    bridge.refresher(config, fn(_) {
      Ok(
        response.new(200)
        |> response.set_body(
          "{\"access_token\":\"synthetic-new\",\"expires_in\":3600}",
        ),
      )
    })
  let assert Ok(updated) = refresh(material, 1000)
  updated.private_metadata |> should.equal(material.private_metadata)
  updated.credential.refresh_token |> should.equal("synthetic-refresh")
  let c.Refresh(invalid) =
    bridge.refresher(config, fn(_) {
      Ok(
        response.new(400) |> response.set_body("{\"error\":\"invalid_grant\"}"),
      )
    })
  invalid(material, 1000) |> should.equal(Error(c.InvalidGrant))
}

pub fn compact_rejects_tool_aliases_and_bare_status_never_proves_rejection_test() {
  let context =
    c.Context(
      "xai",
      "api_key",
      "synthetic",
      "https://api.x.ai",
      "session",
      c.ApiKey("synthetic"),
    )
  bridge.prepare_plan(
    endpoint.defaults(endpoint.ApiKey),
    context,
    c.Request(
      ..req(),
      operation: "responses/compact",
      mode: c.Buffered,
      required: [c.Tools],
      body: "{\"model\":\"grok-4.7\",\"input\":[],\"tools\":[{\"type\":\"function\",\"name\":\"web_search\"}]}",
    ),
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  bridge.rejection(401, [])
  |> should.equal(Some(c.Failure(c.CredentialUnavailable, c.Uncertain, None)))
  bridge.rejection(429, [])
  |> should.equal(Some(c.Failure(c.Quota, c.Uncertain, None)))
}

pub fn api_key_and_oauth_use_actual_loopback_transport_test() {
  let started = process.new_subject()
  let received = process.new_subject()
  let handler = fn(req: request.Request(BitArray)) {
    process.send(received, #(
      req.path,
      request.get_header(req, "authorization"),
      request.get_header(req, "x-xai-token-auth"),
    ))
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string(
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n",
      )),
    )
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
  list.each([endpoint.ApiKey, endpoint.DeviceOAuth], fn(mode) {
    let config =
      endpoint.Config(
        ..endpoint.defaults(mode),
        http_base: Some(origin <> "/v1"),
        policy: endpoint.LocalMock,
      )
    let #(name, material) = case mode {
      endpoint.ApiKey -> #("api_key", c.ApiKey("synthetic-key"))
      endpoint.DeviceOAuth -> #(
        "oauth",
        c.OAuth(
          c.OAuthData(
            auth.Credential("synthetic-oauth", "synthetic-refresh", 123),
            [],
          ),
        ),
      )
    }
    let context =
      c.Context("xai", name, "synthetic", origin, "scoped-session", material)
    let adapter =
      transport.http(
        fn(ctx, req) { bridge.prepare(config, ctx, req) },
        bridge.rejection,
        None,
      )
    let assert Ok(opened) =
      adapter.open(context, c.Request(..req(), auth_mode: name))
    opened.status |> should.equal(200)
    let assert Ok(Some(#(body, handle))) = adapter.next(opened.handle)
    should.be_true(bit_array.byte_size(body) > 0)
    adapter.cancel(handle)
    let assert Ok(#(path, authorization, proxy_identity)) =
      process.receive(received, 5000)
    path |> should.equal("/v1/responses")
    authorization
    |> should.equal(
      Ok(case mode {
        endpoint.ApiKey -> "Bearer synthetic-key"
        endpoint.DeviceOAuth -> "Bearer synthetic-oauth"
      }),
    )
    proxy_identity |> should.be_error
  })
  process.unlink(server.pid)
  process.send_exit(server.pid)
}

fn pool() {
  let assert Ok(store) = storage.new(test_directory())
  list.each(["a", "b"], fn(id) {
    credentials.save_api_key(
      store,
      credentials.key("xai", "api_key", id),
      "synthetic-" <> id,
    )
    |> should.be_ok
  })
  let assert Ok(registry) =
    registry.new([
      registry.Model(
        "xai",
        "grok-4.7",
        ["api_key"],
        ["responses"],
        ["responses"],
        [c.Stream, c.Buffer],
      ),
    ])
  let assert Ok(pool) =
    runtime.start(
      store,
      registry,
      list.map(["a", "b"], fn(id) {
        runtime.Account(
          "xai",
          "api_key",
          id,
          "http://127.0.0.1:8765",
          fleet.LocalLoopback,
          1,
          ["grok-4.7"],
          credentials.StaticKey,
        )
      }),
    )
  pool
}

pub fn runtime_failover_stops_at_first_downstream_output_test() {
  let pool = pool()
  let calls = process.new_subject()
  let adapter =
    c.Adapter(
      open: fn(context, _) {
        process.send(calls, context.account)
        case context.account {
          "a" -> Error(c.Failure(c.Unavailable, c.NotSent, None))
          _ -> Ok(c.Opened(200, [], 0))
        }
      },
      next: fn(state) {
        case state {
          0 -> Ok(Some(#(bit_array.from_string(": keepalive\n\n"), 1)))
          _ -> Error(c.Failure(c.Unavailable, c.Uncertain, None))
        }
      },
      cancel: fn(_) { Nil },
      rejection: bridge.rejection,
    )
  let assert Ok(opened) = runtime.open(pool, adapter, req())
  opened.account |> should.equal("b")
  process.receive(calls, 1000) |> should.equal(Ok("a"))
  process.receive(calls, 1000) |> should.equal(Ok("b"))
  let assert Ok(Some(_)) = runtime.next(opened.stream)
  runtime.next(opened.stream) |> should.be_error
  process.receive(calls, 0) |> should.be_error
  runtime.cancel(opened.stream)
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}

pub fn runtime_cancel_releases_xai_lease_test() {
  let pool = pool()
  let cancelled = process.new_subject()
  let adapter =
    c.Adapter(
      open: fn(_, _) { Ok(c.Opened(200, [], Nil)) },
      next: fn(_) { Ok(Some(#(bit_array.from_string(": keepalive\n\n"), Nil))) },
      cancel: fn(_) { process.send(cancelled, Nil) },
      rejection: bridge.rejection,
    )
  let assert Ok(opened) = runtime.open(pool, adapter, req())
  runtime.cancel(opened.stream)
  runtime.cancel(opened.stream)
  process.receive(cancelled, 1000) |> should.equal(Ok(Nil))
  process.receive(cancelled, 0) |> should.be_error
  runtime.active_leases(pool) |> should.equal(Ok(0))
  runtime.stop(pool) |> should.be_ok
}
