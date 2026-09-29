%% Synthetic two-account loopback upstream. Captures only test-owned requests.
-module(mimic_claude_429_test_ffi).
-export([start/1, port/1, requests/1, closed/1, stop/1]).

start(Responses) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Table = ets:new(?MODULE, [public, ordered_set]),
    Closed = atomics:new(1, []),
    Pid = spawn(fun() -> accept(Listener, Responses, Table, Closed) end),
    {Listener, Pid, Port, Table, Closed}.

accept(Listener, [Response | Remaining] = Responses, Table, Closed) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            Worker = spawn(fun() ->
                receive ready ->
                    try serve(Socket, Response, Table, Closed)
                    after gen_tcp:close(Socket) end
                end
            end),
            ets:insert(Table, {{worker, Worker}, Worker}),
            ok = gen_tcp:controlling_process(Socket, Worker),
            Worker ! ready,
            Next = case Remaining of [] -> Responses; _ -> Remaining end,
            accept(Listener, Next, Table, Closed);
        _ -> ok
    end.

serve(Socket, Response, Table, Closed) ->
    case read_request(Socket, []) of
        {ok, Request} ->
            ets:insert(Table, {{request, erlang:unique_integer([monotonic])}, Request}),
            %% In the stalled-body scenario only headers are sent. The client
            %% must close without waiting for the withheld body or this timeout.
            Sent = gen_tcp:send(Socket, Response),
            Result = case Sent of ok -> gen_tcp:recv(Socket, 0, 5000); _ -> Sent end,
            case Result of
                {error, closed} -> atomics:add_get(Closed, 1, 1);
                {error, econnreset} -> atomics:add_get(Closed, 1, 1);
                _ -> ok
            end;
        _ -> ok
    end.

read_request(Socket, Acc) ->
    ok = inet:setopts(Socket, [{packet, line}]),
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, <<"\r\n">>} ->
            Headers = iolist_to_binary(lists:reverse([<<"\r\n">> | Acc])),
            Length = case re:run(Headers, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                                [{capture, [1], binary}]) of
                {match, [Value]} -> binary_to_integer(Value);
                _ -> 0
            end,
            ok = inet:setopts(Socket, [{packet, raw}]),
            case Length of
                0 -> {ok, Headers};
                _ -> case gen_tcp:recv(Socket, Length, 5000) of
                    {ok, Body} -> {ok, <<Headers/binary, Body/binary>>};
                    Error -> Error
                end
            end;
        {ok, Line} -> read_request(Socket, [Line | Acc]);
        Error -> Error
    end.

port({_, _, Port, _, _}) -> Port.
requests({_, _, _, Table, _}) ->
    [Raw || {{request, _}, Raw} <- ets:tab2list(Table)].
closed({_, _, _, _, Closed}) -> atomics:get(Closed, 1).
stop({Listener, Pid, _, Table, _}) ->
    gen_tcp:close(Listener),
    exit(Pid, kill),
    [exit(Worker, kill) || {{worker, Worker}, _} <- ets:tab2list(Table)],
    ets:delete(Table),
    nil.
