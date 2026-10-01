-module(mimic_provider_deadline_test_ffi).
-export([with_paused_runtime/2]).

%% Dedicated fault test only: pause this test's private actor so Acquire is
%% queued until after caller expiry. Always resume before teardown.
with_paused_runtime({runtime, _, Pid, _}, Fun) ->
    true = erlang:suspend_process(Pid),
    try Fun()
    after true = erlang:resume_process(Pid) end.
