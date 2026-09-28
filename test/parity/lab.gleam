/// Test-only CPA conformance domain. No production provider dependencies.
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub const cpa_revision = "acdace936fa7df2905500c7f5e0a97d683138dea"

pub const source_prefix = "https://github.com/router-for-me/CLIProxyAPI/blob/"

pub type Capability {
  Capability(
    id: String,
    provider: String,
    auth_mode: String,
    input_protocol: String,
    upstream_mode: String,
    capability: String,
    required: Bool,
    source_status: String,
    source: String,
    fixture: String,
  )
}

pub type Manifest {
  Manifest(
    version: Int,
    reference: String,
    base: String,
    rows: List(Capability),
  )
}

pub type Fixture {
  Fixture(
    version: Int,
    id: String,
    reference: String,
    provenance: String,
    checks: List(String),
    restart: Bool,
    text: String,
    digest: String,
  )
}

pub type Evidence {
  Evidence(
    version: Int,
    capability_id: String,
    fixture_id: String,
    digest: String,
    target: String,
    revision: String,
    phase: String,
    status: String,
    observations: String,
    checks: List(#(String, Bool)),
  )
}

@external(erlang, "mimic_parity_ffi", "sha256")
pub fn sha256(text: String) -> String

fn row_decoder() {
  use id <- decode.field("id", decode.string)
  use provider <- decode.field("provider", decode.string)
  use auth_mode <- decode.field("auth_mode", decode.string)
  use input_protocol <- decode.field("input_protocol", decode.string)
  use upstream_mode <- decode.field("upstream_mode", decode.string)
  use capability <- decode.field("capability", decode.string)
  use required <- decode.field("required", decode.bool)
  use source_status <- decode.field("source_status", decode.string)
  use source <- decode.field("source", decode.string)
  use fixture <- decode.field("fixture", decode.string)
  decode.success(Capability(
    id:,
    provider:,
    auth_mode:,
    input_protocol:,
    upstream_mode:,
    capability:,
    required:,
    source_status:,
    source:,
    fixture:,
  ))
}

pub fn parse_manifest(text: String) -> Result(Manifest, String) {
  let decoder = {
    use version <- decode.field("schema_version", decode.int)
    use reference <- decode.field("cpa_revision", decode.string)
    use base <- decode.field("mimic_base_revision", decode.string)
    use rows <- decode.field("capabilities", decode.list(row_decoder()))
    decode.success(Manifest(version, reference, base, rows))
  }
  use manifest <- result.try(
    json.parse(text, decoder) |> result.map_error(fn(_) { "invalid manifest" }),
  )
  let ids = list.map(manifest.rows, fn(row) { row.id })
  case
    manifest.version == 1
    && manifest.reference == cpa_revision
    && manifest.rows != []
    && list.length(ids) == list.length(list.unique(ids))
    && list.all(manifest.rows, valid_row)
    && list.any(manifest.rows, fn(row) { row.required })
  {
    True -> Ok(manifest)
    False -> Error("empty, duplicate, unpinned or invalid capability matrix")
  }
}

fn valid_row(row: Capability) -> Bool {
  list.all(
    [
      row.id, row.provider, row.auth_mode, row.input_protocol, row.upstream_mode,
      row.capability,
    ],
    fn(value) { value != "" },
  )
  && list.contains(["reviewed", "pending"], row.source_status)
  && string.starts_with(row.source, source_prefix <> cpa_revision <> "/")
  && string.starts_with(row.fixture, "test/parity/fixtures/")
  && !string.contains(row.fixture, "..")
}

pub fn read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(_) { "cannot read " <> path })
}

