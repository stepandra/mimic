/// Deterministic synthetic adapter diagnostics. Not assembled-ingress parity.
import gleam/io
import xai_adapter_test
import xai_bridge_test
import xai_endpoint_test
import xai_oauth_guard_test
import xai_oauth_test
import xai_request_test
import xai_websocket_native_test

pub fn main() {
  xai_oauth_test.loopback_discovery_device_token_refresh_test()
  xai_oauth_guard_test.duplicate_discovery_key_rejected_before_selection_test()
  xai_oauth_guard_test.duplicate_token_key_rejected_before_grant_test()
  xai_oauth_guard_test.nested_duplicate_or_contradictory_429_is_unavailable_test()
  xai_oauth_guard_test.known_429_preserves_positive_delay_and_unproved_io_is_unavailable_test()
  xai_endpoint_test.origins_are_explicit_test()
  xai_endpoint_test.overrides_do_not_cross_transports_test()
  xai_request_test.namespace_roundtrip_and_alias_test()
  xai_request_test.native_server_tools_and_client_alias_remain_distinct_test()
  xai_bridge_test.compact_rejects_tool_aliases_and_bare_status_never_proves_rejection_test()
  xai_adapter_test.buffered_sse_collects_terminal_json_usage_and_runtime_credential_test()
  xai_adapter_test.valid_prefix_before_malformed_frame_is_emitted_then_cancelled_test()
  xai_adapter_test.terminal_with_known_bad_tail_does_not_report_success_test()
  xai_adapter_test.selected_account_origin_and_tool_map_are_per_open_test()
  xai_websocket_native_test.physical_ws_wss_api_key_oauth_tools_continuation_test()
  xai_websocket_native_test.malformed_ws_event_and_cross_origin_fail_closed_test()
  xai_websocket_native_test.runtime_rotation_invalidates_physical_xai_socket_test()
  xai_websocket_native_test.wire_identity_cannot_change_between_namespaces_test()
  io.println(
    "{\"schema_version\":1,\"scope\":\"xai_native_adapter\",\"synthetic\":true,\"cpa_revision\":\"acdace936fa7df2905500c7f5e0a97d683138dea\",\"loopback_device_refresh\":true,\"ambiguous_auth_fails_closed\":true,\"http_sse_two_accounts_two_origins\":true,\"api_key_and_oauth_separate\":true,\"tool_namespace_and_hosted_declarations\":true,\"ws_and_verified_wss\":true,\"ws_continuation_tool_pairing\":true,\"token_rotation_closes_socket\":true,\"terminal_usage_keepalive_cancel\":true,\"malformed_wire_identity_rejected\":true,\"assembled_ingress_exercised\":false,\"cpa_differential_exercised\":false,\"live_provider\":false}",
  )
}
