-module(mimic_cli_ffi).
-export([exit/1, executable_available/1, otp_release/0]).

exit(Status) -> erlang:halt(Status).

executable_available(Name) ->
    os:find_executable(binary_to_list(Name)) =/= false.

otp_release() ->
    list_to_binary(erlang:system_info(otp_release)).
