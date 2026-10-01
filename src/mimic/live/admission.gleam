/// This boundary is deliberately not a caller-supplied "qualified" flag.
/// F02 has no approved Linux launcher or measured kernel/lifetime selftests.
import gleam/int
import gleam/result
import gleam/string

pub opaque type Admission {
  Synthetic(endpoint: String, port: Int)
}

pub type LiveInputs {
  LiveInputs(
    approved_by: String,
    account: String,
    endpoint: String,
    scenario: String,
  )
}

/// No process, Docker, native acquisition, endpoint or credential read occurs.
/// A future reviewed F02/F03 verifier must create a distinct opaque capability
/// here before a live/native adapter can use the common execution core.
pub fn live(inputs: LiveInputs) -> Result(Admission, String) {
  case
    inputs.approved_by == ""
    || inputs.account == ""
    || inputs.endpoint == ""
    || inputs.scenario == ""
  {
    True -> Error("live_explicit_operator_inputs_required")
    False ->
      Error(
        "live_admission_blocked_verified_f02_boundary_and_running_identity_missing",
      )
  }
}

pub fn native(_inputs: LiveInputs) -> Result(Admission, String) {
  Error("native_admission_blocked_verified_f02_boundary_missing")
}

/// Exact numeric loopback, explicit port, no DNS/URL normalization. In
/// particular CPA's operator service 8317 can never be a synthetic endpoint.
pub fn synthetic(endpoint: String) -> Result(Admission, String) {
  case string.split(endpoint, "http://127.0.0.1:") {
    ["", port] -> {
      use number <- result.try(
        int.parse(port)
        |> result.replace_error("live_synthetic_endpoint_invalid"),
      )
      case
        number > 1024
        && number <= 65_535
        && number != 8317
        && port == int.to_string(number)
      {
        True -> Ok(Synthetic(endpoint, number))
        False -> Error("live_synthetic_endpoint_invalid")
      }
    }
    _ -> Error("live_synthetic_numeric_loopback_required")
  }
}

pub fn endpoint(admission: Admission) -> String {
  admission.endpoint
}

pub fn port(admission: Admission) -> Int {
  admission.port
}
