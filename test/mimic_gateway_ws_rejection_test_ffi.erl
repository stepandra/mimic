%% Synthetic parser-boundary tests: distinguish rejection from fixture timeout.
-module(mimic_gateway_ws_rejection_test_ffi).
-export([rejection/1]).

rejection(Socket) ->
    rejection(Socket, <<>>, erlang:monotonic_time(millisecond) + 3000).

rejection(_Socket, Acc, _Deadline) when byte_size(Acc) > 65536 ->
    {error, <<"fixture rejection header exceeds limit">>};
rejection(Socket, Acc, Deadline) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {N, _} -> {ok, binary:part(Acc, 0, N)};
        nomatch ->
            Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
            case gen_tcp:recv(Socket, 0, Remaining) of
                {ok, Bytes} -> rejection(Socket, <<Acc/binary, Bytes/binary>>, Deadline);
                {error, closed} when Acc =:= <<>> -> {ok, <<"peer closed">>};
                {error, timeout} -> {error, <<"fixture rejection timed out">>};
                _ -> {error, <<"fixture rejection read failed">>}
            end
    end.
