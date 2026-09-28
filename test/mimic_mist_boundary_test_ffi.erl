%% Raw loopback client for exercising Mist's HTTP/1 parser, not an HTTP client
%% library (which may canonicalize duplicate headers before transmission).
-module(mimic_mist_boundary_test_ffi).
-export([request/2, handshake/2]).

request(Port, Bytes) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port,
                                   [binary, {active, false}], 3000),
    ok = gen_tcp:send(Socket, Bytes),
    Response = receive_all(Socket, <<>>),
    ok = gen_tcp:close(Socket),
    Response.

handshake(Port, Bytes) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port,
                                   [binary, {active, false}], 3000),
    ok = gen_tcp:send(Socket, Bytes),
    Headers = receive_headers(Socket, <<>>),
    ok = gen_tcp:close(Socket),
    Headers.

receive_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> Acc;
        nomatch ->
            case gen_tcp:recv(Socket, 0, 3000) of
                {ok, Bytes} -> receive_headers(Socket, <<Acc/binary, Bytes/binary>>);
                {error, closed} -> Acc;
                {error, timeout} -> <<Acc/binary, "SOCKET_TIMEOUT">>
            end
    end.

receive_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, Bytes} -> receive_all(Socket, <<Acc/binary, Bytes/binary>>);
        {error, closed} -> Acc;
        {error, timeout} -> <<Acc/binary, "SOCKET_TIMEOUT">>
    end.
