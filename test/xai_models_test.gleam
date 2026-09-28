import gleam/option.{None, Some}
import gleeunit/should
import mimic/providers/xai/endpoint
import mimic/providers/xai/models

pub fn model_metadata_is_not_blanket_capability_test() {
  let assert Some(model) = models.lookup("grok-4.7")
  model.context_tokens |> should.equal(500_000)
  model.reasoning_levels |> should.equal(["low", "medium", "high", "xhigh"])
  models.lookup("grok-unknown") |> should.equal(None)
  let config = endpoint.defaults(endpoint.ApiKey)
  models.validate("grok-4.7-build-fast", config, None, "")
  |> should.be_error
  models.validate("grok-4.7", config, Some("none"), "")
  |> should.be_error
  models.validate("grok-4.3", config, Some("none"), "")
  |> should.be_ok
  models.validate("grok-composer-2.5-fast", config, None, "")
  |> should.be_error
  models.validate("grok-composer-2.5-fast", config, None, "isolated")
  |> should.be_ok
}
