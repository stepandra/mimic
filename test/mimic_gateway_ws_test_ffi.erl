%% Synthetic loopback fixtures only. No provider/network discovery.
-module(mimic_gateway_ws_test_ffi).
-export([listen/0, accept/1, connect/1, write/2, read/1, head/1, close/1]).

listen() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    {ok, {Socket, Port}}.
accept(Socket) -> gen_tcp:accept(Socket, 5000).
connect(Port) ->
    gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}], 5000).
write(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        _ -> {error, <<"fixture write failed">>}
    end.
read(Socket) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, Bytes} -> {ok, Bytes};
        _ -> {error, <<"fixture read failed">>}
    end.
head(Socket) -> head(Socket, <<>>).
head(_, Acc) when byte_size(Acc) > 65536 -> {error, <<"fixture header too large">>};
head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {N, 4} ->
            <<Header:N/binary, _:4/binary, Rest/binary>> = Acc,
            {ok, {Header, Rest}};
        nomatch ->
            case read(Socket) of
                {ok, Bytes} -> head(Socket, <<Acc/binary, Bytes/binary>>);
                Error -> Error
            end
    end.
close(Socket) -> gen_tcp:close(Socket), nil.
