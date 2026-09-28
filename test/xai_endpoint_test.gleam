import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/providers/xai/endpoint as xai
import mimic/providers/xai/oauth
import mimic/types

pub fn origins_are_explicit_test() {
  let api = xai.defaults(xai.ApiKey)
  let oauth = xai.defaults(xai.DeviceOAuth)
  let assert Ok(api_plan) = xai.select(api, xai.Chat)
  api_plan.url |> should.equal("https://api.x.ai/v1/responses")
  let assert Ok(proxy) = xai.select(oauth, xai.Responses)
  proxy.url |> should.equal("https://cli-chat-proxy.grok.com/v1/responses")
  proxy.proxy_identity |> should.be_true
  let assert Ok(compact) = xai.select(oauth, xai.Compact)
  compact.url |> should.equal("https://api.x.ai/v1/responses/compact")
  compact.proxy_identity |> should.be_false
  let assert Ok(official) =
    xai.select(xai.Config(..oauth, using_api: True), xai.Responses)
  official.url |> should.equal(api_plan.url)
  official.proxy_identity |> should.be_false
}

pub fn websocket_selection_test() {
  let config = xai.defaults(xai.DeviceOAuth)
  xai.select(config, xai.WebSocket) |> should.be_error
  xai.select_auto(config, True, True, True) |> should.be_error
  let enabled = xai.Config(..config, websockets: True)
  let assert Ok(ws) = xai.select_auto(enabled, True, True, True)
  ws.url |> should.equal("wss://api.x.ai/v1/responses")
  ws.proxy_identity |> should.be_false
  let assert Ok(http) = xai.select_auto(enabled, False, True, False)
  http.operation |> should.equal(xai.Responses)
  xai.select_auto(enabled, False, True, True) |> should.be_error
}

pub fn overrides_do_not_cross_transports_test() {
  let config =
    xai.Config(
      ..xai.defaults(xai.DeviceOAuth),
      http_base: Some("https://owned.example/v1"),
    )
  let assert Ok(http) = xai.select(config, xai.Responses)
  http.url |> should.equal("https://owned.example/v1/responses")
  http.proxy_identity |> should.be_false
  let assert Ok(compact) = xai.select(config, xai.Compact)
  compact.url |> should.equal("https://api.x.ai/v1/responses/compact")
  xai.select(
    xai.Config(..config, compact_base: Some(xai.proxy_base)),
    xai.Compact,
  )
  |> should.be_error
}

pub fn headers_never_contain_credentials_test() {
  let assert Ok(proxy) = xai.select(xai.defaults(xai.DeviceOAuth), xai.Chat)
  let assert Ok(headers) = xai.headers(proxy, "synthetic-conversation")
  list.contains(headers, types.Header("X-XAI-Token-Auth", "xai-grok-cli"))
  |> should.be_true
  list.any(headers, fn(h) { h.name == "Authorization" || h.name == "Cookie" })
  |> should.be_false
  let assert Ok(compact) =
    xai.select(xai.defaults(xai.DeviceOAuth), xai.Compact)
  let assert Ok(headers) = xai.headers(compact, "")
  list.length(headers) |> should.equal(2)
  xai.headers(proxy, "injected\r\nAuthorization: no") |> should.be_error
}

pub fn discovery_validation_test() {
  oauth.validate_endpoint("https://auth.x.ai/token", xai.VerifiedTls)
  |> should.be_ok
  list.each(
    [
      "http://auth.x.ai/token",
      "https://x.ai.evil.example/token",
      "https://evilx.ai/token",
      "https://user@auth.x.ai/token",
      "https://auth.x.ai/token#fragment",
      "https://auth.x.ai/token?secret=no",
      "http://127.0.0.1:8765/token",
    ],
    fn(url) { oauth.validate_endpoint(url, xai.VerifiedTls) |> should.be_error },
  )
  oauth.validate_endpoint("http://127.0.0.1:8765/token", xai.LocalMock)
  |> should.be_ok
  oauth.validate_endpoint("https://auth.x.ai/token", xai.LocalMock)
  |> should.be_error
  oauth.validate_endpoint("http://localhost:8765/token", xai.LocalMock)
  |> should.be_error
}

pub fn session_isolation_test() {
  let assert Ok(plan) = xai.select(xai.defaults(xai.ApiKey), xai.Responses)
  let assert Ok(a) =
    xai.session_key("tenant-a", "key", xai.ApiKey, plan, "same")
  let assert Ok(b) =
    xai.session_key("tenant-b", "key", xai.ApiKey, plan, "same")
  should.be_false(a == b)
  let assert Ok(c) =
    xai.session_key("tenant-a", "other-key", xai.ApiKey, plan, "same")
  should.be_false(a == c)
  xai.session_key("tenant-a", "key", xai.ApiKey, plan, "")
  |> should.be_error
}

pub fn local_mock_is_explicit_test() {
  let config = xai.defaults(xai.ApiKey)
  let local = Some("http://127.0.0.1:8765/v1")
  xai.select(xai.Config(..config, http_base: local), xai.Chat)
  |> should.be_error
  let assert Ok(plan) =
    xai.select(
      xai.Config(..config, http_base: local, policy: xai.LocalMock),
      xai.Chat,
    )
  plan.url |> should.equal("http://127.0.0.1:8765/v1/responses")
  xai.select(
    xai.Config(..config, policy: xai.LocalMock, http_base: None),
    xai.Chat,
  )
  |> should.be_error
}
