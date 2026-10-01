%% Synthetic, loopback-only F06 test primitives. No provider credentials.
-module(mimic_account_ui_codex_test_ffi).
-export([focused/0, request/5, port_closed/1]).

focused() ->
    eunit:test([account_ui_codex_test], [verbose, {scale_timeouts, 20}]) =:= ok.

request(Port, Method, Path, Headers, Body) ->
    try mimic_account_ui_test_ffi:request(Port, Method, Path, Headers, Body)
    catch error:{badmatch, {error, econnrefused}} -> {0, [], <<>>};
          error:{badmatch, {error, closed}} -> {0, [], <<>>}
    end.

port_closed(Port) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}], 1000) of
        {ok, Socket} -> gen_tcp:close(Socket), false;
        {error, econnrefused} -> true;
        {error, _} -> false
    end.
