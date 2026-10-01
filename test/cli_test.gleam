import gleam/string
import gleeunit/should
import mimic
import mimic/account_ui
import mimic/gateway
import mimic/live
import mimic/providers/devin/status_cli

pub fn help_test() {
  let assert Ok(output) = mimic.dispatch(["help"])
  string.contains(output, "workshop") |> should.be_true
  string.contains(output, "persona") |> should.be_true
  string.contains(output, "serve providers") |> should.be_true
  string.contains(output, "accounts ui serve") |> should.be_true
  string.contains(output, "providers status") |> should.be_true
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

pub fn provider_gateway_dispatch_test() {
  // Missing config must reach the new gateway, not the legacy ingress parser.
  mimic.dispatch(["serve", "providers"])
  |> should.equal(gateway.cli(["serve"]))
  mimic.dispatch(["providers"]) |> should.equal(gateway.cli([]))
  mimic.dispatch(["serve", "providers"]) |> should.be_error
}

pub fn account_ui_dispatch_test() {
  mimic.dispatch(["accounts", "ui"]) |> should.equal(account_ui.cli([]))
  mimic.dispatch(["accounts", "ui", "serve"])
  |> should.equal(account_ui.cli(["serve"]))
  mimic.dispatch(["accounts", "ui", "serve"]) |> should.be_error
}

pub fn provider_status_dispatch_precedes_generic_gateway_test() {
  mimic.dispatch(["providers", "status"]) |> should.equal(status_cli.cli([]))
  mimic.dispatch(["providers", "status", "synthetic-missing-config"])
  |> should.equal(status_cli.cli(["synthetic-missing-config"]))
  mimic.dispatch(["providers", "status"]) |> should.be_error
}

pub fn budgeted_scenario_dispatch_test() {
  mimic.dispatch(["live"]) |> should.equal(live.cli([]))
  mimic.dispatch(["live", "native"]) |> should.equal(live.cli(["native"]))
  mimic.dispatch(["live", "native"]) |> should.be_error
}
