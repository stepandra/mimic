import gleam/int
import gleam/string
import gleeunit/should
import mimic/pipeline
import mimic/workshop

pub fn local_trivial_bump_promotes_test() {
  let root = state_directory()
  let assert Ok(report) = pipeline.run(root, "trivial", pipeline.VersionBump)
  string.contains(report, "\"status\":\"promoted\"") |> should.be_true
  string.contains(report, "\"production_validated\":false") |> should.be_true
  workshop.pointer(root, "synthetic-lab") |> should.be_ok
}

pub fn breaking_baseline_never_promotes_test() {
  let root = state_directory()
  pipeline.run(root, "breaking", pipeline.RejectedBaseline)
  |> should.be_error
  workshop.pointer(root, "synthetic-lab") |> should.be_error
}

fn state_directory() -> String {
  ".mimic/test/pipeline-"
  <> int.to_string(timestamp())
  <> "-"
  <> int.to_string(unique_id())
}

@external(erlang, "erlang", "unique_integer")
fn unique_id() -> Int

@external(erlang, "erlang", "system_time")
fn timestamp() -> Int
