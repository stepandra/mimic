-module(mimic_gateway_ws_ffi).
-export([takeover/2, receive_bytes/2, write/2, close/1]).

%% Pinned Mist 6 Connection layout. Domain and protocol decisions live in Gleam.
takeover({connection, _, Socket, Transport, _}, Pid) ->
    try
        Module = module(Transport),
        ok = options(Module, Socket, [{active, false}, {packet, raw},
                                     {send_timeout, 1000}, {send_timeout_close, true}]),
        case Module:controlling_process(Socket, Pid) of
            ok -> {ok, nil};
            _ -> {error, <<"WebSocket ownership unavailable">>}
        end
    catch _:_ -> {error, <<"WebSocket ownership unavailable">>} end.

receive_bytes({connection, _, Socket, Transport, _}, Timeout) ->
    try
        Module = module(Transport),
        case Module:recv(Socket, 0, Timeout) of
            {ok, Bytes} -> {ok, {some, Bytes}};
            {error, timeout} -> {ok, none};
            _ -> {error, <<"WebSocket disconnected">>}
        end
    catch _:_ -> {error, <<"WebSocket disconnected">>} end.

write({connection, _, Socket, Transport, _}, Bytes) ->
    try
        Module = module(Transport),
        case Module:send(Socket, Bytes) of
            ok -> {ok, nil};
            _ -> {error, <<"WebSocket write failed">>}
        end
    catch _:_ -> {error, <<"WebSocket write failed">>} end.

close({connection, _, Socket, Transport, _}) ->
    try (module(Transport)):close(Socket) catch _:_ -> ok end,
    nil.

module(tcp) -> gen_tcp;
module(ssl) -> ssl.

options(gen_tcp, Socket, Options) -> inet:setopts(Socket, Options);
options(ssl, Socket, Options) -> ssl:setopts(Socket, Options).
