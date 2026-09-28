import gleeunit/should
import mimic/providers/codex/scenario

pub fn codex_runnable_synthetic_policy_scenario_test() {
  scenario.run() |> should.be_ok
}
