/// Entirely synthetic device/token exchanges; Send never opens a socket.
import gleam/list
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/providers/contracts
import mimic/providers/kimi/oauth
import mimic/types.{Header}

fn config() {
  oauth.Config(
    "kimi.ai",
    "http://127.0.0.1:4500/api/oauth/device_authorization",
    "http://127.0.0.1:4500/api/oauth/token",
    "synthetic-device-id",
  )
}

pub fn endpoints_are_exact_and_domain_paired_test() {
  oauth.validate(config()) |> should.be_ok
  let public = oauth.Config(..config(), device_id: "")
  oauth.validate_endpoints(public) |> should.be_ok
  oauth.validate(public) |> should.be_error
  oauth.validate(oauth.Config(
    "kimi.ai",
    "https://auth.kimi.com/api/oauth/device_authorization",
    "https://auth.kimi.ai/api/oauth/token",
    "synthetic-device-id",
  ))
  |> should.be_error
  oauth.validate(oauth.Config(
    "kimi.ai",
    "http://not-loopback.invalid/api/oauth/device_authorization",
    "http://not-loopback.invalid/api/oauth/token",
    "synthetic-device-id",
  ))
  |> should.be_error
}

pub fn device_flow_plans_and_poll_schedule_test() {
  let assert Ok(device) =
    oauth.start(
      config(),
      fn(plan) {
        plan.url |> should.equal(config().device_url)
        plan.body |> should.equal("client_id=" <> oauth.client_id)
        Ok(oauth.TokenReply(
          200,
          [],
          "{\"device_code\":\"synthetic-private-code\",\"user_code\":\"ABCD\",\"verification_uri\":\"http://127.0.0.1:4500/verify\",\"expires_in\":120,\"interval\":2}",
        ))
      },
      10_000,
    )
  oauth.user_prompt(device)
  |> should.equal(#("ABCD", "http://127.0.0.1:4500/verify"))
  let assert Ok(oauth.Pending(_, wait)) =
    oauth.poll(
      config(),
      device,
      fn(_) { panic as "No early poll" },
      10_000,
      False,
    )
  wait |> should.equal(5000)
  let assert Ok(oauth.Pending(device, next)) =
    oauth.poll(
      config(),
      device,
      fn(plan) {
        string.contains(plan.body, "device_code=synthetic-private-code")
        |> should.be_true
        Ok(oauth.TokenReply(200, [], "{\"error\":\"slow_down\"}"))
      },
      15_000,
      False,
    )
  next |> should.equal(10_000)
  let assert Ok(oauth.Authorized(token)) =
    oauth.poll(
      config(),
      device,
      fn(_) {
        Ok(oauth.TokenReply(
          200,
          [],
          "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600}",
        ))
      },
      25_000,
      False,
    )
  token
  |> should.equal(auth.Credential(
    "synthetic-access",
    "synthetic-refresh",
    3_625_000,
  ))
}

pub fn refresh_rotation_preserves_private_metadata_test() {
  let current = auth.Credential("old-synthetic", "old-refresh", 100)
  let assert Ok(contracts.OAuth(data)) = oauth.material(config(), current)
  let refresh_config = oauth.Config(..config(), device_id: "")
  let contracts.Refresh(callback) =
    oauth.refresher(refresh_config, fn(plan) {
      string.contains(plan.body, "refresh_token=old-refresh")
      |> should.be_true
      list.find(plan.headers, fn(header) { header.name == "X-Msh-Device-Id" })
      |> should.equal(Ok(Header("X-Msh-Device-Id", "synthetic-device-id")))
      Ok(oauth.TokenReply(
        200,
        [],
        "{\"access_token\":\"new-synthetic\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}",
      ))
    })
  let assert Ok(rotated) = callback(data, 1000)
  rotated.credential.access_token |> should.equal("new-synthetic")
  rotated.credential.refresh_token |> should.equal("new-refresh")
  rotated.private_metadata |> should.equal(data.private_metadata)
}

pub fn import_accepts_expired_positive_expiry_but_not_missing_grant_test() {
  oauth.import_material(
    config(),
    auth.Credential("synthetic-access", "synthetic-refresh", 1),
  )
  |> should.be_ok
  oauth.import_material(
    config(),
    auth.Credential("synthetic-access", "synthetic-refresh", 0),
  )
  |> should.be_error
  oauth.import_material(
    config(),
    auth.Credential("synthetic-access", "", 10_001),
  )
  |> should.be_error
}

pub fn ambiguous_refresh_and_duplicate_grant_fail_closed_test() {
  let current = auth.Credential("old-synthetic", "old-refresh", 100)
  oauth.refresh(
    config(),
    current,
    fn(_) { Error("synthetic transport failure") },
    1000,
  )
  |> should.equal(Error(contracts.RefreshUnavailable))
  oauth.refresh(
    config(),
    current,
    fn(_) {
      Ok(oauth.TokenReply(
        400,
        [],
        "{\"error\":\"invalid_grant\",\"access_token\":\"contradiction\"}",
      ))
    },
    1000,
  )
  |> should.equal(Error(contracts.RefreshUnavailable))
  oauth.refresh(
    config(),
    current,
    fn(_) {
      Ok(oauth.TokenReply(
        200,
        [],
        "{\"access_token\":\"one\",\"access_token\":\"two\",\"expires_in\":3600}",
      ))
    },
    1000,
  )
  |> should.equal(Error(contracts.RefreshUnavailable))
}
