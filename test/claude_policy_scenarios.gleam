import claude_policy_test as policy
import claude_policy_wire_test as wire
import claude_provider_scenarios
import gleam/io

pub fn main() {
  policy.source_model_boundaries_test()
  policy.translated_and_native_sampling_matrix_test()
  policy.forced_tool_preserves_extensions_test()
  policy.cache_selection_and_explicit_ownership_test()
  policy.deferred_tools_final_system_and_ttl_order_test()
  policy.auth_model_operation_beta_matrix_test()
  policy.approved_profile_rejects_credentials_and_duplicate_identity_test()
  policy.advisor_beta_order_and_identity_ambiguity_test()
  policy.subagent_helper_cache_and_beta_matrix_test()
  policy.differential_fixture_expectations_test()
  policy.runtime_identity_isolation_and_context_guard_test()
  io.println("PASS: synthetic Claude source-policy matrix")
  wire.local_auth_model_kind_normalization_wire_matrix_test()
  wire.every_byte_split_tools_thinking_usage_and_malformed_prefix_test()
  wire.real_tls_byte_chunks_terminal_error_cancel_cleanup_once_test()
  io.println("PASS: Claude tool/thinking byte splits and real TLS cleanup")
  claude_provider_scenarios.main()
}
