/// Run with `gleam run -m parity/runner -- check|baseline|release ...`.
import argv
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import parity/lab
import parity/scope
import simplifile

type Driver {
  Driver(argv: List(String), revision: String)
}

@external(erlang, "mimic_parity_ffi", "run")
fn execute(
  argv: List(String),
  plan: String,
  home: String,
) -> Result(String, String)

@external(erlang, "mimic_parity_ffi", "private_directory")
fn private_directory() -> Result(String, String)

@external(erlang, "mimic_parity_ffi", "fail")
fn fail() -> Nil

fn driver_decoder() {
  use args <- decode.field("argv", decode.list(decode.string))
  use revision <- decode.field("revision", decode.string)
  decode.success(Driver(args, revision))
}

fn drivers(path: String) {
  use text <- result.try(lab.read(path))
  let decoder = {
    use mimic <- decode.field("mimic", driver_decoder())
    use cpa <- decode.field("cpa", driver_decoder())
    decode.success(#(mimic, cpa))
  }
  json.parse(text, decoder)
  |> result.map_error(fn(_) { "invalid driver config" })
}

fn write(path: String, text: String) {
  simplifile.write(path, text)
  |> result.map_error(fn(_) { "cannot write parity artifact" })
}

fn invoke(
  row: lab.Capability,
  fixture: lab.Fixture,
  driver: Driver,
  target: String,
  phase: String,
  directory: String,
) -> Result(lab.Evidence, String) {
  let basename = directory <> "/" <> target <> "-" <> phase
  let plan =
    json.object([
      #("schema_version", json.int(1)),
      #("capability_id", json.string(row.id)),
      #("provider", json.string(row.provider)),
      #("auth_mode", json.string(row.auth_mode)),
      #("input_protocol", json.string(row.input_protocol)),
      #("upstream_mode", json.string(row.upstream_mode)),
      #("cpa_revision", json.string(lab.cpa_revision)),
      #("fixture_json", json.string(fixture.text)),
      #("fixture_sha256", json.string(fixture.digest)),
      #("target", json.string(target)),
      #("target_revision", json.string(driver.revision)),
      #("phase", json.string(phase)),
      #("state_dir", json.string(directory <> "/" <> target)),
    ])
  use _ <- result.try(write(basename <> ".plan.json", json.to_string(plan)))
  use output <- result.try(execute(
    driver.argv,
    basename <> ".plan.json",
    directory,
  ))
  use _ <- result.try(write(basename <> ".result.json", output))
  use evidence <- result.try(lab.parse_evidence(output))
  use _ <- result.try(lab.verify(
    evidence,
    row.id,
    fixture,
    target,
    driver.revision,
    phase,
  ))
  Ok(evidence)
}

fn run_target(row, fixture: lab.Fixture, driver, target, directory) {
  use first <- result.try(invoke(
    row,
    fixture,
    driver,
    target,
    "exercise",
    directory,
  ))
  case fixture.restart {
    False -> Ok([first])
    True -> {
      use second <- result.try(invoke(
        row,
        fixture,
        driver,
        target,
        "restart",
        directory,
      ))
      Ok([first, second])
    }
  }
}

fn run_row(row: lab.Capability, mimic: Driver, cpa: Driver, release: Bool) {
  use fixture <- result.try(lab.load_fixture(row.fixture))
  use directory <- result.try(private_directory())
  io.println("artifacts " <> row.id <> ": " <> directory)
  let a = run_target(row, fixture, mimic, "mimic", directory)
  // Execute both targets even if the first fails, to retain both failure paths.
  let b = case release {
    True -> run_target(row, fixture, cpa, "cpa", directory)
    False -> Error("not_run")
  }
  let comparison = case a, b {
    Ok(left), Ok(right) ->
      list.try_map(list.zip(left, right), fn(pair) {
        lab.differential(pair.0, pair.1)
      })
      |> result.map(fn(_) { Nil })
    Error(error), _ -> Error("MIMIC: " <> error)
    _, Error(error) -> Error("CPA: " <> error)
  }
  let passed = case release {
    False -> result.is_ok(a)
    True -> result.is_ok(comparison) && row.source_status == "reviewed"
  }
  let report =
    json.object([
      #("id", json.string(row.id)),
      #("required", json.bool(row.required)),
      #("source_evidence", json.string(row.source_status)),
      #("mock_tested", result_json(a)),
      #("cpa_mock_tested", result_json(b)),
      #("differential", case release {
        True -> result_json(comparison)
        False -> json.object([#("status", json.string("not_run"))])
      }),
      #("live_verified", json.string("not_run")),
      #("passed_in_selected_mode", json.bool(passed)),
      #("fixture_sha256", json.string(fixture.digest)),
      #("artifacts", json.string(directory)),
    ])
  io.println(
    row.id
    <> case passed {
      True -> ": selected-mode checks passed"
      False -> ": BLOCKED (see report and raw driver results)"
    },
  )
  Ok(#(row.required && passed, report))
}

fn result_json(value: Result(a, String)) -> json.Json {
  case value {
    Ok(_) -> json.object([#("status", json.string("passed"))])
    Error("not_run") -> json.object([#("status", json.string("not_run"))])
    Error(error) ->
      json.object([
        #("status", json.string("blocked")),
        #("reason", json.string(error)),
      ])
  }
}

fn report(
  manifest: lab.Manifest,
  selected_scope: scope.Scope,
  manifest_path: String,
  text: String,
  mode: String,
  outcomes: List(#(Bool, json.Json)),
) {
  use directory <- result.try(private_directory())
  let passed = list.count(outcomes, fn(item) { item.0 })
  let body =
    json.object([
      #("schema_version", json.int(1)),
      #("mode", json.string(mode)),
      #("scope_id", json.string(selected_scope.id)),
      #("manifest_path", json.string(manifest_path)),
      #("excluded_providers", scope.exclusions_json(selected_scope)),
      #("cpa_revision", json.string(lab.cpa_revision)),
      #("manifest_sha256", json.string(lab.sha256(text))),
      #("required_total", json.int(lab.denominator(manifest))),
      #("required_passed_in_selected_mode", json.int(passed)),
      #("live_verified", json.string("not_run")),
      #(
        "capabilities",
        json.array(list.map(outcomes, fn(item) { item.1 }), fn(x) { x }),
      ),
    ])
  let path = directory <> "/report.json"
  use _ <- result.try(write(path, json.to_string(body)))
  io.println("report " <> path)
  io.println(mode <> ": " <> lab.summary(manifest, passed))
  case mode {
    "baseline" ->
      io.println("Baseline mock evidence only; parity release NOT evaluated.")
    _ -> Nil
  }
  case passed == lab.denominator(manifest) {
    True -> Ok(Nil)
    False -> Error("required capability gate blocked; not parity passed")
  }
}

fn run(
  mode: String,
  config: String,
  manifest_path: String,
) -> Result(Nil, String) {
  use text <- result.try(lab.read(manifest_path))
  use manifest <- result.try(lab.parse_manifest(text))
  use selected_scope <- result.try(scope.parse(text, manifest))
  use _ <- result.try(
    list.try_map(manifest.rows, fn(row) { lab.load_fixture(row.fixture) }),
  )
  io.println("scope " <> selected_scope.id <> "; manifest " <> manifest_path)
  io.println("manifest sha256 " <> lab.sha256(text))
  case mode {
    "check" -> {
      io.println(
        "matrix/fixture schema valid; no capability execution or parity claim",
      )
      Ok(Nil)
    }
    _ -> {
      use pair <- result.try(drivers(config))
      use outcomes <- result.try(
        list.try_map(manifest.rows, fn(row) {
          run_row(row, pair.0, pair.1, mode == "release")
        }),
      )
      report(manifest, selected_scope, manifest_path, text, mode, outcomes)
    }
  }
}

pub fn main() {
  let outcome = case argv.load().arguments {
    ["check"] -> run("check", "", "test/parity/manifest.json")
    ["baseline", config] -> run("baseline", config, "test/parity/manifest.json")
    ["release", config] -> run("release", config, "test/parity/manifest.json")
    ["check", "--manifest", path] -> run("check", "", path)
    ["baseline", config, "--manifest", path] -> run("baseline", config, path)
    ["release", config, "--manifest", path] -> run("release", config, path)
    _ ->
      Error(
        "usage: check | baseline <drivers.json> | release <drivers.json> [--manifest <path>]",
      )
  }
  case outcome {
    Ok(_) -> Nil
    Error(error) -> {
      io.println(error)
      fail()
    }
  }
}
