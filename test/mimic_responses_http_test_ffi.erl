-module(mimic_responses_http_test_ffi).
-export([listen/0, accept/1, connect/1, line_mode/2, read/2, write/2, close/1]).

%% Loopback-only socket primitives. All fixture/protocol decisions are Gleam.
listen() ->
    case gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}},
                           {reuseaddr, true}]) of
        {ok, Socket} ->
            {ok, {_, Port}} = inet:sockname(Socket),
            {ok, {Socket, Port}};
        {error, _} -> {error, <<"mock listen failed">>}
    end.

accept(Listener) ->
    result(gen_tcp:accept(Listener, 5000)).

connect(Port) ->
    result(gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 5000)).

line_mode(Socket, Enabled) ->
    Packet = case Enabled of true -> line; false -> raw end,
    case inet:setopts(Socket, [{packet, Packet}, {packet_size, 1048576}]) of
        ok -> {ok, nil};
        _ -> {error, <<"mock packet mode failed">>}
    end.

read(Socket, Count) ->
    case gen_tcp:recv(Socket, Count, 5000) of
        {ok, Bytes} -> {ok, {some, Bytes}};
        {error, closed} -> {ok, none};
        {error, _} -> {error, <<"mock read failed or timed out">>}
    end.

write(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        _ -> {error, <<"mock write failed">>}
    end.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.

result({ok, Value}) -> {ok, Value};
result({error, _}) -> {error, <<"mock socket operation failed">>}.
