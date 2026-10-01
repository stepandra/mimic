/// F04 bindings consume F01 data, not F01 execution or assertion evaluation.
/// All executable digests below are SUPPLIED CLAIMS, never running identity.
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import mimic/ir/json_guard

pub type Claim {
  Claim(
    artifact_sha256: String,
    source_sha256: String,
    dependencies_sha256: String,
    configuration_sha256: String,
  )
}

pub type Case {
  Case(
    id: String,
    row_id: String,
    method: String,
    path: String,
    transport: String,
  )
}

pub opaque type Binding {
  Binding(
    contract_sha256: String,
    case_binding_sha256: String,
    selected: Case,
    cpa_revision: String,
    clients_lock_sha256: String,
    historical_manifest_sha256: String,
    candidate: Claim,
    reference: Claim,
  )
}

@external(erlang, "mimic_live_ffi", "sha256")
fn hash(bytes: BitArray) -> String

pub fn sha256(text: String) -> String {
  hash(bit_array.from_string(text))
}

pub fn valid_digest(text: String) -> Bool {
  string.byte_size(text) == 64
  && list.all(string.to_graphemes(text), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}

pub fn claim_decoder() -> decode.Decoder(Claim) {
  use artifact <- decode.field("artifact_sha256", decode.string)
  use source <- decode.field("source_sha256", decode.string)
  use dependencies <- decode.field("dependencies_sha256", decode.string)
  use configuration <- decode.field("configuration_sha256", decode.string)
  decode.success(Claim(artifact, source, dependencies, configuration))
}

fn valid_claim(claim: Claim) -> Bool {
  list.all(
    [
      claim.artifact_sha256, claim.source_sha256, claim.dependencies_sha256,
      claim.configuration_sha256,
    ],
    valid_digest,
  )
}

/// `expected_sha256` is the explicit operator's selected F01 input, not proof
/// of source authenticity. No F01 validator, launcher or Python is invoked.
pub fn bind(
  contract_bytes: String,
  expected_sha256: String,
  case_id: String,
  candidate: Claim,
  reference: Claim,
) -> Result(Binding, String) {
  use _ <- result.try(
    json_guard.validate(contract_bytes, 1_048_576, 32, 100_000)
    |> result.replace_error("live_contract_json_invalid"),
  )
  let digest = sha256(contract_bytes)
  use _ <- result.try(
    case
      valid_digest(expected_sha256)
      && digest == expected_sha256
      && valid_claim(candidate)
      && valid_claim(reference)
    {
      True -> Ok(Nil)
      False -> Error("live_contract_or_identity_claim_mismatch")
    },
  )
  let selected_decoder = {
    use version <- decode.field("version", decode.int)
    use row_id <- decode.field("row_id", decode.string)
    use method <- decode.subfield(["route", "method"], decode.string)
    use path <- decode.subfield(["route", "path"], decode.string)
    use transport <- decode.subfield(["route", "transport"], decode.string)
    decode.success(#(version, Case(case_id, row_id, method, path, transport)))
  }
  let decoder = {
    use schema <- decode.field("schema", decode.string)
    use scope <- decode.field("scope_id", decode.string)
    use revision <- decode.subfield(["cpa", "revision"], decode.string)
    use clients <- decode.subfield(["clients_lock", "sha256"], decode.string)
    use historical <- decode.subfield(["historical", "sha256"], decode.string)
    use selected <- decode.subfield(["cases", case_id], selected_decoder)
    decode.success(#(schema, scope, revision, clients, historical, selected))
  }
  use decoded <- result.try(
    json.parse(contract_bytes, decoder)
    |> result.replace_error("live_f01_case_missing_or_invalid"),
  )
  let #(schema, scope, revision, clients, historical, #(version, selected)) =
    decoded
  use _ <- result.try(
    case
      schema == "mimic.final-parity-contract/v1"
      && scope == "mimic-final-v1"
      && version == 1
      && selected.id == selected.row_id <> ".final-v1"
      && revision == "acdace936fa7df2905500c7f5e0a97d683138dea"
      && clients
      == "c3e2985192d3725e4ddd2a8ff0634630a5a0798af393182c443e00f5ddfbf85a"
      && historical
      == "3967cf7f03aff95d39f57d6b2590caecec5ba3f367bab11bde0f233121eb06d9"
    {
      True -> Ok(Nil)
      False -> Error("live_f01_scope_or_pin_mismatch")
    },
  )
  // Fixed-order structured encoding. Hash binds EVERY exact contract byte via
  // its digest, plus the selected ID. This is not a F01 canonical case hash.
  let case_binding =
    json.array(["mimic.f04-case-binding/v1", digest, selected.id], json.string)
    |> json.to_string
    |> sha256
  Ok(Binding(
    digest,
    case_binding,
    selected,
    revision,
    clients,
    historical,
    candidate,
    reference,
  ))
}

pub fn selected(binding: Binding) -> Case {
  binding.selected
}

pub fn contract_sha256(binding: Binding) -> String {
  binding.contract_sha256
}

pub fn case_binding_sha256(binding: Binding) -> String {
  binding.case_binding_sha256
}

pub fn claims(binding: Binding) -> #(Claim, Claim) {
  #(binding.candidate, binding.reference)
}

pub fn encode_claim(claim: Claim) -> json.Json {
  json.object([
    #("artifact_sha256", json.string(claim.artifact_sha256)),
    #("source_sha256", json.string(claim.source_sha256)),
    #("dependencies_sha256", json.string(claim.dependencies_sha256)),
    #("configuration_sha256", json.string(claim.configuration_sha256)),
  ])
}

pub fn encode(binding: Binding) -> json.Json {
  json.object([
    #("contract_sha256", json.string(binding.contract_sha256)),
    #("case_id", json.string(binding.selected.id)),
    #("f04_case_binding_sha256", json.string(binding.case_binding_sha256)),
    #("binding_schema", json.string("mimic.f04-case-binding/v1")),
    #("cpa_revision", json.string(binding.cpa_revision)),
    #("clients_lock_sha256", json.string(binding.clients_lock_sha256)),
    #(
      "historical_manifest_sha256",
      json.string(binding.historical_manifest_sha256),
    ),
    #("candidate_claim", encode_claim(binding.candidate)),
    #("reference_claim", encode_claim(binding.reference)),
    #("running_identity", json.string("unverified")),
    #("differential", json.string("not_run")),
    #("native", json.string("not_run")),
    #("live", json.string("not_run")),
  ])
}
