/// Synthetic OAuth trust-boundary regressions. No live xAI calls or secrets.
import gleam/http/response
import gleeunit/should
import mimic/auth
import mimic/providers/contracts
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/providers/xai/oauth

fn config() {
  oauth.Config("http://127.0.0.1:8765/discovery", endpoint.LocalMock)
}

fn old() {
  auth.Credential("synthetic-old-access", "synthetic-old-refresh", 1000)
}

fn send(status: Int, body: String) {
  fn(_) { Ok(response.new(status) |> response.set_body(body)) }
}

pub fn duplicate_discovery_key_rejected_before_selection_test() {
  oauth.discover(
    config(),
    send(
      200,
      "{\"device_authorization_endpoint\":\"http://127.0.0.1:8765/device\",\"token_endpoint\":\"http://127.0.0.1:8765/token\",\"\\u0074oken_endpoint\":\"http://127.0.0.1:8765/other\"}",
    ),
  )
  |> should.be_error
}

pub fn duplicate_token_key_rejected_before_grant_test() {
  oauth.refresh_outcome(
    config(),
    "http://127.0.0.1:8765/token",
    old(),
    send(
      200,
      "{\"access_token\":\"synthetic-new\",\"\\u0061ccess_token\":\"synthetic-other\",\"expires_in\":3600}",
    ),
    2000,
  )
  |> should.equal(Error(oauth.Unavailable))
}

pub fn nested_duplicate_or_contradictory_429_is_unavailable_test() {
  let material =
    contracts.OAuthData(old(), [
      #("token_endpoint", "http://127.0.0.1:8765/token"),
    ])
  let contracts.Refresh(refresh) =
    bridge.refresher(
      config(),
      send(
        429,
        "{\"error\":\"rate_limit_exceeded\",\"nested\":{\"a\":1,\"\\u0061\":2}}",
      ),
    )
  refresh(material, 2000) |> should.equal(Error(contracts.RefreshUnavailable))

  let contracts.Refresh(refresh) =
    bridge.refresher(
      config(),
      send(
        429,
        "{\"error\":\"rate_limit_exceeded\",\"access_token\":\"synthetic-stale\"}",
      ),
    )
  refresh(material, 2000) |> should.equal(Error(contracts.RefreshUnavailable))
}

pub fn known_429_preserves_positive_delay_and_unproved_io_is_unavailable_test() {
  let material =
    contracts.OAuthData(old(), [
      #("token_endpoint", "http://127.0.0.1:8765/token"),
    ])
  let contracts.Refresh(refresh) =
    bridge.refresher(config(), fn(_) {
      Ok(
        response.new(429)
        |> response.set_header("retry-after", "17")
        |> response.set_body("{\"error\":\"rate_limit_exceeded\"}"),
      )
    })
  refresh(material, 2000)
  |> should.equal(Error(contracts.RefreshRateLimited(17_000)))
  let contracts.Refresh(refresh) =
    bridge.refresher(config(), fn(_) {
      Error("synthetic timeout after possible send")
    })
  refresh(material, 2000) |> should.equal(Error(contracts.RefreshUnavailable))
}
