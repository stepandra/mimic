import devin_runtime_test
import devin_stream_runtime_test
import gleam/io

/// Local runtime-adapter evidence, deliberately NOT a parity-plan driver.
pub fn main() {
  devin_runtime_test.real_socket_buffered_chat_and_messages_test()
  devin_runtime_test.rejects_before_socket_test()
  devin_runtime_test.remote_binary_is_explicitly_unsupported_test()
  devin_runtime_test.real_socket_429_failover_test()
  devin_runtime_test.trailer_failure_never_replays_test()
  devin_runtime_test.actual_runtime_pull_adoption_and_cancellation_test()
  devin_stream_runtime_test.http_prefix_then_trailer_error_never_replays_test()
  devin_stream_runtime_test.http_same_chunk_prefix_survives_trailer_failure_test()
  devin_stream_runtime_test.http_truncated_after_prefix_is_started_without_stop_test()
  devin_stream_runtime_test.http_terminal_waits_for_eof_and_stops_once_test()
  devin_stream_runtime_test.tls_verified_stream_cancel_releases_lease_test()
  devin_stream_runtime_test.tls_unknown_ca_and_unsupported_origin_or_h2_send_no_bytes_test()
  io.println(
    "{\"scope\":\"devin_native_runtime_adapter\",\"synthetic\":true,\"scenarios_passed\":12,\"assembled_ingress\":false,\"client_stream_codec\":false,\"remote_enabled\":false,\"cpa_differential\":false,\"live_verified\":false}",
  )
}
