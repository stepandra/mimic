/// Run with: gleam run -m claude_provider_scenarios
/// All network traffic stays on local ephemeral-port mocks.
import claude_provider_oauth_test as oauth
import claude_provider_request_test as request
import claude_provider_stream_test as stream
import claude_provider_transport_test as transport
import gleam/io

pub fn main() {
  oauth.ambiguous_token_success_is_rejected_test()
  oauth.ambiguous_oauth_rejection_is_not_retryable_test()
  oauth.oauth_json_guard_unicode_and_object_scopes_test()
  oauth.oauth_json_guard_byte_depth_and_value_bounds_test()
  oauth.oauth_json_guard_malformed_and_exchange_boundaries_test()
  oauth.pkce_and_callback_validation_test()
  oauth.local_json_exchange_refresh_and_429_test()
  oauth.refresh_rotation_identity_and_invalid_response_test()
  oauth.sanitized_failure_and_cooldown_test()
  oauth.token_exchange_requires_refresh_token_test()
  io.println(
    "PASS: PKCE, callback validation, JSON exchange/refresh, typed 429",
  )
  request.separate_auth_headers_and_framing_test()
  request.count_tokens_has_separate_profile_test()
  request.native_tool_thinking_and_cache_preservation_test()
  request.oauth_identity_replaces_selected_fields_only_test()
  request.beta_order_duplicates_and_forced_thinking_test()
  request.thinking_display_sampling_and_haiku_effort_test()
  request.stream_mode_is_one_authority_test()
  request.cache_ttl_order_and_breakpoint_limit_test()
  request.untrusted_origin_and_header_injection_test()
  request.identity_and_legacy_metadata_validation_test()
  io.println(
    "PASS: native request/auth/identity/beta/thinking/tool/cache cases",
  )
  stream.native_sse_every_character_boundary_test()
  stream.stop_reason_and_eof_are_not_completion_test()
  stream.errors_are_terminal_but_not_success_test()
  stream.terminal_is_sticky_across_trailing_chunks_test()
  stream.malformed_and_spoofed_terminal_events_test()
  stream.request_rejection_scope_and_delay_test()
  io.println("PASS: SSE segmentation, completion, usage and sanitized errors")
  transport.local_messages_and_count_tokens_wire_test()
  io.println("PASS: Messages and count_tokens over local HTTP/1.1")
}