pub fn load_fixture(path: String) -> Result(Fixture, String) {
  use text <- result.try(read(path))
  let decoder = {
    use version <- decode.field("schema_version", decode.int)
    use id <- decode.field("id", decode.string)
    use reference <- decode.field("cpa_revision", decode.string)
    use provenance <- decode.field("provenance", decode.string)
    use checks <- decode.field("required_checks", decode.list(decode.string))
    use restart <- decode.field("restart", decode.bool)
    decode.success(Fixture(
      version,
      id,
      reference,
      provenance,
      checks,
      restart,
      text,
      sha256(text),
    ))
  }
  use fixture <- result.try(
    json.parse(text, decoder)
    |> result.map_error(fn(_) { "invalid fixture: " <> path }),
  )
  case
    fixture.version == 1
    && fixture.reference == cpa_revision
    && fixture.provenance == "synthetic"
    && fixture.id != ""
    && fixture.checks != []
    && !list.contains(fixture.checks, "")
    && list.length(fixture.checks) == list.length(list.unique(fixture.checks))
  {
    True -> Ok(fixture)
    False -> Error("unversioned, unpinned or assertion-free fixture: " <> path)
  }
}

pub fn parse_evidence(text: String) -> Result(Evidence, String) {
  let check = {
    use name <- decode.field("name", decode.string)
    use passed <- decode.field("passed", decode.bool)
    decode.success(#(name, passed))
  }
  let decoder = {
    use version <- decode.field("schema_version", decode.int)
    use id <- decode.field("fixture_id", decode.string)
    use capability_id <- decode.field("capability_id", decode.string)
    use digest <- decode.field("fixture_sha256", decode.string)
    use target <- decode.field("target", decode.string)
    use revision <- decode.field("target_revision", decode.string)
    use phase <- decode.field("phase", decode.string)
    use status <- decode.field("status", decode.string)
    use observations <- decode.field("observations", decode.string)
    use checks <- decode.field("checks", decode.list(check))
    decode.success(Evidence(
      version,
      capability_id,
      id,
      digest,
      target,
      revision,
      phase,
      status,
      observations,
      checks,
    ))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(_) { "driver returned malformed evidence" })
}

/// Driver output is evidence only after binding it to the exact invocation.
/// Unsupported, skipped and source-only are never substitutes for assertions.
pub fn verify(
  evidence: Evidence,
  capability_id: String,
  fixture: Fixture,
  target: String,
  revision: String,
  phase: String,
) -> Result(Nil, String) {
  let names = list.map(evidence.checks, fn(check) { check.0 })
  case
    evidence.version == 1
    && evidence.capability_id == capability_id
    && evidence.fixture_id == fixture.id
    && evidence.digest == fixture.digest
    && evidence.target == target
    && evidence.revision == revision
    && evidence.phase == phase
    && revision != ""
    && { target != "cpa" || revision == cpa_revision }
  {
    False -> Error("stale, mismatched or unpinned driver evidence")
    True ->
      case
        evidence.status == "passed"
        && valid_observations(evidence.observations)
        && list.key_find(evidence.checks, "assembled_ingress") == Ok(True)
        && list.length(names) == list.length(list.unique(names))
        && list.all(fixture.checks, fn(name) {
          list.key_find(evidence.checks, name) == Ok(True)
        })
        && list.all(evidence.checks, fn(check) { check.1 })
      {
        True -> Ok(Nil)
        False -> Error("missing, failed, unsupported or skipped assertions")
      }
  }
}

fn valid_observations(text: String) -> Bool {
  case json.parse(text, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> dict.size(fields) > 0
    _ -> False
  }
}

/// v1 deliberately has NO volatile-field normalization. Header order/case,
/// duplicates, body bytes, SSE order and WS messages must survive comparison.
pub fn differential(a: Evidence, b: Evidence) -> Result(Nil, String) {
  case a.observations == b.observations {
    True -> Ok(Nil)
    False -> Error("CPA/MIMIC observations differ (no normalization in v1)")
  }
}

pub fn denominator(manifest: Manifest) -> Int {
  list.count(manifest.rows, fn(row) { row.required })
}

pub fn summary(manifest: Manifest, passed: Int) -> String {
  int.to_string(passed)
  <> "/"
  <> int.to_string(denominator(manifest))
  <> " required capability rows passed; live evidence: not_run"
}
