import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/gateway/config
import mimic/providers/contracts as c
import mimic/providers/xai/endpoint

const operations = ",\"xai_operations\":[{\"protocol\":\"responses\","
  <> "\"operation\":\"responses\",\"base\":\"http://127.0.0.1:8311/v1\","
  <> "\"using_api\":false},{\"protocol\":\"responses\","
  <> "\"operation\":\"responses/compact\",\"base\":\"http://127.0.0.1:8312/v1\","
  <> "\"using_api\":true}]"

fn account(id: String, mode: String, options: String) -> String {
  "{\"provider\":\"xai\",\"auth_mode\":\""
  <> mode
  <> "\",\"id\":\""
  <> id
  <> "\",\"origin\":\"http://127.0.0.1:8310\",\"models\":[\"grok-4.7\"]"
  <> options
  <> "}"
}

fn settings(accounts: String) -> String {
  "{\"version\":1,\"state_dir\":\"/synthetic/f07\",\"listen_port\":0,"
  <> "\"accounts\":["
  <> accounts
  <> "]}"
}

fn oauth(options: String) -> String {
  account(
    "selected",
    "oauth",
    ",\"oauth\":{\"discovery_url\":\"http://127.0.0.1:8310/discovery\"}"
      <> options,
  )
}

fn context(origin: String) -> c.Context {
  c.Context(
    "xai",
    "oauth",
    "selected",
    origin,
    "synthetic-session",
    c.OAuth(
      c.OAuthData(
        auth.Credential(
          "synthetic-access",
          "synthetic-refresh",
          9_000_000_000_000,
        ),
        [],
      ),
    ),
  )
}

fn request(operation: String) -> c.Request {
  c.Request(
    "xai",
    "oauth",
    "grok-4.7",
    "responses",
    operation,
    c.Buffered,
    [],
    "synthetic-session",
    None,
    "{\"model\":\"grok-4.7\",\"input\":\"synthetic\"}",
  )
}

pub fn legacy_key_accounts_keep_explicit_origin_and_no_bindings_test() {
  let assert Ok(settings) =
    config.decode(settings(account("selected", "api_key", "")))
  config.runtime_bindings(settings) |> should.equal([])
  let assert Ok(row) = config.xai_registration(settings, "grok-4.7")
  row.auth_modes |> should.equal(["api_key"])
  row.operations |> should.equal(["responses", "responses/compact"])
  let ctx =
    c.Context(
      ..context("http://127.0.0.1:8310"),
      auth_mode: "api_key",
      credential: c.ApiKey("synthetic-key"),
    )
  let req = c.Request(..request("responses"), auth_mode: "api_key")
  let assert Ok(selected) = config.xai_endpoint(settings, ctx, req)
  selected.mode |> should.equal(endpoint.ApiKey)
  selected.http_base |> should.equal(Some("http://127.0.0.1:8310/v1"))
  config.xai_endpoint(
    settings,
    c.Context(..ctx, origin: "http://127.0.0.1:8311"),
    req,
  )
  |> should.be_error
}

pub fn oauth_requires_typed_exclusive_operation_bindings_test() {
  config.decode(settings(oauth(""))) |> should.be_error
  config.decode(settings(oauth(",\"xai_operations\":[]"))) |> should.be_error
  let assert Ok(settings) = config.decode(settings(oauth(operations)))
  config.runtime_bindings(settings) |> list.length |> should.equal(2)
  let assert Ok(row) = config.xai_registration(settings, "grok-4.7")
  row.auth_modes |> should.equal(["oauth"])
  row.operations |> should.equal(["responses", "responses/compact"])
}

pub fn actual_selected_operation_origin_controls_transport_test() {
  let assert Ok(settings) = config.decode(settings(oauth(operations)))
  let assert Ok(proxy) =
    config.xai_endpoint(
      settings,
      context("http://127.0.0.1:8311"),
      request("responses"),
    )
  proxy.mode |> should.equal(endpoint.DeviceOAuth)
  proxy.using_api |> should.be_false
  proxy.http_base |> should.equal(Some("http://127.0.0.1:8311/v1"))
  let assert Ok(api) =
    config.xai_endpoint(
      settings,
      context("http://127.0.0.1:8312"),
      request("responses/compact"),
    )
  api.using_api |> should.be_true
  api.compact_base |> should.equal(Some("http://127.0.0.1:8312/v1"))
  list.each(
    [
      context("http://127.0.0.1:8310"),
      context("http://127.0.0.1:8312"),
      c.Context(..context("http://127.0.0.1:8311"), account: "unconfigured"),
    ],
    fn(ctx) {
      config.xai_endpoint(settings, ctx, request("responses"))
      |> should.be_error
    },
  )
  config.xai_endpoint(
    settings,
    context("http://127.0.0.1:8311"),
    c.Request(..request("responses"), model: "unconfigured"),
  )
  |> should.be_error
}

pub fn shared_model_registration_retains_only_configured_auth_modes_test() {
  let assert Ok(settings) =
    config.decode(settings(
      account("key", "api_key", "") <> "," <> oauth(operations),
    ))
  let assert Ok(row) = config.xai_registration(settings, "grok-4.7")
  row.auth_modes |> should.equal(["api_key", "oauth"])
  row.operations |> should.equal(["responses", "responses/compact"])
}

pub fn compact_selection_skips_response_only_auth_partition_test() {
  let proxy_only =
    oauth(
      ",\"xai_operations\":[{\"protocol\":\"responses\",\"operation\":\"responses\","
      <> "\"base\":\"http://127.0.0.1:8311/v1\",\"using_api\":false}]",
    )
  let key = account("key", "api_key", "")
  list.each([proxy_only <> "," <> key, key <> "," <> proxy_only], fn(accounts) {
    let assert Ok(settings) = config.decode(settings(accounts))
    let assert Ok(selected) =
      list.find(settings.accounts, fn(account) {
        list.contains(account.models, "grok-4.7")
        && config.admits_operation(account, "grok-4.7", "responses/compact")
      })
    selected.id |> should.equal("key")
    selected.auth_mode |> should.equal("api_key")
  })
}
