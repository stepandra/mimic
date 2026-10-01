%% Synthetic raw loopback transport. HTTP framing assertions live in Gleam.
-module(mimic_f44_http_boundary_test_ffi).
-export([run/0, exchange/4, sequential/2, websocket/2, websocket_with_upgrade/3,
         stop/1, timeout_probe/1, head_timeout_probe/1, connection_abi/1,
         retained_frame/1, without_unexpected_messages/2, log/2]).

run() ->
    case eunit:test(f44_http_boundary_test, [verbose, {scale_timeouts, 20}]) of
        ok -> halt(0);
        _ -> halt(1)
    end.

connection_abi({connection, _, _, _, _}) -> true;
connection_abi(_) -> false.

retained_frame({connection, {initial, Data}, _, _, _}) ->
    Data =:= synthetic_frame();
retained_frame(_) -> false.

%% Count only this synthetic WS actor's unknown-message event, never its data.
%% The test holds the actor at a barrier until this handler is installed.
without_unexpected_messages(Pid, Run) ->
    Ref = make_ref(),
    Name = mimic_f44_unknown_probe,
    ok = logger:add_handler(Name, ?MODULE,
                            #{level => all,
                              config => #{target => Pid,
                                          owner => self(), probe => Ref}}),
    try
        Run(),
        receive {Ref, unexpected} -> false after 0 -> true end
    after
        logger:remove_handler(Name),
        flush_probe(Ref)
    end.

log(#{msg := {"Actor discarding unexpected message: ~s", _},
      meta := #{pid := Pid}},
    #{config := #{target := Pid, owner := Owner, probe := Ref}}) ->
    Owner ! {Ref, unexpected},
    ok;
log(_, _) -> ok.

flush_probe(Ref) ->
    receive {Ref, _} -> flush_probe(Ref) after 0 -> ok end.

stop(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> nil
    after 3000 -> error(server_shutdown_timeout)
    end.

connect(Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port,
                   [binary, {active, false}, {nodelay, true}], 2000).

exchange(Port, Parts, Count, ExpectClose) ->
    {ok, Socket} = connect(Port),
    try
        lists:foreach(fun(Part) ->
            ok = gen_tcp:send(Socket, Part),
            %% Force the split to reach passive receive, not just two send calls.
            timer:sleep(2)
        end, Parts),
        {Responses, Rest} = responses(Socket, Count, <<>>, []),
        case ExpectClose of
            true ->
                <<>> = Rest,
                case gen_tcp:recv(Socket, 0, 2000) of
                    {error, closed} -> ok;
                    {error, econnreset} -> ok;
                    {error, timeout} -> throw(<<"connection close timeout">>);
                    {ok, _} -> throw(<<"unexpected trailing response">>)
                end;
            false -> ok
        end,
        {ok, Responses}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, format(Reason)}
    after
        gen_tcp:close(Socket)
    end.

sequential(Port, Requests) ->
    {ok, Socket} = connect(Port),
    try
        {Results, <<>>} = lists:mapfoldl(fun(Request, Acc) ->
            ok = gen_tcp:send(Socket, Request),
            {Response, Rest} = response(Socket, Acc),
            {Response, Rest}
        end, <<>>, Requests),
        {error, closed} = gen_tcp:recv(Socket, 0, 2000),
        {ok, Results}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, format(Reason)}
    after
        gen_tcp:close(Socket)
    end.

timeout_probe(Port) ->
    {ok, Socket} = connect(Port),
    Begin = erlang:monotonic_time(millisecond),
    Drip = spawn(fun() ->
        timer:sleep(8000),
        gen_tcp:send(Socket, <<"A">>),
        timer:sleep(4000),
        gen_tcp:send(Socket, <<"\r\n">>),
        timer:sleep(2000),
        gen_tcp:send(Socket, <<"0">>)
    end),
    try
        ok = gen_tcp:send(Socket, <<"POST /one HTTP/1.1\r\nHost: localhost\r\n",
                                   "Transfer-Encoding: chunked\r\n\r\n1\r\n">>),
        {ok, Bytes} = gen_tcp:recv(Socket, 0, 17500),
        {{<<"HTTP/1.1">>, 400, <<"/one:MALFORMED">>}, <<>>} = response(Socket, Bytes),
        {error, closed} = gen_tcp:recv(Socket, 0, 2000),
        {ok, erlang:monotonic_time(millisecond) - Begin}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, format(Reason)}
    after
        exit(Drip, kill),
        gen_tcp:close(Socket)
    end.

