import gleam/string
import gleeunit/should
import mimic

pub fn help_test() {
  let assert Ok(output) = mimic.dispatch(["help"])
  string.contains(output, "workshop") |> should.be_true
  string.contains(output, "persona") |> should.be_true
}

pub fn version_test() {
  mimic.dispatch(["--version"]) |> should.equal(Ok("mimic 0.1.0"))
}

pub fn metrics_command_and_observability_alias_test() {
  mimic.dispatch(["metrics"]) |> should.be_ok
  mimic.dispatch(["obs", "metrics"]) |> should.be_ok
}

pub fn unknown_command_fails_test() {
  mimic.dispatch(["not-a-command"]) |> should.be_error
}

pub fn unknown_arguments_do_not_echo_secrets_test() {
  let assert Error(error) = mimic.dispatch(["secret-as-unknown-command"])
  string.contains(error, "secret-as-unknown-command") |> should.be_false
}
