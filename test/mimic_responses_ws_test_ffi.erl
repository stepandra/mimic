-module(mimic_responses_ws_test_ffi).
-export([listen/0, connect/1, accept/1, send/2, recv_exact/2, close/1]).

%% Synthetic loopback mock only. No provider traffic, route, or WS server.
listen() ->
    case gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}},
                            {active, false}, {reuseaddr, true}]) of
        {ok, Socket} ->
            {ok, {_, Port}} = inet:sockname(Socket),
            {ok, {Socket, Port}};
        {error, _} -> {error, <<"loopback listen failed">>}
    end.

connect(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 3000) of
        {ok, Socket} -> {ok, Socket};
        {error, _} -> {error, <<"loopback connect failed">>}
    end.

accept(Socket) ->
    case gen_tcp:accept(Socket, 3000) of
        {ok, Peer} -> {ok, Peer};
        {error, _} -> {error, <<"loopback accept failed">>}
    end.

send(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        {error, _} -> {error, <<"loopback send failed">>}
    end.

recv_exact(Socket, Count) ->
    case gen_tcp:recv(Socket, Count, 3000) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, <<"loopback receive failed">>}
    end.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.
