-module(mimic_account_ui_xai_test_ffi).
-export([focused/0]).

%% Explicit F07 module only. Never launches a live provider or the full suite.
focused() ->
    eunit:test(
        [account_ui_xai_test, gateway_xai_operations_test,
         account_ui_coordinator_test, account_ui_codex_test, account_ui_test],
        [verbose, {scale_timeouts, 20}]
    ) =:= ok.
