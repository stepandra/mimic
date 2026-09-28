-module(mimic_egress_test_ffi).
-export([start/1, start_drop/1, port/1, accepts/1, requests/1, stop/1,
         start_binary/0]).

%% A synthetic, loopback-only HTTP/1.1 fixture. Sessions persist until the
%% client or a Connection: close response closes them; accepts is a socket
%% count, not a request count.
start(Response) -> start_with(Response, false).
start_drop(Response) -> start_with(Response, true).

start_binary() ->
    start_with(<<"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n", 255>>, false).

start_with(Response, CloseAfter) ->
    case gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}},
                            {active, false}, {reuseaddr, true}]) of
        {ok, Listener} ->
            {ok, {_Address, Port}} = inet:sockname(Listener),
            Counter = atomics:new(2, []),
            Table = ets:new(?MODULE, [public, ordered_set]),
            Pid = spawn(fun() ->
                accept_loop(Listener, Response, CloseAfter, Counter, Table)
            end),
            {ok, {Listener, Pid, Port, Counter, Table}};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

port({_Listener, _Pid, Port, _Counter, _Table}) -> Port.
accepts({_Listener, _Pid, _Port, Counter, _Table}) -> atomics:get(Counter, 1).
requests({_Listener, _Pid, _Port, _Counter, Table}) ->
    [Raw || {_Id, Raw} <- ets:tab2list(Table)].
stop({Listener, Pid, _Port, _Counter, Table}) ->
    gen_tcp:close(Listener),
    exit(Pid, shutdown),
    ets:delete(Table),
    nil.

accept_loop(Listener, Response, CloseAfter, Counter, Table) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            atomics:add_get(Counter, 1, 1),
            spawn(fun() -> serve(Socket, Response, CloseAfter, Counter, Table) end),
            accept_loop(Listener, Response, CloseAfter, Counter, Table);
        {error, closed} -> ok;
        {error, _} -> ok
    end.

serve(Socket, Response, CloseAfter, Counter, Table) ->
    case request(Socket, []) of
        {ok, Raw} ->
            Id = atomics:add_get(Counter, 2, 1),
            ets:insert(Table, {Id, Raw}),
            case gen_tcp:send(Socket, Response) of
                ok ->
                    case CloseAfter orelse
                         binary:match(Response, <<"Connection: close">>) =/= nomatch of
                        false -> serve(Socket, Response, CloseAfter, Counter, Table);
                        true -> gen_tcp:close(Socket)
                    end;
                {error, _} -> gen_tcp:close(Socket)
            end;
        {error, _} -> gen_tcp:close(Socket)
    end.

request(Socket, Acc) ->
    ok = inet:setopts(Socket, [{packet, line}]),
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, <<"\r\n">>} ->
            Header = iolist_to_binary(lists:reverse([<<"\r\n">> | Acc])),
            Length = content_length(Header),
            ok = inet:setopts(Socket, [{packet, raw}]),
            case Length of
                0 -> {ok, Header};
                _ ->
                    case gen_tcp:recv(Socket, Length, 5000) of
                        {ok, Body} -> {ok, <<Header/binary, Body/binary>>};
                        Error -> Error
                    end
            end;
        {ok, Line} -> request(Socket, [Line | Acc]);
        Error -> Error
    end.

content_length(Header) ->
    case re:run(Header, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                [{capture, [1], binary}]) of
        {match, [Value]} -> binary_to_integer(Value);
        nomatch -> 0
    end.
