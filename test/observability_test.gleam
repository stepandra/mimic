import gleam/string
import gleeunit
import gleeunit/should
import mimic/observability
import mimic/types.{Header}

pub fn main() {
  gleeunit.main()
}

pub fn redacts_header_dictionary_case_and_duplicate_test() {
  let redactor =
    observability.new() |> observability.register("synthetic-secret-123")
  let headers = [
    Header("AUTHORIZATION", "Bearer synthetic-secret-123"),
    Header("x-Api-Key", "synthetic-secret-123"),
    Header("X-Note", "prefix synthetic-secret-123 suffix"),
    Header("Set-Cookie", "synthetic-secret-123"),
  ]
  observability.headers(redactor, headers)
  |> should.equal([
    Header("AUTHORIZATION", "[REDACTED]"),
    Header("x-Api-Key", "[REDACTED]"),
    Header("X-Note", "prefix [REDACTED] suffix"),
    Header("Set-Cookie", "[REDACTED]"),
  ])
}

pub fn recursive_json_and_registered_values_test() {
  let redactor =
    observability.new() |> observability.register("synthetic-secret-123")
  let input =
    "{\"nested\":[{\"access_token\":\"synthetic-secret-123\",\"other\":\"Bearer synthetic-secret-123\"},{\"ok\":true,\"n\":2,\"null\":null}],\"X-API-KEY\":\"sensitive\",\"apiKey\":\"camel-secret\"}"
  let assert Ok(output) = observability.json_body(redactor, input)
  string.contains(output, "synthetic-secret-123") |> should.be_false()
  string.contains(output, "sensitive") |> should.be_false()
  string.contains(output, "camel-secret") |> should.be_false()
  string.contains(output, "Bearer [REDACTED]") |> should.be_true()
  string.contains(output, "\"ok\":true") |> should.be_true()
  observability.json_body(redactor, "{") |> should.be_error()
}

pub fn metric_label_is_opaque_test() {
  observability.increment(observability.Accepted, "synthetic-secret-123")
  let output = observability.metrics()
  string.contains(output, "synthetic-secret-123") |> should.be_false()
  string.contains(output, "mimic_acceptance_accepted_total") |> should.be_true()
}
