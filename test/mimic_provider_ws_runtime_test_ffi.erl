-module(mimic_provider_ws_runtime_test_ffi).
-export([unlink_runtime/1]).

%% Only test code may break the opaque wrapper to simulate an abnormal actor
%% death. The test process must be unlinked before killing its actor.
unlink_runtime({runtime, _Subject, Pid, _Registry}) ->
    erlang:unlink(Pid),
    Pid.
