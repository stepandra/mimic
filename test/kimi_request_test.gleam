/// Synthetic request plans only. No Kimi network calls or real credentials.
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/models
import mimic/providers/kimi/request as kimi_request
import mimic/types.{Header}

fn context(mode: String, material: contracts.AuthMaterial) {
  contracts.Context(
    "kimi",
    mode,
    "synthetic-account",
    "http://127.0.0.1:8443",
    "synthetic-session-key",
    material,
  )
}

fn req(mode: String, protocol: String, operation: String, body: String) {
  contracts.Request(
    "kimi",
    mode,
    "kimi-k2.8",
    protocol,
    operation,
    contracts.Buffered,
    [],
    "synthetic-session",
    None,
    body,
  )
}

pub fn key_responses_uses_selected_account_and_native_path_test() {
  let context = context("api_key", contracts.ApiKey("synthetic-key"))
  let request =
    req(
      "api_key",
      "responses",
      "responses",
      "{\"model\":\"kimi-k2.8\",\"input\":\"synthetic prompt\",\"stream\":false}",
    )
  let assert Ok(plan) = kimi_request.prepare(context, request)
  plan.endpoint |> should.equal(context.origin)
  plan.target |> should.equal("/coding/v1/responses")
  list.find(plan.headers, fn(header) { header.name == "Authorization" })
  |> should.equal(Ok(Header("Authorization", "Bearer synthetic-key")))
  let assert Ok(body) = ir.parse(plan.body)
  ir.string_field(body, "model") |> should.equal(Ok("kimi-for-coding"))
}

pub fn oauth_selected_access_token_and_explicit_base_path_test() {
  let material =
    contracts.OAuth(
      contracts.OAuthData(
        auth.Credential("synthetic-access", "synthetic-refresh", 1_000_000),
        [#("domain", "kimi.ai"), #("device_id", "synthetic-device")],
      ),
    )
  let request =
    req(
      "oauth",
      "chat",
      "chat/completions",
      "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}",
    )
  let assert Ok(plan) =
    kimi_request.prepare_at("/tenant/kimi", context("oauth", material), request)
  plan.target |> should.equal("/tenant/kimi/v1/chat/completions")
  list.find(plan.headers, fn(header) { header.name == "Authorization" })
  |> should.equal(Ok(Header("Authorization", "Bearer synthetic-access")))
  list.find(plan.headers, fn(header) { header.name == "X-Msh-Device-Id" })
  |> should.equal(Ok(Header("X-Msh-Device-Id", "synthetic-device")))
}

pub fn path_cannot_change_authority_or_escape_prefix_test() {
  let context = context("api_key", contracts.ApiKey("synthetic-key"))
  let request =
    req(
      "api_key",
      "responses",
      "responses",
      "{\"model\":\"kimi-k2.8\",\"input\":\"synthetic\"}",
    )
  list.each(["//evil", "/../evil", "/a?b", "/a%2fb", "https://evil"], fn(path) {
    kimi_request.prepare_at(path, context, request)
    |> should.equal(
      Error(contracts.Failure(
        contracts.InvalidConfiguration,
        contracts.NotSent,
        None,
      )),
    )
  })
  let assert Ok(direct) = kimi_request.prepare_at("", context, request)
  direct.target |> should.equal("/v1/responses")
  kimi_request.prepare(
    contracts.Context(..context, origin: "http://localhost:8443/"),
    request,
  )
  |> should.be_ok
}

pub fn unsupported_transforms_and_mode_mismatch_fail_before_io_test() {
  let context = context("api_key", contracts.ApiKey("synthetic-key"))
  let tools =
    req(
      "api_key",
      "responses",
      "responses",
      "{\"model\":\"kimi-k2.8\",\"input\":\"synthetic\",\"tools\":[]}",
    )
  kimi_request.prepare(context, tools)
  |> should.equal(
    Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
  )
  let mismatch =
    req(
      "api_key",
      "responses",
      "responses",
      "{\"model\":\"kimi-k2.8\",\"input\":\"synthetic\",\"stream\":true}",
    )
  kimi_request.prepare(context, mismatch)
  |> should.equal(
    Error(contracts.Failure(
      contracts.InvalidConfiguration,
      contracts.NotSent,
      None,
    )),
  )
}

pub fn registration_does_not_invent_models_or_capabilities_test() {
  let assert Ok(model) = models.registration("kimi-k3-256k")
  model.auth_modes |> should.equal(["api_key", "oauth"])
  model.capabilities |> should.equal([contracts.Buffer, contracts.Stream])
  models.registration("unknown-model") |> should.be_error
  models.upstream_id("kimi-k2.7-code-highspeed")
  |> should.equal(Some("kimi-for-coding-highspeed"))
}

pub fn rejection_never_replays_ambiguous_429_test() {
  kimi_request.rejection(429, [])
  |> should.equal(
    Some(contracts.Failure(contracts.Quota, contracts.Uncertain, None)),
  )
  kimi_request.rejection(401, [])
  |> should.equal(
    Some(contracts.Failure(
      contracts.CredentialUnavailable,
      contracts.Rejected,
      None,
    )),
  )
  kimi_request.rejection(500, []) |> should.equal(None)
}
