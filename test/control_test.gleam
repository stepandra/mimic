import gleam/bit_array
import gleam/http.{Delete, Get, Post, Put}
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/storage
import mimic/control
import mimic/demo
import mimic/dialect.{Anthropic}
import mimic/differ
import mimic/ingress
import mimic/ingress/keys
import mimic/lab
import mimic/management
import mimic/persona
import mimic/pipeline
import mimic/replay
import mimic/types.{Header}
import mimic/wire
import mimic/workshop

pub fn management_uses_real_stores_without_activating_drafts_test() {
  let assert Ok(directory) = private_directory()
  let assert Ok(backend) = control.backend(directory, directory, directory)
  let assert Ok(capture) = demo.fixture(8000)
  let assert Ok(profile) = persona.draft([capture])
  let content = persona.render(profile)
  let assert Ok(digest) = backend.create_persona("synthetic-lab", content)
  workshop.read_artifact(directory, digest) |> should.equal(Ok(content))
  backend.active_persona("synthetic-lab") |> should.be_error
  backend.promote("missing-run", "not-a-signature") |> should.be_error
}

pub fn management_key_changes_are_seen_by_ingress_registry_test() {
  let assert Ok(directory) = private_directory()
  let assert Ok(backend) = control.backend(directory, directory, directory)
  let synthetic_key = "synthetic-client-key-for-integration-only"
  backend.create_key("test-client", synthetic_key) |> should.be_ok
  keys.verify(directory, synthetic_key) |> should.equal(Ok(True))
  backend.keys() |> should.equal(Ok(["test-client"]))
  backend.delete_key("test-client") |> should.be_ok
  keys.verify(directory, synthetic_key) |> should.equal(Ok(False))
}

pub fn credential_metadata_does_not_expose_tokens_test() {
  let assert Ok(directory) = private_directory()
  let assert Ok(backend) = control.backend(directory, directory, directory)
  backend.create_credential(management.CredentialInput(
    "synthetic-credential",
    "synthetic-access-not-a-provider-token",
    "synthetic-refresh-not-a-provider-token",
    9_999_999_999_999,
  ))
  |> should.be_ok
  backend.credentials()
  |> should.equal(
    Ok([
      management.CredentialMetadata("synthetic-credential", 9_999_999_999_999),
    ]),
  )
  backend.delete_credential("synthetic-credential") |> should.be_ok
  backend.credentials() |> should.equal(Ok([]))
}

