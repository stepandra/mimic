import gleam/list
import gleam/option.{None}
import gleeunit/should
import mimic/providers/contracts
import mimic/providers/kimi/models
import mimic/providers/kimi_compat/request
import mimic/providers/registry

pub fn native_and_generic_models_coexist_in_either_order_test() {
  let assert Ok(native) = models.registration("kimi-k2.8")
  let assert Ok(generic) = request.registration("kimi-k2.8")
  list.each([[native, generic], [generic, native]], fn(models) {
    let assert Ok(registry) = registry.new(models)
    registry.models(registry) |> list.length |> should.equal(2)
  })
}

pub fn generic_has_no_native_path_model_thinking_or_device_transform_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}],\"temperature\":0.2}"
  let context =
    contracts.Context(
      request.provider,
      "api_key",
      "compat-account",
      "http://127.0.0.1:8000",
      "compat-session",
      contracts.ApiKey("synthetic"),
    )
  let req =
    contracts.Request(
      request.provider,
      "api_key",
      "kimi-k2.8",
      "chat",
      "chat/completions",
      contracts.Buffered,
      [],
      "synthetic",
      None,
      body,
    )
  let assert Ok(plan) = request.prepare_at("/v1", context, req)
  plan.body |> should.equal(body)
  plan.target |> should.equal("/v1/chat/completions")
  list.any(plan.headers, fn(header) { header.name == "X-Msh-Device-Id" })
  |> should.be_false
  request.prepare_at("/v1", contracts.Context(..context, provider: "kimi"), req)
  |> should.be_error
  request.prepare_at(
    "/v1",
    contracts.Context(..context, auth_mode: "oauth"),
    req,
  )
  |> should.be_error
}

pub fn generic_duplicate_model_is_rejected_before_raw_forward_test() {
  let body =
    "{\"model\":\"hidden\",\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}"
  let context =
    contracts.Context(
      request.provider,
      "api_key",
      "compat-account",
      "http://127.0.0.1:8000",
      "compat-session",
      contracts.ApiKey("synthetic"),
    )
  let req =
    contracts.Request(
      request.provider,
      "api_key",
      "kimi-k2.8",
      "chat",
      "chat/completions",
      contracts.Buffered,
      [],
      "synthetic",
      None,
      body,
    )
  request.prepare_at("/v1", context, req) |> should.be_error
}
