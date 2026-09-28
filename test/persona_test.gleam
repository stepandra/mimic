import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/corpus
import mimic/persona
import mimic/replay
import mimic/types.{Capture, Header, Transport}

fn sample(kind: String) {
  Capture(
    "synthetic-client",
    "1.0.0",
    "http://127.0.0.1:9999",
    kind,
    "POST",
    "/v1/messages",
    "HTTP/1.1",
    [
      Header("Host", "fixture.test"),
      Header("X-Trace", "a"),
      Header("x-trace", "b"),
      Header("Content-Length", "2"),
    ],
    "{}",
    Transport("http/1.1", None),
  )
}

pub fn roundtrip_draft_test() {
  let assert Ok(draft) = persona.draft([sample("main"), sample("count_tokens")])
  persona.lint(draft) |> should.equal([])
  let assert Ok(parsed) = persona.parse(persona.render(draft))
  parsed |> should.equal(draft)
  list.length(parsed.headers) |> should.equal(8)
}

pub fn draft_host_uses_runtime_origin_test() {
  let original = sample("main")
  let assert Ok(profile) = persona.draft([original])
  let runtime =
    Capture(
      ..original,
      endpoint: "http://127.0.0.1:9998",
      headers: list.map(original.headers, fn(header) {
        case header.name {
          "Host" -> Header("Host", "127.0.0.1:9998")
          _ -> header
        }
      }),
    )
  let assert Ok(materialized) = replay.materialize(profile, runtime)
  list.first(materialized.headers)
  |> should.equal(Ok(Header("Host", "127.0.0.1:9998")))
}

pub fn forbidden_betas_test() {
  let text =
    "forbidden_betas = [[\"a\", \"b\"]]\n[meta]\nclient = \"synthetic\"\nversion = \"1\"\nsource = \"synthetic\"\n[transport]\nalpn = \"http/1.1\"\n[[headers]]\nname = \"Host\"\nsource = \"fixed\"\nvalue = \"fixture.test\"\n[[headers]]\nname = \"anthropic-beta\"\nsource = \"betas\"\n[[betas]]\nvalue = \"a\"\n[[betas]]\nvalue = \"b\"\n"
  let assert Ok(p) = persona.parse(text)
  string.join(persona.lint(p), ";")
  |> string.contains("Forbidden beta combination")
  |> should.be_true
}

pub fn unsupported_tls_test() {
  let assert Ok(p) = persona.draft([sample("main")])
  let modified = persona.Persona(..p, ja4: Some("unmeasured"))
  string.join(persona.lint(modified), ";")
  |> string.contains("TLS fingerprint reproduction is unsupported")
  |> should.be_true
}

pub fn no_alpn_http_1_1_draft_test() {
  let original = sample("main")
  let no_alpn = Capture(..original, transport: Transport("none", None))
  let profile = persona.draft([no_alpn]) |> should.be_ok
  profile.alpn |> should.equal("none")
  persona.lint(profile) |> should.equal([])
}

pub fn empty_draft_test() {
  let assert Error(_) = persona.draft([])
}

pub fn reject_unknown_field_test() {
  let text =
    "[meta]\nclient = \"fixture\"\nversion = \"1\"\nsource = \"synthetic\"\n[transport]\nalpn = \"http/1.1\"\nclienthello = \"unimplemented\"\n[[headers]]\nname = \"Host\"\nsource = \"fixed\"\nvalue = \"fixture.test\"\n"
  let assert Error(message) = persona.parse(text)
  message |> string.contains("Unsupported transport field") |> should.be_true
}

pub fn duplicate_order_variation_is_passthrough_test() {
  let first = sample("main")
  let second =
    Capture(..first, headers: [
      Header("Host", "fixture.test"),
      Header("X-Trace", "b"),
      Header("x-trace", "a"),
      Header("Content-Length", "2"),
    ])
  let assert Ok(profile) = persona.draft([first, second])
  let rules =
    list.filter(profile.headers, fn(h) { string.lowercase(h.name) == "x-trace" })
  let assert [a, b] = rules
  a.source |> should.equal("passthrough")
  b.source |> should.equal("passthrough")
}

pub fn beta_draft_and_conditional_lint_test() {
  let base = sample("main")
  let first =
    Capture(..base, headers: [
      Header("Host", "fixture.test"),
      Header("anthropic-beta", "fixture-alpha,fixture-legacy"),
      Header("Content-Length", "2"),
    ])
  let assert Ok(profile) = persona.draft([first])
  profile.headers
  |> list.filter(fn(h) { string.lowercase(h.name) == "anthropic-beta" })
  |> should.equal([
    persona.HeaderRule(
      "anthropic-beta",
      "fixed",
      "fixture-alpha,fixture-legacy",
      "main",
    ),
  ])
  let forbidden =
    persona.Persona(..profile, forbidden_betas: [
      ["fixture-alpha", "fixture-legacy"],
    ])
  string.join(persona.lint(forbidden), ";")
  |> string.contains("Forbidden beta combination")
  |> should.be_true
}

pub fn scrubbed_values_are_not_fixed_evidence_test() {
  let original = sample("main")
  let capture =
    Capture(..original, headers: [
      Header("Host", "fixture.test"),
      Header("User-Agent", "synthetic-client/1"),
      Header("Content-Type", "application/json"),
      Header("Content-Length", "2"),
    ])
  let sanitized = corpus.redact(capture) |> should.be_ok
  let profile = persona.draft([sanitized]) |> should.be_ok
  let host = list.first(profile.headers) |> should.be_ok
  host.source |> should.equal("passthrough")
  let ua = list.drop(profile.headers, 1) |> list.first |> should.be_ok
  ua.source |> should.equal("passthrough")
  let materialized = replay.materialize(profile, capture) |> should.be_ok
  materialized.headers |> should.equal(capture.headers)
}

pub fn sanitized_structural_capture_can_materialize_test() {
  let original =
    Capture(
      ..sample("main"),
      endpoint: "https://fixture.test/v1/messages",
      headers: [
        Header("Host", "fixture.test"),
        Header("anthropic-beta", "feature-2025-05-14"),
        Header("Content-Type", "application/problem+json"),
        Header("Content-Length", "2"),
      ],
    )
  let sanitized = corpus.redact(original) |> should.be_ok
  let profile = persona.draft([sanitized]) |> should.be_ok
  persona.lint(profile) |> should.equal([])
  let materialized = replay.materialize(profile, sanitized) |> should.be_ok
  materialized.headers |> should.equal(sanitized.headers)
}

pub fn duplicate_beta_headers_keep_occurrence_values_test() {
  let original = sample("main")
  let capture =
    Capture(..original, headers: [
      Header("Host", "fixture.test"),
      Header("anthropic-beta", "fixture-alpha"),
      Header("anthropic-beta", "fixture-legacy"),
      Header("Content-Length", "2"),
    ])
  let profile = persona.draft([capture]) |> should.be_ok
  profile.betas |> should.equal([])
  let materialized = replay.materialize(profile, capture) |> should.be_ok
  materialized.headers |> should.equal(capture.headers)
}

pub fn forbidden_fixed_beta_headers_are_linted_test() {
  let original = sample("main")
  let profile = persona.draft([original]) |> should.be_ok
  let forbidden =
    persona.Persona(
      ..profile,
      headers: [
        persona.HeaderRule("Host", "fixed", "fixture.test", "*"),
        persona.HeaderRule("anthropic-beta", "fixed", "a,b", "*"),
      ],
      forbidden_betas: [["a", "b"]],
    )
  string.join(persona.lint(forbidden), ";")
  |> string.contains("Forbidden beta combination")
  |> should.be_true
}
