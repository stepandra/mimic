import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import parity/lab
import parity/scope

fn v2() {
  let assert Ok(text) = lab.read("test/parity/v2/manifest.json")
  let assert Ok(manifest) = lab.parse_manifest(text)
  #(text, manifest)
}

pub fn historical_v1_matrix_remains_byte_identical_test() {
  let assert Ok(text) = lab.read("test/parity/manifest.json")
  lab.sha256(text)
  |> should.equal(
    "b90298fcab43caa15d7a2b6771403f34003e700fbbc0a894f7b2ec605caf3cbf",
  )
  let assert Ok(manifest) = lab.parse_manifest(text)
  lab.denominator(manifest) |> should.equal(25)
  scope.parse(text, manifest)
  |> should.equal(Ok(scope.Scope("cpa-provider-parity-v1", [])))
}

pub fn scoped_rows_retain_every_nonexcluded_requirement_test() {
  let assert Ok(old_text) = lab.read("test/parity/manifest.json")
  let assert Ok(old) = lab.parse_manifest(old_text)
  let #(_, current) = v2()
  let retained =
    list.filter(old.rows, fn(row) {
      !list.contains(["gemini", "antigravity", "copilot"], row.provider)
    })
  list.length(retained) |> should.equal(22)
  list.filter(current.rows, fn(row) { row.provider != "devin" })
  |> should.equal(retained)
  lab.denominator(current) |> should.equal(37)
}

pub fn excluded_providers_are_not_active_or_passing_test() {
  let #(text, manifest) = v2()
  let assert Ok(selected) = scope.parse(text, manifest)
  selected.id |> should.equal("cpa-provider-parity-v2-devin")
  list.map(selected.exclusions, fn(item) { #(item.provider, item.status) })
  |> should.equal([
    #("gemini", "out_of_scope"),
    #("antigravity", "out_of_scope"),
    #("copilot", "out_of_scope"),
  ])
  text
  |> string.replace("\"status\":\"out_of_scope\"", "\"status\":\"passed\"")
  |> scope.parse(manifest)
  |> result.is_error
  |> should.be_true
}

pub fn accidental_reactivation_of_excluded_provider_fails_test() {
  let #(text, manifest) = v2()
  let assert [first, ..] = manifest.rows
  let conflicting =
    lab.Capability(..first, id: "accidental-gemini", provider: "gemini")
  scope.parse(
    text,
    lab.Manifest(..manifest, rows: [conflicting, ..manifest.rows]),
  )
  |> result.is_error
  |> should.be_true
}

pub fn all_devin_rows_are_required_and_use_pinned_synthetic_fixtures_test() {
  let #(_, manifest) = v2()
  let devin = list.filter(manifest.rows, fn(row) { row.provider == "devin" })
  list.length(devin) |> should.equal(15)
  list.each(devin, fn(row) {
    row.required |> should.be_true
    row.auth_mode |> should.equal("session_token")
    row.upstream_mode |> should.equal("devin_connect_rpc")
    let assert Ok(fixture) = lab.load_fixture(row.fixture)
    fixture.reference |> should.equal(lab.cpa_revision)
    fixture.text
    |> string.contains("\"driver_kind\":\"scenario\"")
    |> should.be_true
  })
}

pub fn source_review_and_unsupported_devin_are_not_execution_passes_test() {
  let #(_, manifest) = v2()
  let assert Ok(row) =
    list.find(manifest.rows, fn(row) { row.id == "devin-count-estimate" })
  row.source_status |> should.equal("reviewed")
  let assert Ok(fixture) = lab.load_fixture(row.fixture)
  let evidence =
    lab.Evidence(
      1,
      row.id,
      fixture.id,
      fixture.digest,
      "mimic",
      "synthetic-test-revision",
      "exercise",
      "unsupported",
      "{}",
      [],
    )
  lab.verify(
    evidence,
    row.id,
    fixture,
    "mimic",
    "synthetic-test-revision",
    "exercise",
  )
  |> result.is_error
  |> should.be_true
  fixture.text
  |> string.contains("\"measurement_kind\":\"estimate\"")
  |> should.be_true
}
