//// Test-only parity driver. Exercises actual xAI adapter/runtime diagnostics,
//// but deliberately cannot certify an unregistered assembled ingress route.

import argv
import gleam/bit_array
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import mimic/ir
import simplifile
import xai_bridge_test
import xai_oauth_test

const cpa_revision = "acdace936fa7df2905500c7f5e0a97d683138dea"

@external(erlang, "mimic_xai_scenario_ffi", "sha256")
fn sha256(bytes: BitArray) -> BitArray

pub fn main() {
  let result = case argv.load().arguments {
    [path] -> run(path)
    _ -> Error("Expected exactly one absolute parity plan filename")
  }
  case result {
    Ok(output) -> io.println(output)
    Error(_) ->
      // Invalid output schema intentionally blocks the lab instead of inventing
      // an observation for an unvalidated fixture.
      io.println(
        "{\"status\":\"failed\",\"error\":\"invalid xAI scenario plan\"}",
      )
  }
}

pub fn run(path: String) -> Result(String, String) {
  use _ <- result.try(require(string.starts_with(path, "/")))
  use raw <- result.try(
    simplifile.read(path) |> result.map_error(fn(_) { "Unreadable plan" }),
  )
  use plan <- result.try(ir.parse(raw))
  use fixture_json <- result.try(ir.string_field(plan, "fixture_json"))
  use expected_digest <- result.try(ir.string_field(plan, "fixture_sha256"))
  let digest =
    fixture_json
    |> bit_array.from_string
    |> sha256
    |> bit_array.base16_encode
    |> string.lowercase
  use _ <- result.try(require(expected_digest == digest))
  use fixture <- result.try(ir.parse(fixture_json))
  use _ <- result.try(require(
    ir.field(plan, "schema_version") == Some(ir.Integer(1)),
  ))
  use _ <- result.try(require(
    ir.field(fixture, "schema_version") == Some(ir.Integer(1)),
  ))
  use _ <- result.try(require(
    ir.string_field(plan, "cpa_revision") == Ok(cpa_revision),
  ))
  use _ <- result.try(require(
    ir.string_field(fixture, "cpa_revision") == Ok(cpa_revision),
  ))
  use capability <- result.try(ir.string_field(plan, "capability_id"))
  use fixture_id <- result.try(ir.string_field(fixture, "id"))
  use target <- result.try(ir.string_field(plan, "target"))
  use revision <- result.try(ir.string_field(plan, "target_revision"))
  use phase <- result.try(ir.string_field(plan, "phase"))
  use required <- result.try(ir.required(fixture, "required_checks"))
  use required <- result.try(ir.as_array(required))
  use names <- result.try(list.try_map(required, ir.as_string))
  use _ <- result.try(require(phase == "exercise" || phase == "restart"))
  let executed = target == "mimic" && phase == "exercise"
  case executed {
    True -> {
      xai_oauth_test.loopback_discovery_device_token_refresh_test()
      xai_bridge_test.api_key_and_oauth_use_actual_loopback_transport_test()
      xai_bridge_test.runtime_failover_stops_at_first_downstream_output_test()
      xai_bridge_test.runtime_cancel_releases_xai_lease_test()
    }
    False -> Nil
  }
  let observations =
    json.object([
      #(
        "scope",
        json.string("adapter diagnostics only; no assembled ingress request"),
      ),
      #("adapter_diagnostics_executed", json.bool(executed)),
      #("assembled_ingress_exercised", json.bool(False)),
      #("restart_exercised", json.bool(False)),
    ])
    |> json.to_string
  Ok(
    json.object([
      #("schema_version", json.int(1)),
      #("capability_id", json.string(capability)),
      #("fixture_id", json.string(fixture_id)),
      #("fixture_sha256", json.string(digest)),
      #("target", json.string(target)),
      #("target_revision", json.string(revision)),
      #("phase", json.string(phase)),
      #("status", json.string("unsupported")),
      #("observations", json.string(observations)),
      #(
        "checks",
        json.array(list.unique(["assembled_ingress", ..names]), fn(name) {
          json.object([
            #("name", json.string(name)),
            #("passed", json.bool(False)),
          ])
        }),
      ),
    ])
    |> json.to_string,
  )
}

fn require(valid: Bool) -> Result(Nil, String) {
  case valid {
    True -> Ok(Nil)
    False -> Error("Invalid parity plan")
  }
}
