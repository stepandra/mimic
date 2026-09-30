import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import parity/lab

fn fixture() {
  let assert Ok(value) =
    lab.load_fixture("test/parity/fixtures/messages-v1.json")
  value
}

fn evidence() {
  let fixture = fixture()
  lab.Evidence(
    1,
    "claude-messages",
    fixture.id,
    fixture.digest,
    "mimic",
    "synthetic-test-revision",
    "exercise",
    "passed",
    "{\"response\":{\"status\":200,\"headers\":[[\"X-Test\",\"a\"],[\"X-Test\",\"b\"]],\"body\":\"synthetic\"},\"upstream\":[]}",
    [
      #("assembled_ingress", True),
      ..list.map(fixture.checks, fn(name) { #(name, True) })
    ],
  )
}

fn verify(value) {
  lab.verify(
    value,
    "claude-messages",
    fixture(),
    "mimic",
    "synthetic-test-revision",
    "exercise",
  )
}

pub fn manifest_and_all_pinned_synthetic_fixtures_test() {
  let assert Ok(text) = lab.read("test/parity/manifest.json")
  let assert Ok(manifest) = lab.parse_manifest(text)
  lab.denominator(manifest) |> should.equal(25)
  list.each(manifest.rows, fn(row) {
    lab.load_fixture(row.fixture) |> result.is_ok |> should.be_true
  })
}

pub fn empty_matrix_and_wrong_pin_block_test() {
  lab.parse_manifest(
    "{\"schema_version\":1,\"cpa_revision\":\"wrong\",\"mimic_base_revision\":\"base\",\"capabilities\":[]}",
  )
  |> result.is_error
  |> should.be_true
}

pub fn valid_bound_evidence_test() {
  evidence() |> verify |> should.equal(Ok(Nil))
}

pub fn unsupported_skipped_source_only_and_unrun_block_test() {
  list.each(
    ["unsupported", "skipped", "source_evidence", "not_run", "failed"],
    fn(status) {
      lab.Evidence(..evidence(), status:)
      |> verify
      |> result.is_error
      |> should.be_true
    },
  )
}

pub fn missing_assertion_blocks_test() {
  lab.Evidence(..evidence(), checks: [])
  |> verify
  |> result.is_error
  |> should.be_true
}

pub fn duplicate_assertion_blocks_test() {
  let value = evidence()
  lab.Evidence(..value, checks: list.append(value.checks, value.checks))
  |> verify
  |> result.is_error
  |> should.be_true
}

pub fn failed_assertion_blocks_test() {
  lab.Evidence(..evidence(), checks: [#("authenticated_http", False)])
  |> verify
  |> result.is_error
  |> should.be_true
}

pub fn stale_fixture_and_wrong_target_revision_block_test() {
  list.each(
    [
      lab.Evidence(..evidence(), capability_id: "different-backend"),
      lab.Evidence(..evidence(), digest: "stale"),
      lab.Evidence(..evidence(), fixture_id: "other"),
      lab.Evidence(..evidence(), revision: "other"),
      lab.Evidence(..evidence(), target: "cpa"),
      lab.Evidence(..evidence(), phase: "restart"),
      lab.Evidence(..evidence(), version: 2),
    ],
    fn(value) { value |> verify |> result.is_error |> should.be_true },
  )
}

pub fn identical_404_is_not_passing_test() {
  let value =
    lab.Evidence(
      ..evidence(),
      status: "failed",
      observations: "{\"status\":404}",
    )
  lab.differential(value, value) |> should.equal(Ok(Nil))
  value |> verify |> result.is_error |> should.be_true
}

pub fn header_order_case_duplicates_and_body_are_semantic_test() {
  let original = evidence()
  list.each(
    [
      "{\"status\":200,\"headers\":[[\"X-Test\",\"b\"],[\"X-Test\",\"a\"]]}",
      "{\"status\":200,\"headers\":[[\"x-test\",\"a\"],[\"X-Test\",\"b\"]]}",
      "{\"status\":200,\"headers\":[[\"X-Test\",\"a\"]]}",
      original.observations <> " ",
    ],
    fn(observations) {
      lab.differential(original, lab.Evidence(..original, observations:))
      |> result.is_error
      |> should.be_true
    },
  )
}

pub fn duplicate_rows_and_unpinned_source_block_test() {
  let assert Ok(text) = lab.read("test/parity/manifest.json")
  text
  |> string.replace("\"id\":\"claude-count\"", "\"id\":\"claude-models\"")
  |> lab.parse_manifest
  |> result.is_error
  |> should.be_true
  text
  |> string.replace("/blob/" <> lab.cpa_revision, "/blob/main")
  |> lab.parse_manifest
  |> result.is_error
  |> should.be_true
}

pub fn no_live_evidence_inferred_test() {
  let assert Ok(text) = lab.read("test/parity/manifest.json")
  let assert Ok(manifest) = lab.parse_manifest(text)
  lab.summary(manifest, 0)
  |> should.equal(
    "0/25 required capability rows passed; live evidence: not_run",
  )
}

pub fn malformed_and_empty_observations_block_test() {
  list.each(
    ["", "[]", "{}", "null", "not-json", "{\"broken\""],
    fn(observations) {
      lab.Evidence(..evidence(), observations:)
      |> verify
      |> result.is_error
      |> should.be_true
    },
  )
}

pub fn adapter_only_evidence_cannot_close_ingress_gate_test() {
  let value = evidence()
  lab.Evidence(
    ..value,
    checks: list.filter(value.checks, fn(check) {
      check.0 != "assembled_ingress"
    }),
  )
  |> verify
  |> result.is_error
  |> should.be_true
}

pub fn callback_only_and_partial_envelopes_block_even_with_all_checks_test() {
  list.each(
    [
      "{\"callback_passed\":true,\"scope\":\"actual_gateway_cli\"}",
      "{\"response\":{\"status\":200,\"headers\":[],\"body\":\"ok\"}}",
      "{\"response\":{\"status\":200,\"headers\":[]},\"upstream\":[]}",
      "{\"response\":{\"status\":200,\"headers\":{\"X-Test\":\"a\"},\"body\":\"ok\"},\"upstream\":[]}",
      "{\"response\":{\"status\":200,\"headers\":[[\"X-Test\"]],\"body\":\"ok\"},\"upstream\":[]}",
      "{\"response\":{\"status\":200,\"headers\":[],\"body\":\"ok\"},\"upstream\":[{\"callback_passed\":true}]}",
      "{\"response\":{\"status\":200,\"headers\":[],\"body\":\"ok\"},\"upstream\":[{\"method\":false,\"path\":null,\"headers\":{},\"body\":null}]}",
    ],
    fn(observations) {
      lab.Evidence(..evidence(), observations:)
      |> verify
      |> result.is_error
      |> should.be_true
    },
  )
}
