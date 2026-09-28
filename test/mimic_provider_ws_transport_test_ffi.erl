-module(mimic_provider_ws_transport_test_ffi).
-export([start/4, port/1, request/1, received/1, was_closed/1, stop/1]).

%% Synthetic loopback peer. It deliberately uses wire bytes rather than the
%% production codec so transport tests exercise the physical socket boundary.
start(Tls, Cert, Key, Mode) ->
    case listener(Tls, Cert, Key) of
        {ok, Listener, Temp} ->
            {ok, {_, Port}} = sockname(Tls, Listener),
            Table = ets:new(?MODULE, [public, ordered_set]),
            Pid = spawn(fun() -> accept(Tls, Listener, Table, Mode) end),
            {ok, {Tls, Listener, Pid, Port, Table, Temp}};
        {error, Reason} -> {error, Reason}
    end.

listener(false, _, _) ->
    case gen_tcp:listen(0, [binary, {ip, {127,0,0,1}},
                            {active, false}, {reuseaddr, true}]) of
        {ok, Socket} -> {ok, Socket, none};
        _ -> {error, <<"test TCP listen failed">>}
    end;
listener(true, Cert, Key) ->
    _ = ssl:start(),
    case mimic_recorder_tls_ffi:make_leaf(binary_to_list(Cert),
                                          binary_to_list(Key), "127.0.0.1") of
        {ok, Temp, Leaf, LeafKey} ->
            case ssl:listen(0, [binary, {active, false}, {reuseaddr, true},
                                {ip, {127,0,0,1}}, {certfile, Leaf},
                                {keyfile, LeafKey},
                                {alpn_preferred_protocols, [<<"http/1.1">>]}]) of
                {ok, Socket} -> {ok, Socket, {some, Temp}};
                _ ->
                    mimic_recorder_tls_ffi:cleanup(Temp),
                    {error, <<"test TLS listen failed">>}
            end;
        _ -> {error, <<"test TLS leaf failed">>}
    end.

sockname(false, Socket) -> inet:sockname(Socket);
sockname(true, Socket) -> ssl:sockname(Socket).

accept(false, Listener, Table, Mode) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Socket} ->
            try serve(false, Socket, Table, Mode)
            after gen_tcp:close(Socket) end;
        _ -> ok
    end;
accept(true, Listener, Table, Mode) ->
    case ssl:transport_accept(Listener, 5000) of
        {ok, Transport} ->
            case ssl:handshake(Transport, 5000) of
                {ok, Socket} ->
                    try serve(true, Socket, Table, Mode)
                    after ssl:close(Socket) end;
                _ -> ssl:close(Transport)
            end;
        _ -> ok
    end.

