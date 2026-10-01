import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/providers/contracts
import mimic/providers/kimi/models
import mimic/providers/kimi_compat/request
import mimic/providers/registry
import mimic/types.{type Capture, Header}

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

/// Reflect actual ingress: no inferred capabilities in Request.required.
fn prepare_native(body: String) -> Result(Capture, contracts.Failure) {
  prepare_mode(body, contracts.Buffered)
}

fn prepare_mode(
  body: String,
  mode: contracts.Mode,
) -> Result(Capture, contracts.Failure) {
  request.prepare_at(
    "/v1",
    contracts.Context(
      request.provider,
      "api_key",
      "compat-account",
      "http://127.0.0.1:8000",
      "compat-session",
      contracts.ApiKey("synthetic"),
    ),
    contracts.Request(
      request.provider,
      "api_key",
      "kimi-k2.8",
      "chat",
      "chat/completions",
      mode,
      [],
      "synthetic",
      None,
      body,
    ),
  )
}

fn streaming_body(body: String) -> String {
  "{\"stream\":true," <> string.drop_start(body, 1)
}

fn unsupported_before_io(body: String) {
  list.each(
    [
      #(body, contracts.Buffered),
      #(streaming_body(body), contracts.Streaming),
    ],
    fn(pair) {
      let #(body, mode) = pair
      prepare_mode(body, mode)
      |> should.equal(
        Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
      )
    },
  )
}

pub fn generic_audio_with_no_required_capabilities_fails_before_io_test() {
  unsupported_before_io(
    "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"AA==\",\"format\":\"wav\"}}]}]}",
  )
}

pub fn generic_content_media_policy_applies_to_all_message_roles_test() {
  list.each(
    [
      "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"AA==\",\"format\":\"wav\"}}",
      "{\"type\":\"audio\",\"audio\":{\"id\":\"synthetic\"}}",
      "{\"type\":\"output_audio\",\"data\":\"AA==\"}",
      "{\"type\":\"video_url\",\"video_url\":{\"url\":\"https://synthetic.invalid/video\"}}",
      "{\"type\":\"input_video\",\"video_url\":\"https://synthetic.invalid/video\"}",
      "{\"type\":\"file\",\"file\":{\"file_id\":\"file_synthetic\"}}",
      "{\"type\":\"input_file\",\"file_id\":\"file_synthetic\"}",
      "{\"type\":\"unknown_media\",\"data\":\"synthetic\"}",
    ],
    fn(part) {
      list.each(["system", "developer", "user", "assistant", "tool"], fn(role) {
        let id = case role {
          "tool" -> ",\"tool_call_id\":\"call_synthetic\""
          _ -> ""
        }
        unsupported_before_io(
          "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\""
          <> role
          <> "\""
          <> id
          <> ",\"content\":["
          <> part
          <> "]}]}",
        )
      })
    },
  )
}

pub fn generic_message_audio_reference_is_not_a_vendor_extension_test() {
  unsupported_before_io(
    "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"assistant\",\"content\":null,\"audio\":{\"id\":\"audio_synthetic\"}}]}",
  )
}

pub fn generic_supported_text_and_images_remain_byte_preserved_test() {
  list.each(["user", "tool"], fn(role) {
    let id = case role {
      "tool" -> ",\"tool_call_id\":\"call_synthetic\""
      _ -> ""
    }
    list.each(
      [
        "https://synthetic.invalid/audio.png",
        "data:image/png;base64,AA==",
      ],
      fn(url) {
        let body =
          "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\""
          <> role
          <> "\""
          <> id
          <> ",\"content\":[{\"type\":\"text\",\"text\":\"synthetic\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\""
          <> url
          <> "\",\"detail\":\"auto\"}}]}]}"
        let assert Ok(plan) = prepare_native(body)
        plan.body |> should.equal(body)
      },
    )
  })
}

pub fn generic_media_named_schema_arguments_and_vendor_data_are_not_scanned_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"vendor\":{\"audio\":{\"type\":\"input_audio\"}},\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"audio\",\"parameters\":{\"type\":\"object\",\"properties\":{\"audio\":{\"type\":\"string\"},\"content\":{\"type\":\"array\",\"items\":{\"type\":\"object\"}}}}}}],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"synthetic audio\",\"vendor\":{\"audio\":{\"type\":\"input_audio\"}}}]},{\"role\":\"assistant\",\"content\":null,\"vendor\":{\"video\":{\"type\":\"input_file\"}},\"tool_calls\":[{\"id\":\"call_synthetic\",\"type\":\"function\",\"function\":{\"name\":\"audio\",\"arguments\":\"{\\\"audio\\\":{\\\"type\\\":\\\"input_audio\\\"},\\\"content\\\":[{\\\"type\\\":\\\"input_audio\\\"}]}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_synthetic\",\"content\":\"{\\\"audio\\\":\\\"synthetic\\\"}\"}]}"
  let assert Ok(plan) = prepare_native(body)
  plan.body |> should.equal(body)
}

