import gleam/list
import gleeunit/should
import mimic/drive

@external(erlang, "mimic_f_test_ffi", "drive_deadline")
fn drive_deadline() -> Result(Int, String)

const valid = "
image = \"example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"
executable = \"/usr/bin/cli\"
seed = 42
args = [\"prompt with ; shell text\", \"--short\"]
expected_request_kinds = [\"chat\"]
"

pub fn pinned_args_and_no_shell_test() {
  let assert Ok(config) = drive.parse(valid)
  let assert Ok(0) =
    drive.run_with(config, fn(args) {
      list.contains(args, "prompt with ; shell text") |> should.be_true
      list.contains(args, "--network=none") |> should.be_true
      list.contains(args, "--user=65534:65534") |> should.be_true
      list.contains(args, "--read-only") |> should.be_true
      list.contains(args, "--cap-drop=ALL") |> should.be_true
      list.contains(args, "--pids-limit=64") |> should.be_true
      list.contains(args, "--memory=512m") |> should.be_true
      let assert ["--", image, ..] =
        list.drop_while(args, fn(arg) { arg != "--" })
      image |> should.equal(config.image)
      Ok(0)
    })
}

pub fn rejects_unpinned_test() {
  let config = drive.Drive("latest", "/usr/bin/cli", 1, [], ["chat"], "", "")
  let assert Error(_) =
    drive.run_with(config, fn(_) { panic as "no invocation" })
}

pub fn rejects_option_image_even_with_digest_test() {
  let bad =
    drive.Drive(
      "--label=escape@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "/usr/bin/cli",
      1,
      ["--privileged", "--user=0", "--volume=/:/host", "unpinned:latest"],
      ["chat"],
      "",
      "",
    )
  let assert Error(_) = drive.run_with(bad, fn(_) { panic as "no invocation" })
}

pub fn wall_deadline_survives_continuous_child_output_test() {
  let assert Error("Docker timed out") = drive_deadline()
}
