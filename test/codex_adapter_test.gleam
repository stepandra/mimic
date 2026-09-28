import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/ir
import mimic/providers/codex/adapter
import mimic/providers/codex/fixtures
import mimic/providers/codex/local
import mimic/providers/codex/models
import mimic/providers/codex/oauth
import mimic/providers/contracts
import mimic/types.{WireResponse}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

pub fn codex_real_loopback_runtime_lifecycle_test() {
  local.run(directory()) |> should.be_ok
}

fn config() {
  adapter.Config(
    "synthetic-tenant",
    "mimic-synthetic-test/1",
    True,
    models.pinned(),
    None,
  )
}

fn context() {
  contracts.Context(
    "codex",
    "oauth",
    "internal-account",
    "http://127.0.0.1:1234",
    "runtime-session-key",
    contracts.OAuth(
      contracts.OAuthData(
        auth.Credential("synthetic-access", "synthetic-refresh", 1_000_000),
        [#("chatgpt_account_id", "chatgpt-account")],
      ),
    ),
  )
}

fn request() {
  contracts.Request(
    "codex",
    "oauth",
    "gpt-5.5",
    "responses",
    "responses",
    contracts.Buffered,
    [],
    "session",
    None,
    fixtures.request,
  )
}

pub fn codex_runtime_bridge_private_metadata_and_origin_test() {
  let assert Ok(plan) = adapter.prepare(config(), context(), request())
  plan.endpoint |> should.equal(context().origin)
  plan.target |> should.equal("/backend-api/codex/responses")
  let assert Ok(body) = ir.parse(plan.body)
  ir.field(body, "stream") |> should.equal(Some(ir.Boolean(True)))
  adapter.prepare(
    config(),
    contracts.Context(..context(), credential: contracts.ApiKey("not-oauth")),
    request(),
  )
  |> should.be_error
  adapter.prepare(
    config(),
    context(),
    contracts.Request(..request(), required: [contracts.WebSocket]),
  )
  |> should.be_error
}

pub fn codex_runtime_bridge_rejects_unpinned_incremental_and_streaming_compact_test() {
  adapter.prepare(
    config(),
    context(),
    contracts.Request(..request(), body: fixtures.continuation),
  )
  |> should.be_error
  adapter.prepare(
    config(),
    context(),
    contracts.Request(
      ..request(),
      operation: "responses/compact",
      mode: contracts.Streaming,
    ),
  )
  |> should.be_error
  let assert Ok(plan) =
    adapter.prepare(
      config(),
      context(),
      contracts.Request(..request(), operation: "responses/compact"),
    )
  plan.target |> should.equal("/backend-api/codex/responses/compact")
}

pub fn codex_runtime_refresh_bridge_rotation_metadata_and_revocation_test() {
  let assert contracts.OAuth(old) = context().credential
  let contracts.Refresh(refresh) =
    adapter.refresh(oauth.published_config(), fn(_) {
      Ok(WireResponse(
        200,
        [],
        "{\"access_token\":\"synthetic-next\",\"refresh_token\":\"synthetic-rotated\",\"expires_in\":600}",
        0,
      ))
    })
  let assert Ok(next) = refresh(old, 1000)
  next.credential.refresh_token |> should.equal("synthetic-rotated")
  next.private_metadata |> should.equal(old.private_metadata)
  let contracts.Refresh(revoked) =
    adapter.refresh(oauth.published_config(), fn(_) {
      Ok(WireResponse(400, [], "{\"error\":\"invalid_grant\"}", 0))
    })
  revoked(old, 1000) |> should.equal(Error(contracts.InvalidGrant))
}