head_timeout_probe(Port) ->
    {ok, Socket} = connect(Port),
    Begin = erlang:monotonic_time(millisecond),
    Owner = self(),
    Ref = make_ref(),
    ok = gen_tcp:send(Socket, <<"G">>),
    Drip = spawn(fun() ->
        lists:foreach(fun({Delay, Bytes}) ->
            timer:sleep(Delay),
            Owner ! {Ref, gen_tcp:send(Socket, Bytes)}
        end, [{6000, <<"ET /one HTTP/1.1\r\nHo">>},
              {4000, <<"st: localhost\r\nX-Test: ">>},
              {4000, <<"progress">>}])
    end),
    try
        case gen_tcp:recv(Socket, 0, 17500) of
            {error, closed} -> ok;
            {error, econnreset} -> ok;
            {error, timeout} -> throw(<<"request head deadline reset by progress">>);
            {ok, _} -> throw(<<"incomplete head dispatched a response">>);
            {error, Reason} -> throw(format(Reason))
        end,
        %% All three later fragments made real progress, crossing the
        %% request-line/header boundary without resetting the deadline.
        lists:foreach(fun(_) ->
            receive
                {Ref, ok} -> ok;
                {Ref, Error} -> throw(format({head_progress, Error}))
            after 0 -> throw(<<"missing request head progress">>)
            end
        end, [1, 2, 3]),
        {ok, erlang:monotonic_time(millisecond) - Begin}
    catch
        throw:Failure -> {error, Failure};
        error:Failure -> {error, format(Failure)}
    after
        exit(Drip, kill),
        gen_tcp:close(Socket),
        flush_probe(Ref)
    end.

responses(_, 0, Rest, Acc) -> {lists:reverse(Acc), Rest};
responses(Socket, Count, Acc, Results) ->
    {Response, Rest} = response(Socket, Acc),
    responses(Socket, Count - 1, Rest, [Response | Results]).

response(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Headers, Body] ->
            [StatusLine | HeaderLines] = binary:split(Headers, <<"\r\n">>, [global]),
            [Version, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
            Lengths = [binary_to_integer(string:trim(Value)) ||
                Header <- HeaderLines,
                [Name, Value] <- [binary:split(Header, <<":">>)],
                string:lowercase(Name) =:= <<"content-length">>],
            [Length] = Lengths,
            {Payload, Rest} = body(Socket, Body, Length),
            {{Version, binary_to_integer(Status), Payload}, Rest};
        _ -> response(Socket, recv(Socket, Acc))
    end.

body(_, Acc, Length) when byte_size(Acc) >= Length ->
    <<Payload:Length/binary, Rest/binary>> = Acc,
    {Payload, Rest};
body(Socket, Acc, Length) -> body(Socket, recv(Socket, Acc), Length).

recv(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, Bytes} -> <<Acc/binary, Bytes/binary>>;
        {error, timeout} -> throw(<<"response timeout">>);
        {error, closed} -> throw(<<"closed before expected response">>);
        {error, Reason} -> throw(format(Reason))
    end.

websocket(Port, Split) ->
    websocket_with_upgrade(Port, Split, <<"websocket">>).

websocket_with_upgrade(Port, Split, Upgrade) ->
    {ok, Socket} = connect(Port),
    try
        Handshake = <<"GET /ws HTTP/1.1\r\nHost: localhost\r\n",
                      "Connection: Upgrade\r\nUpgrade: ", Upgrade/binary, "\r\n",
                      "Sec-WebSocket-Version: 13\r\n",
                      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n">>,
        Frame = synthetic_frame(),
        FirstSize = case Split of 0 -> byte_size(Frame); _ -> Split end,
        <<First:FirstSize/binary, Last/binary>> = Frame,
        ok = gen_tcp:send(Socket, <<Handshake/binary, First/binary>>),
        {Status, Rest} = ws_headers(Socket, <<>>),
        <<"HTTP/1.1 101", _/binary>> = Status,
        ok = gen_tcp:send(Socket, Last),
        Bytes = ws_frame(Socket, Rest),
        {ok, Bytes}
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, format(Reason)}
    after
        gen_tcp:close(Socket)
    end.

synthetic_frame() ->
    %% Masked RFC6455 text "synthetic", synthetic mask 1,2,3,4.
    Payload = <<"synthetic">>,
    Mask = <<1, 2, 3, 4>>,
    Masked = mask(Payload, Mask, 0, <<>>),
    <<16#81, (16#80 bor byte_size(Payload)), Mask/binary, Masked/binary>>.

ws_headers(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Headers, Rest] -> {Headers, Rest};
        _ -> ws_headers(Socket, recv(Socket, Acc))
    end.

ws_frame(_, <<16#81, Size, Data:Size/binary, _/binary>>) -> Data;
ws_frame(Socket, Acc) -> ws_frame(Socket, recv(Socket, Acc)).

mask(<<>>, _, _, Acc) -> Acc;
mask(<<Byte, Rest/binary>>, Mask, Offset, Acc) ->
    Value = Byte bxor binary:at(Mask, Offset rem 4),
    mask(Rest, Mask, Offset + 1, <<Acc/binary, Value>>).

format(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).
