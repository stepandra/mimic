import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import mimic/autopilot
import mimic/autopilot/inference
import mimic/autopilot/validation
import simplifile

fn pack() -> List(validation.Artifact) {
  [validation.Artifact("drift-1", "version changed")]
}

fn patch_pack() -> List(validation.Artifact) {
  [
    validation.Artifact("drift-1", "version changed"),
    validation.Artifact("persona.toml", "old = \"x\"\n"),
  ]
}

fn classified(confidence: String, span: String) -> String {
  "{\"class\":\"TRIVIAL\",\"confidence\":"
  <> confidence
  <> ",\"evidence\":[{\"artifact_id\":\"drift-1\",\"start\":0,\"end\":"
  <> span
  <> "}]}"
}

pub fn classifier_schema_and_citation_test() {
  let assert Ok(validation.Classified(value)) =
    autopilot.validate(autopilot.Classifier, classified("0.9", "7"), pack())
  value.class |> should.equal(validation.Trivial)
  let assert Ok(validation.Classified(integral)) =
    autopilot.validate(
      autopilot.Classifier,
      "{\"class\":\"TRIVIAL\",\"confidence\":0.9,\"evidence\":[{\"artifact_id\":\"drift-1\",\"start\":0.0,\"end\":1.0}]}",
      pack(),
    )
  integral.evidence
  |> should.equal([validation.Citation("drift-1", 0, 1)])
  autopilot.validate(
    autopilot.Classifier,
    "{\"class\":\"TRIVIAL\",\"confidence\":0.9,\"evidence\":[{\"artifact_id\":\"drift-1\",\"start\":0.5,\"end\":1.0}]}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(autopilot.Classifier, classified("0.9", "200"), pack())
  |> should.be_error
  autopilot.validate(
    autopilot.Classifier,
    "{\"class\":\"TRIVIAL\",\"confidence\":0.9,\"evidence\":[{\"artifact_id\":\"absent\",\"start\":0,\"end\":1}]}",
    pack(),
  )
  |> should.be_error
}

pub fn classifier_rejects_unknowns_enum_and_confidence_test() {
  autopilot.validate(
    autopilot.Classifier,
    "{\"class\":\"TRIVIAL\",\"confidence\":0.9,\"evidence\":[{\"artifact_id\":\"drift-1\",\"start\":0,\"end\":1}],\"promote\":true}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(
    autopilot.Classifier,
    "{\"class\":\"TRIVIAL\",\"confidence\":0.9}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(
    autopilot.Classifier,
    "{\"class\":\"TRIVIAL\",\"confidence\":0.9,\"evidence\":[{\"artifact_id\":\"drift-1\",\"start\":0,\"end\":1,\"extra\":1}]}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(autopilot.Classifier, classified("1.1", "1"), pack())
  |> should.be_error
  autopilot.validate(autopilot.Classifier, classified("-0.1", "1"), pack())
  |> should.be_error
  autopilot.validate(
    autopilot.Classifier,
    "{\"class\":\"UNKNOWN\",\"confidence\":0.9,\"evidence\":[]}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(
    autopilot.Classifier,
    classified("0.9", "1") <> "{}",
    pack(),
  )
  |> should.be_error
}

pub fn retry_and_schema_request_test() {
  let send = fn(_endpoint, payload, n) {
    string.contains(payload, "Authorization") |> should.equal(False)
    string.contains(payload, "[REDACTED]") |> should.equal(True)
    let assert Ok(format) =
      json.parse(payload, {
        use format <- decode.subfield(
          ["response_format", "type"],
          decode.string,
        )
        decode.success(format)
      })
    format |> should.equal("json_schema")
    case n {
      0 -> Ok("not json")
      1 -> Ok(classified("0.8", "999"))
      2 -> Ok(classified("0.8", "7"))
      _ -> Error("unexpected attempt")
    }
  }
  let assert Ok(validation.Classified(_)) =
    autopilot.invoke_with(
      send,
      inference.local(),
      "local",
      autopilot.Classifier,
      [
        validation.Artifact(
          "drift-1",
          "version changed\nAuthorization: Bearer synthetic-secret",
        ),
      ],
    )
}

pub fn exhaustion_asks_after_three_retries_test() {
  let assert Error(autopilot.Ask(_, options, reasons)) =
    autopilot.invoke_with(
      fn(_, _, _) { Ok("{}") },
      inference.local(),
      "local",
      autopilot.Classifier,
      pack(),
    )
  list.length(reasons) |> should.equal(4)
  list.length(options) |> should.equal(3)
}

pub fn endpoint_deny_test() {
  inference.validate_endpoint(inference.Endpoint(
    "http://example.com/v1/chat/completions",
    False,
  ))
  |> should.be_error
  inference.validate_endpoint(inference.Endpoint(
    "http://127.0.0.1:8080/v1/chat/completions",
    False,
  ))
  |> should.be_ok
  inference.validate_endpoint(inference.Endpoint(
    "https://owned.example/v1/chat/completions",
    True,
  ))
  |> should.be_ok
  inference.validate_endpoint(inference.Endpoint(
    "https://owned.example/v1/chat/completions",
    False,
  ))
  |> should.be_error
  inference.validate_endpoint(inference.Endpoint(
    "http://127.0.0.1:8080/v1/chat/completions?redirect=1",
    False,
  ))
  |> should.be_error
}

pub fn grounding_redacted_and_bounded_test() {
  let assert Ok([validation.Artifact(_, text)]) =
    validation.prepare([
      validation.Artifact(
        "drift-1",
        "hello\nAuthorization: Bearer sample\nworld",
      ),
    ])
  text |> should.equal("[REDACTED]")
  validation.prepare([
    validation.Artifact("drift-1", string.repeat("x", 2001)),
  ])
  |> should.be_error
  validation.prepare([
    validation.Artifact("drift-1", "x" <> string.repeat("\u{0301}", 100_000)),
  ])
  |> should.be_error
  validation.prepare([validation.Artifact("../path", "x")])
  |> should.be_error
}

pub fn structured_and_folded_credentials_never_reach_inference_test() {
  let send = fn(_, payload, _) {
    string.contains(payload, "c3ludGhldGlj") |> should.equal(False)
    string.contains(payload, "[REDACTED]") |> should.equal(True)
    Ok("{\"transition\":\"NO_COMMENTARY\"}")
  }
  list.each(
    [
      "{\n  \"name\":\"Authorization\",\n  \"value\":\"Basic c3ludGhldGlj\"\n}",
      "Authorization:\n  Basic c3ludGhldGlj",
    ],
    fn(text) {
      autopilot.invoke_with(
        send,
        inference.local(),
        "local",
        autopilot.Reporter,
        [validation.Artifact("drift-1", text)],
      )
      |> should.be_ok
    },
  )
}

pub fn inference_envelope_and_content_byte_bounds_test() {
  let huge = "x" <> string.repeat("\u{0301}", 100_000)
  inference.extract_content(
    "{\"choices\":[{\"message\":{\"content\":\"" <> huge <> "\"}}]}",
  )
  |> should.be_error
  inference.extract_content(
    "{\"choices\":[{\"message\":{\"content\":\""
    <> "x"
    <> string.repeat("\u{0301}", 9000)
    <> "\"}}]}",
  )
  |> should.be_error
}

pub fn escaped_grounding_cannot_bypass_request_byte_bound_test() {
  let text = string.repeat("\u{0001}", 2000)
  let artifacts =
    ["one", "two", "three", "four", "five", "six"]
    |> list.map(fn(id) { validation.Artifact(id, text) })
  let assert Error(autopilot.Ask("Inference request rejected", _, _)) =
    autopilot.invoke_with(
      fn(_, _, _) { panic as "oversized request must not be sent" },
      inference.local(),
      "local",
      autopilot.Reporter,
      artifacts,
    )
}

pub fn conservative_route_test() {
  let assert Ok(classification) =
    validation.validate_classifier(classified("0.69", "1"), pack())
  autopilot.route(classification, validation.Trivial)
  |> should.equal(autopilot.Route(validation.Major, True, True))
  let assert Ok(classification) =
    validation.validate_classifier(classified("0.7", "1"), pack())
  autopilot.route(classification, validation.Minor)
  |> should.equal(autopilot.Route(validation.Minor, True, False))
  autopilot.route(classification, validation.Breaking)
  |> should.equal(autopilot.Route(validation.Breaking, True, True))
}

fn diff() -> String {
  "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,1 +1,1 @@\n-old = \"x\"\n+old = \"y\"\n"
}

pub fn patch_is_not_applied_and_requires_lint_test() {
  let raw =
    json.object([
      #("patch", json.string(diff())),
      #("rationale", json.string("version string")),
      #("risk_notes", json.string("requires oracle")),
    ])
    |> json.to_string
  let assert Ok(validation.Proposed(proposal)) =
    autopilot.validate(autopilot.Hypothesizer, raw, patch_pack())
  autopilot.lint_proposal(proposal, fn(_) { Error("forbidden beta") })
  |> should.equal(Error("forbidden beta"))
  autopilot.lint_proposal(proposal, fn(_) { Ok(Nil) })
  |> should.be_ok
  autopilot.lint_proposal(
    validation.Hypothesis("not a diff", "reason", "risk"),
    fn(_) { Ok(Nil) },
  )
  |> should.be_error
  validation.minimal_diff(
    "--- a/other.toml\n+++ b/other.toml\n@@ -1,1 +1,1 @@\n-x\n+y\n",
  )
  |> should.equal(False)
  validation.minimal_diff(
    "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,8 +1,1 @@\n-x\n+y\n",
  )
  |> should.equal(False)
  validation.minimal_diff(
    "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,2 +1,2 @@\n-x\n+y\n \n",
  )
  |> should.equal(True)
  validation.minimal_diff(
    "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,1 +1,1 @@\n-x\n+y\n \n",
  )
  |> should.equal(False)
}

pub fn proposed_patch_requires_matching_supplied_base_test() {
  let raw = fn(patch) {
    json.object([
      #("patch", json.string(patch)),
      #("rationale", json.string("synthetic")),
      #("risk_notes", json.string("synthetic")),
    ])
    |> json.to_string
  }
  autopilot.validate(autopilot.Hypothesizer, raw(diff()), pack())
  |> should.be_error
  autopilot.validate(
    autopilot.Hypothesizer,
    raw(
      "--- a/persona.toml\n+++ b/persona.toml\n@@ -2,1 +2,1 @@\n-old = \"x\"\n+old = \"y\"\n",
    ),
    patch_pack(),
  )
  |> should.be_error
  autopilot.validate(
    autopilot.Hypothesizer,
    raw(
      "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,1 +1,1 @@\n-invented = \"x\"\n+old = \"y\"\n",
    ),
    patch_pack(),
  )
  |> should.be_error
  autopilot.validate(autopilot.Hypothesizer, raw(diff()), [
    validation.Artifact("persona.toml", "old = \"x\""),
  ])
  |> should.be_error
  autopilot.validate(autopilot.Hypothesizer, raw(diff()), [
    validation.Artifact("persona.toml", "old = \"x\"\ntoken = \"secret\"\n"),
  ])
  |> should.be_error
  autopilot.validate(
    autopilot.Hypothesizer,
    raw(
      "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,2 +1,2 @@\n old = \"x\"\n-invented = \"z\"\n+new = \"z\"\n",
    ),
    [validation.Artifact("persona.toml", "old = \"x\"\nactual = \"z\"\n")],
  )
  |> should.be_error
  let assert Ok(validation.Proposed(_)) =
    autopilot.validate(
      autopilot.Hypothesizer,
      raw(
        "--- a/persona.toml\n+++ b/persona.toml\n@@ -1,2 +1,2 @@\n old = \"x\"\n-actual = \"z\"\n+new = \"z\"\n",
      ),
      [validation.Artifact("persona.toml", "old = \"x\"\nactual = \"z\"\n")],
    )
  let assert Ok(validation.Proposed(_)) =
    autopilot.validate(
      autopilot.Hypothesizer,
      raw(
        "--- a/persona.toml\n+++ b/persona.toml\n@@ -2,1 +2,1 @@\n-actual = \"z\"\n+new = \"z\"\n",
      ),
      [validation.Artifact("persona.toml", "old = \"x\"\nactual = \"z\"\n")],
    )
}

pub fn diagnosis_report_and_escalation_test() {
  autopilot.validate(
    autopilot.Diagnostician,
    "{\"hypothesis\":\"NETWORK\",\"next_action\":\"RETRY_NETWORK\",\"patch\":\"\"}",
    pack(),
  )
  |> should.be_ok
  autopilot.validate(
    autopilot.Diagnostician,
    "{\"hypothesis\":\"invented unlimited prose\",\"next_action\":\"RETRY_NETWORK\",\"patch\":\"\"}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(
    autopilot.Diagnostician,
    "{\"hypothesis\":\"maybe\",\"next_action\":\"SKIP_ORACLE\",\"patch\":\"\"}",
    pack(),
  )
  |> should.be_error
  autopilot.validate(
    autopilot.Reporter,
    "{\"transition\":\"Oracle 99% passed\"}",
    pack(),
  )
  |> should.be_error
  let facts =
    autopilot.ReportFacts(
      "synthetic-run",
      validation.Minor,
      8,
      10,
      1,
      True,
      False,
      True,
      False,
    )
  let assert Ok(report) =
    autopilot.render_report(facts, validation.Narrative("REVIEW_REQUESTED"))
  string.contains(report, "Not eligible for promotion") |> should.equal(True)
  string.contains(report, "8/10 accepted") |> should.equal(True)
  let assert Ok(one) = autopilot.replan(autopilot.new_budget(), "oracle")
  let assert Ok(two) = autopilot.replan(one, "oracle")
  let assert Error(autopilot.Ask(_, _, _)) = autopilot.replan(two, "oracle")
  let assert Error(autopilot.Ask(_, _, _)) =
    autopilot.diagnostic_action(validation.Diagnosis(
      "needs review",
      "ASK_HUMAN",
      "",
    ))
}

pub fn diagnostic_repair_patch_requires_matching_base_test() {
  let raw =
    json.object([
      #("hypothesis", json.string("DATA")),
      #("next_action", json.string("REPAIR_PERSONA")),
      #("patch", json.string(diff())),
    ])
    |> json.to_string
  autopilot.validate(autopilot.Diagnostician, raw, pack())
  |> should.be_error
  autopilot.validate(autopilot.Diagnostician, raw, patch_pack())
  |> should.be_ok
}

pub fn schema_and_prompt_files_match_runtime_test() {
  let roles = [
    autopilot.Classifier,
    autopilot.Hypothesizer,
    autopilot.Diagnostician,
    autopilot.Reporter,
  ]
  list.each(roles, fn(role) {
    let name = autopilot.role_name(role)
    let assert Ok(schema_file) =
      simplifile.read("priv/autopilot/" <> name <> ".schema.json")
    let assert Ok(file_value) = json.parse(schema_file, decode.dynamic)
    let assert Ok(runtime_value) =
      json.parse(json.to_string(autopilot.schema(role)), decode.dynamic)
    file_value |> should.equal(runtime_value)
    let assert Ok(prompt) =
      simplifile.read("priv/autopilot/" <> name <> ".prompt.txt")
    string.trim(prompt) |> should.equal(autopilot.system_prompt(role))
  })
}

pub fn offline_cli_report_test() {
  let assert Ok(report) =
    autopilot.cli(["report", "examples/g_report_facts.json"])
  string.contains(report, "Not eligible for promotion") |> should.equal(True)
  string.contains(report, "synthetic-pb-1") |> should.equal(True)
}