serve(Tls, Socket, Table, Mode) ->
    case read_lines(Tls, Socket, [], 0) of
        {ok, Request} ->
            ets:insert(Table, {request, Request}),
            Key = request_key(Request),
            Accept = base64:encode(crypto:hash(sha,
                <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
            Response = upgrade(Mode, Accept),
            case Mode of
                <<"stall">> ->
                    timer:sleep(500);
                <<"segmented">> ->
                    <<First:11/binary, Rest/binary>> = Response,
                    send(Tls, Socket, First),
                    timer:sleep(5),
                    send(Tls, Socket, [Rest, <<1,1,226, 137,1,112,
                                               0,1,130, 128,1,172,
                                               129,2,79,75>>]);
                <<"close">> ->
                    send(Tls, Socket, [Response, <<136,2,3,232>>]);
                <<"bad_frame">> ->
                    send(Tls, Socket, [Response, <<129,130,0,0,0,0,79,75>>]);
                <<"prefix_bad_frame">> ->
                    send(Tls, Socket, [Response, <<129,2,79,75,
                                                  129,130,0,0,0,0,79,75>>]);
                <<"large">> ->
                    send(Tls, Socket, [Response, <<129,127,65536:64>>,
                                       binary:copy(<<"x">>, 65536)]);
                <<"limit">> ->
                    send(Tls, Socket, [Response, <<129,126,4,1>>]);
                <<"eof">> ->
                    send(Tls, Socket, Response),
                    ok;
                _ -> send(Tls, Socket, Response)
            end,
            case Mode of
                <<"eof">> -> ok;
                _ ->
                    case recv(Tls, Socket, 0, 2000) of
                        {ok, Frame} -> ets:insert(Table, {received, Frame});
                        {error, closed} -> ets:insert(Table, {closed, true});
                        _ -> ok
                    end
            end;
        _ -> ok
    end.

read_lines(Tls, Socket, Acc, Size) when Size < 16384 ->
    ok = set_line(Tls, Socket),
    case recv_line(Tls, Socket) of
        {ok, <<"\r\n">>} ->
            {ok, iolist_to_binary(lists:reverse([<<"\r\n">> | Acc]))};
        {ok, Line} -> read_lines(Tls, Socket, [Line | Acc], Size + byte_size(Line));
        _ -> {error, invalid_request}
    end;
read_lines(_, _, _, _) -> {error, oversized_request}.

request_key(Request) ->
    {match, [Key]} = re:run(Request, <<"[Ss]ec-[Ww]eb[Ss]ocket-[Kk]ey: ([^\r]+)">>,
                             [{capture, [1], binary}]),
    Key.

upgrade(<<"bad_status">>, Accept) ->
    standard(<<"HTTP/1.1 200 OK\r\n">>, Accept, <<>>);
upgrade(<<"bad_accept">>, _Accept) ->
    standard(<<"HTTP/1.1 101 Switching Protocols\r\n">>, <<"invalid">>, <<>>);
upgrade(<<"extension">>, Accept) ->
    standard(<<"HTTP/1.1 101 Switching Protocols\r\n">>, Accept,
             <<"Sec-WebSocket-Extensions: permessage-deflate\r\n">>);
upgrade(<<"no_upgrade">>, Accept) ->
    <<"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Accept: ", Accept/binary, "\r\n\r\n">>;
upgrade(<<"oversize">>, Accept) ->
    standard(<<"HTTP/1.1 101 Switching Protocols\r\n">>, Accept,
             [<<"X-Big: ">>, binary:copy(<<"x">>, 9000), <<"\r\n">>]);
upgrade(<<"aggregate">>, Accept) ->
    standard(<<"HTTP/1.1 101 Switching Protocols\r\n">>, Accept,
             binary:copy(<<"X-A: 12345678901234567890\r\n">>, 700));
upgrade(_, Accept) ->
    standard(<<"HTTP/1.1 101 Switching Protocols\r\n">>, Accept, <<>>).

standard(Status, Accept, Extra) ->
    iolist_to_binary([Status, <<"Upgrade: websocket\r\nConnection: Upgrade\r\n",
                              "Sec-WebSocket-Accept: ">>, Accept, <<"\r\n">>,
                      Extra, <<"\r\n">>]).

set_line(false, Socket) -> inet:setopts(Socket, [{packet, line}]);
set_line(true, Socket) -> ssl:setopts(Socket, [{packet, line}]).
recv_line(false, Socket) -> gen_tcp:recv(Socket, 0, 3000);
recv_line(true, Socket) -> ssl:recv(Socket, 0, 3000).
recv(false, Socket, Count, Timeout) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    gen_tcp:recv(Socket, Count, Timeout);
recv(true, Socket, Count, Timeout) ->
    ok = ssl:setopts(Socket, [{packet, raw}]),
    ssl:recv(Socket, Count, Timeout).
send(false, Socket, Data) -> gen_tcp:send(Socket, Data);
send(true, Socket, Data) -> ssl:send(Socket, Data).

port({_, _, _, Port, _, _}) -> Port.
request({_, _, _, _, Table, _}) ->
    case ets:lookup(Table, request) of
        [{request, Value}] -> {some, Value};
        [] -> none
    end.
received({_, _, _, _, Table, _}) ->
    case ets:lookup(Table, received) of
        [{received, Value}] -> {some, Value};
        [] -> none
    end.
was_closed({_, _, _, _, Table, _}) ->
    ets:lookup(Table, closed) =:= [{closed, true}].
stop({Tls, Listener, Pid, _, Table, Temp}) ->
    case Tls of
        true -> ssl:close(Listener);
        false -> gen_tcp:close(Listener)
    end,
    exit(Pid, kill),
    ets:delete(Table),
    case Temp of
        {some, Directory} -> mimic_recorder_tls_ffi:cleanup(Directory);
        none -> ok
    end,
    nil.
