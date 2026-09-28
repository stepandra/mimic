import gleam/option.{None}
import gleeunit/should
import mimic/policy
import mimic/types.{type Capture, Capture, Header, Transport}
import mimic/workshop.{Breaking, Major, Trivial}

fn sample(version: String, user_agent: String) -> Capture {
  Capture(
    client: "synthetic",
    version: version,
    endpoint: "http://127.0.0.1:8000",
    request_kind: "main",
    method: "POST",
    target: "/v1/messages",
    http_version: "HTTP/1.1",
    headers: [
      Header("User-Agent", user_agent),
      Header("Content-Length", "2"),
    ],
    body: "{}",
    transport: Transport("http/1.1", None),
  )
}

pub fn versions_only_are_trivial_test() {
  policy.classify(
    sample("1.0.0", "synthetic/1.0.0 (qa)"),
    sample("1.0.1", "synthetic/1.0.1 (qa)"),
    True,
  )
  |> should.equal(Trivial)
}

pub fn arbitrary_user_agent_change_needs_review_test() {
  policy.classify(
    sample("1.0.0", "synthetic/1.0.0 (qa)"),
    sample("1.0.1", "other/1.0.1 (qa)"),
    True,
  )
  |> should.equal(Major)
}

pub fn header_casing_change_needs_review_test() {
  let before = sample("1.0.0", "synthetic/1.0.0")
  let after =
    Capture(..before, headers: [
      Header("user-agent", "synthetic/1.0.0"),
      Header("Content-Length", "2"),
    ])
  policy.classify(before, after, True) |> should.equal(Major)
}

pub fn rejected_baseline_is_breaking_even_for_version_only_test() {
  policy.classify(
    sample("1.0.0", "synthetic/1.0.0"),
    sample("1.0.1", "synthetic/1.0.1"),
    False,
  )
  |> should.equal(Breaking)
}

pub fn body_change_cannot_auto_promote_test() {
  let before = sample("1.0.0", "synthetic/1.0.0")
  let after = Capture(..before, body: "{\"stream\":true}")
  policy.classify(before, after, True) |> should.equal(Major)
}
