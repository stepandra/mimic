import gleeunit
import gleeunit/should
import mimic/fleet
import mimic/quota
import mimic/types.{Header, WireResponse}

pub fn main() {
  gleeunit.main()
}

fn profile(id: String) -> fleet.Profile {
  fleet.Profile(id, "http://127.0.0.1:9999", fleet.LocalLoopback, 2)
}

pub fn rotation_sticky_and_cooldown_test() {
  let assert Ok(state) = fleet.new([profile("a"), profile("b")])
  let assert Ok(#(state, first)) =
    fleet.select(state, quota.empty(), "session-a", 1000)
  first.profile.id |> should.equal("a")
  let assert Ok(#(state, second)) =
    fleet.select(state, quota.empty(), "session-b", 1000)
  second.profile.id |> should.equal("b")
  let state = fleet.release(state, first)
  let assert Ok(#(state, again)) =
    fleet.select(state, quota.empty(), "session-a", 1000)
  again.profile.id |> should.equal("a")
  let response = WireResponse(429, [Header("Retry-After", "5")], "", 0)
  let ledger = quota.observe(quota.empty(), "a", response, 1000)
  fleet.select(state, ledger, "session-a", 2000)
  |> should.equal(Error("Sticky credential is cooling or at capacity"))
  // In-flight session cannot be forgotten before its lease is released.
  let state = fleet.end_session(state, "session-a")
  fleet.select(state, ledger, "session-a", 2000)
  |> should.equal(Error("Sticky credential is cooling or at capacity"))
  let state = fleet.release(state, again)
  let state = fleet.release(state, again)
  let state = fleet.end_session(state, "session-a")
  let assert Ok(#(_, alternate)) =
    fleet.select(state, ledger, "session-a", 2000)
  alternate.profile.id |> should.equal("b")
}

pub fn unsupported_egress_fails_test() {
  fleet.new([
    fleet.Profile("x", "https://example.com", fleet.Proxy("http://proxy"), 1),
  ])
  |> should.equal(Error(
    "Proxy egress is unsupported; no proxy binding has been installed",
  ))
  fleet.new([fleet.Profile("x", "https://example.com", fleet.LocalLoopback, 1)])
  |> should.equal(Error(
    "Local egress only supports explicit loopback HTTP upstream",
  ))
}
