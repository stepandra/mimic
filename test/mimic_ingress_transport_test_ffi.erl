-module(mimic_ingress_transport_test_ffi).
-export([framing_cases/0, chunked_origin/0]).

%% Deterministic buffer shapes supplement the real socket test: TCP itself
%% may split a coalesced write before either reader sees the full buffer.
framing_cases() ->
    Body = binary:copy(<<"x">>, 70000),
    Upstream = <<"HTTP/1.1 200 OK\r\nContent-Length: 70000">>,
    Request = <<"POST /v1/messages HTTP/1.1\r\nContent-Length: 70000">>,
    ChunkBody = binary:copy(<<"y">>, 9000),
    MaxHead = binary:copy(<<"h">>, 65536),
    MaxLine = binary:copy(<<"l">>, 8192),
    try
        {ok, Upstream, Body} = mimic_ingress_ffi:split_head(
            <<Upstream/binary, "\r\n\r\n", Body/binary>>),
        {ok, Request, Body} = mimic_lab_ffi:split_head(
            <<Request/binary, "\r\n\r\n", Body/binary>>),
        {ok, <<"2328">>, ChunkBody} = mimic_ingress_ffi:split_line(
            <<"2328\r\n", ChunkBody/binary>>),
        more = mimic_ingress_ffi:split_head(<<MaxHead/binary, "\r\n\r">>),
        {ok, MaxHead, <<>>} =
            mimic_ingress_ffi:split_head(<<MaxHead/binary, "\r\n\r\n">>),
        {ok, MaxHead, <<>>} =
            mimic_lab_ffi:split_head(<<MaxHead/binary, "\r\n\r\n">>),
        more = mimic_ingress_ffi:split_line(<<MaxLine/binary, "\r">>),
        {ok, MaxLine, <<>>} =
            mimic_ingress_ffi:split_line(<<MaxLine/binary, "\r\n">>),
        {error, _} = mimic_ingress_ffi:split_head(
            <<MaxHead/binary, "x\r\n\r\n">>),
        {error, 413} = mimic_lab_ffi:split_head(
            <<MaxHead/binary, "x\r\n\r\n">>),
        {error, _} = mimic_ingress_ffi:split_line(
            <<MaxLine/binary, "x\r\n">>),
        {error, _} = mimic_ingress_ffi:next(
            {upstream, tcp, unused_socket, <<"100001\r\n">>, chunked}),
        {ok, nil}
    catch _:_ -> {error, <<"coalesced framing or size boundary failed">>}
    end.

chunked_origin() ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
                                        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    spawn(fun() ->
        case gen_tcp:accept(Listener, 5000) of
            {ok, Socket} ->
                {ok, _} = gen_tcp:recv(Socket, 0, 5000),
                Body = binary:copy(<<"x">>, 9000),
                Response = <<"HTTP/1.1 200 OK\r\nContent-Type: application/json"
                             "\r\nTransfer-Encoding: chunked\r\n"
                             "Connection: close\r\n\r\n2328\r\n",
                             Body/binary, "\r\n0\r\n\r\n">>,
                ok = gen_tcp:send(Socket, Response),
                gen_tcp:close(Socket);
            _ -> ok
        end,
        gen_tcp:close(Listener)
    end),
    Port.