pub fn generic_malformed_content_or_disguised_audio_is_rejected_test() {
  list.each(
    [
      "{\"audio\":\"synthetic\"}",
      "[{\"type\":\"text\",\"text\":42}]",
      "[{\"type\":\"image_url\",\"image_url\":{\"url\":\"\"}}]",
      "[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:audio/wav;base64,AA==\"}}]",
      "[{\"type\":\"image_url\",\"image_url\":{\"file_id\":\"file_synthetic\"}}]",
    ],
    fn(content) {
      unsupported_before_io(
        "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"tool\",\"tool_call_id\":\"call_synthetic\",\"content\":"
        <> content
        <> "}]}",
      )
    },
  )
}

pub fn generic_stream_registration_is_distinct_and_api_key_only_test() {
  let assert Ok(model) = request.registration("kimi-k2.8")
  model.provider |> should.equal("openai-compatible-kimi")
  model.auth_modes |> should.equal(["api_key"])
  model.protocols |> should.equal(["chat"])
  model.operations |> should.equal(["chat/completions"])
  model.capabilities
  |> should.equal([
    contracts.Buffer,
    contracts.Stream,
    contracts.Tools,
    contracts.Images,
  ])
}

pub fn generic_stream_mode_must_match_the_native_body_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}"
  prepare_mode(body, contracts.Buffered) |> should.be_ok
  prepare_mode(body, contracts.Streaming) |> should.be_error
  let false_body = "{\"stream\":false," <> string.drop_start(body, 1)
  prepare_mode(false_body, contracts.Buffered) |> should.be_ok
  prepare_mode(false_body, contracts.Streaming) |> should.be_error
  let true_body = streaming_body(body)
  prepare_mode(true_body, contracts.Buffered) |> should.be_error
  let assert Ok(plan) = prepare_mode(true_body, contracts.Streaming)
  plan.body |> should.equal(true_body)
  plan.target |> should.equal("/v1/chat/completions")
  list.find(plan.headers, fn(header) { header.name == "Accept" })
  |> should.equal(Ok(Header("Accept", "text/event-stream")))
}

pub fn generic_stream_preserves_native_options_tools_images_and_opaque_fields_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"stream\":true,\"stream_options\":{\"include_usage\":true,\"vendor\":42},\"temperature\":0.2,\"top_p\":0.8,\"max_tokens\":64,\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"response_format\":{\"type\":\"json_object\"},\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"audio\",\"parameters\":{\"type\":\"object\",\"properties\":{\"audio\":{\"type\":\"string\"}}}}}],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"synthetic 思考🌍\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,AA==\",\"detail\":\"low\"}}]},{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"native\",\"tool_calls\":[{\"id\":\"call_synthetic\",\"type\":\"function\",\"function\":{\"name\":\"audio\",\"arguments\":\"{\\\"model\\\":\\\"kimi-for-coding\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_synthetic\",\"content\":\"synthetic result\"}],\"thinking\":{\"type\":\"opaque\"},\"vendor\":{\"model\":\"kimi-for-coding\",\"audio\":{\"type\":\"input_audio\"}}}"
  let assert Ok(plan) = prepare_mode(body, contracts.Streaming)
  plan.body |> should.equal(body)
  list.any(plan.headers, fn(header) {
    string.starts_with(string.lowercase(header.name), "x-msh-")
  })
  |> should.be_false
}

pub fn generic_stream_rejects_native_identity_state_and_unregistered_capabilities_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]}"
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
      contracts.Streaming,
      [contracts.Stream, contracts.Tools, contracts.Images],
      "synthetic",
      None,
      body,
    )
  request.prepare_at("/v1", context, req) |> should.be_ok
  list.each(
    [
      contracts.Request(..req, provider: "kimi"),
      contracts.Request(..req, auth_mode: "oauth"),
      contracts.Request(..req, protocol: "responses"),
      contracts.Request(..req, operation: "messages"),
      contracts.Request(..req, pinned_account: Some("compat-account")),
      contracts.Request(..req, required: [contracts.Audio]),
      contracts.Request(..req, required: [contracts.Continuation]),
      contracts.Request(..req, required: [contracts.WebSocket]),
    ],
    fn(req) {
      request.prepare_at("/v1", context, req)
      |> should.equal(
        Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
      )
    },
  )
}