pub fn typed_drift_index_exposes_counts_not_arbitrary_artifacts_test() {
  let assert Ok(directory) = private_directory()
  let assert Ok(backend) = control.backend(directory, directory, directory)
  let assert Ok(capture) = demo.fixture(8000)
  let assert Ok(report) = differ.diff(capture, capture)
  let assert Ok(id) = workshop.artifact(directory, differ.report_json(report))
  control.record_drift(directory, id) |> should.be_ok
  backend.drift() |> should.equal(Ok([#(id, 0)]))
  let assert Ok(other) = workshop.artifact(directory, "not a drift report")
  control.record_drift(directory, other) |> should.be_error
  string.contains(id, "not a drift report") |> should.be_false
}

/// Management writes the stores that managed ingress reads on each request.
/// A draft alone cannot activate ingress; a gated local Workshop run can.
pub fn management_api_to_managed_ingress_over_loopback_test() {
  let assert Ok(directory) = private_directory()
  let assert Ok(backend) = control.backend(directory, directory, directory)
  let management_key = "synthetic-management-key-for-test-only"
  let client_key = "synthetic-client-key-for-loopback-only"
  let assert Ok(capture) = demo.fixture(8000)
  let assert Ok(profile) = persona.draft([capture])
  let draft =
    management.handle(
      api_request(
        Put,
        "/api/personas/synthetic-lab/drafts",
        json.object([#("content", json.string(persona.render(profile)))])
          |> json.to_string,
        management_key,
      ),
      management_key,
      4199,
      backend,
    )
  draft.status |> should.equal(201)
  management.handle(
    api_request(Get, "/api/personas/synthetic-lab/active", "", management_key),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(404)
  management.handle(
    api_request(
      Post,
      "/api/promotions",
      "{\"run_id\":\"unapproved\",\"signature\":\"synthetic-signature\"}",
      management_key,
    ),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(422)
  management.handle(
    api_request(Get, "/api/personas/synthetic-lab/active", "", management_key),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(404)

  let assert Ok(upstream_port) =
    lab.start_with(
      0,
      lab.Config(
        required_headers: [
          Header("Authorization", "Bearer synthetic-access-only"),
        ],
        failure_status: 400,
        status: 200,
        response_body: "{\"ok\":true}",
        sse_events: [],
      ),
    )
  let upstream = "http://127.0.0.1:" <> int.to_string(upstream_port)
  ingress.start_managed(
    0,
    upstream,
    directory,
    "synthetic-lab",
    "qa-credential",
    Anthropic,
  )
  |> should.be_error
  let assert Ok(_) =
    pipeline.run(directory, "qa-approved", pipeline.VersionBump)
  management.handle(
    api_request(Get, "/api/personas/synthetic-lab/active", "", management_key),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(200)
  management.handle(
    api_request(
      Post,
      "/api/credentials",
      "{\"id\":\"qa-credential\",\"access_token\":\"synthetic-access-only\",\"refresh_token\":\"synthetic-refresh-only\",\"expires_at_ms\":9999999999999}",
      management_key,
    ),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(201)
  management.handle(
    api_request(
      Post,
      "/api/keys",
      "{\"id\":\"qa-key\",\"token\":\"" <> client_key <> "\"}",
      management_key,
    ),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(201)
  let assert Ok(store) = storage.new(directory)
  auth.load(store, "qa-credential") |> should.be_ok
  let assert Ok(active_id) = workshop.pointer(directory, "synthetic-lab")
  let assert Ok(active_content) = workshop.read_artifact(directory, active_id)
  let assert Ok(active_profile) = persona.parse(active_content)
  list.any(active_profile.headers, fn(header) {
    string.lowercase(header.name) == "authorization"
    && header.source == "passthrough"
  })
  |> should.be_true
  replay.materialize(active_profile, capture) |> should.be_ok
  let assert Ok(port) =
    ingress.start_managed(
      0,
      upstream,
      directory,
      "synthetic-lab",
      "qa-credential",
      Anthropic,
    )
  ingress_request(port, client_key)
  |> should.equal(Ok(#(200, "{\"ok\":true}")))
  let assert Ok([forwarded]) = lab.requests(upstream_port)
  let assert Ok(observed) =
    wire.parse_request(forwarded, "ingress", "managed", upstream, "main")
  observed.headers
  |> list.filter(fn(header) { string.lowercase(header.name) == "host" })
  |> should.equal([
    Header("Host", "127.0.0.1:" <> int.to_string(upstream_port)),
  ])
  management.handle(
    api_request(Delete, "/api/keys/qa-key", "", management_key),
    management_key,
    4199,
    backend,
  ).status
  |> should.equal(200)
  ingress_request(port, client_key)
  |> should.equal(Ok(#(401, "{\"error\":\"unauthorized\"}")))
  ingress.stop(port) |> should.be_ok
  lab.stop(upstream_port) |> should.be_ok
}

pub fn auth_store_accepts_private_state_from_different_cwd_test() {
  let assert Ok(directory) = private_directory()
  validate_from_other_cwd(directory) |> should.be_ok
}

fn api_request(method, path, body: String, key: String) {
  request.Request(
    ..request.new(),
    method:,
    host: "127.0.0.1",
    path:,
    body: bit_array.from_string(body),
    headers: [
      #("authorization", "Bearer " <> key),
      #("content-type", "application/json"),
    ],
  )
}

@external(erlang, "mimic_control_test_ffi", "ingress_request")
fn ingress_request(port: Int, key: String) -> Result(#(Int, String), String)

@external(erlang, "mimic_control_test_ffi", "validate_from_other_cwd")
fn validate_from_other_cwd(directory: String) -> Result(Nil, String)

@external(erlang, "mimic_control_test_ffi", "private_directory")
fn private_directory() -> Result(String, String)
