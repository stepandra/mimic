import devin_runtime_test
import gleam/io

/// Local runtime-adapter evidence, deliberately NOT a parity-plan driver.
pub fn main() {
  devin_runtime_test.real_socket_buffered_chat_and_messages_test()
  devin_runtime_test.rejects_before_socket_test()
  devin_runtime_test.remote_binary_is_explicitly_unsupported_test()
  devin_runtime_test.real_socket_429_failover_test()
  devin_runtime_test.trailer_failure_never_replays_test()
  devin_runtime_test.actual_runtime_pull_adoption_and_cancellation_test()
  io.println(
    "{\"scope\":\"devin_runtime_adapter\",\"scenarios_passed\":6,\"assembled_ingress\":false,\"cpa_differential\":false,\"live_verified\":false}",
  )
}
