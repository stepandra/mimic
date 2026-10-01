-module(mimic_devin_f27_catalog_test_ffi).
-export([with_servers/4, port/1, counts/1, finally/2, focused/0]).

%% Recovered from exact F27 63a0096e. SYNTHETIC numeric-loopback fixtures only.
%% Two configurable responses permit actual runtime selection/failover tests.
%% Inspect returns only a boolean; token-bearing wire data is never persisted.
focused() ->
    eunit:test([devin_catalog_test, devin_chat_projection_test,
        devin_messages_projection_test, devin_wire_test],
        [verbose, {scale_timeouts, 10}]) =:= ok.

with_servers(Response, SecondResponse, Inspect, Fun) ->
    Owner = self(),
    {Guard, Monitor} = spawn_monitor(fun() ->
        scope(Owner, erlang:monitor(process, Owner), [])
    end),
    Directory = filename:absname(filename:join(["build", "f27",
        "state-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))])),
    ok = filelib:ensure_dir(Directory),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Guard ! {own, {directory, Directory}},
    First = start(Response, Inspect, Guard),
    Second = start(SecondResponse, Inspect, Guard),
    try Fun(list_to_binary(Directory), First, Second)
    after
        Ref = make_ref(),
        Guard ! {finish, Ref},
        receive {Ref, cleaned} -> ok after 3000 -> error(f27_cleanup_timeout) end,
        receive {'DOWN', Monitor, process, Guard, normal} -> ok
        after 1000 -> error(f27_scope_survived) end
    end.

finally(Fun, Cleanup) ->
    try Fun() after Cleanup() end.

scope(Owner, Monitor, Owned) ->
    receive
        {own, Resource} -> scope(Owner, Monitor, [Resource | Owned]);
        {'ETS-TRANSFER', _, _, f27} -> scope(Owner, Monitor, Owned);
        {finish, Ref} -> cleanup(Owned), Owner ! {Ref, cleaned};
        {'DOWN', Monitor, process, Owner, _} -> cleanup(Owned)
    end.

cleanup(Owned) ->
    lists:foreach(fun
        ({server, Server}) -> stop(Server);
        ({directory, Path}) ->
            ok = file:del_dir_r(Path),
            {error, enoent} = file:read_link_info(Path)
    end, Owned).

start(Response, Inspect, Guard) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Table = ets:new(?MODULE, [public, {heir, Guard, f27}]),
    Counts = atomics:new(3, []),
    Acceptor = spawn(fun() -> accept(Listener, Response, Inspect, Table, Counts) end),
    Server = {Listener, Acceptor, Port, Table, Counts},
    Guard ! {own, {server, Server}},
    Server.

port({_, _, Port, _, _}) -> Port.
counts({_, _, _, _, C}) ->
    {atomics:get(C, 1), atomics:get(C, 2), atomics:get(C, 3)}.

accept(Listener, Response, Inspect, Table, Counts) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            atomics:add_get(Counts, 1, 1),
            Worker = spawn(fun() ->
                receive {serve, S} -> serve(S, Response, Inspect, Counts) end
            end),
            ets:insert(Table, {Worker}),
            ok = gen_tcp:controlling_process(Socket, Worker),
            Worker ! {serve, Socket},
            accept(Listener, Response, Inspect, Table, Counts);
        {error, _} -> ok
    end.

serve(Socket, Response, Inspect, Counts) ->
    try
        case read_request(Socket, <<>>) of
            {ok, Header, Body} ->
                atomics:add_get(Counts, 2, 1),
                case Inspect(Header, Body) of
                    true -> atomics:add_get(Counts, 3, 1);
                    false -> ok
                end,
                ok = gen_tcp:send(Socket, Response);
            _ -> ok
        end
    after gen_tcp:close(Socket) end.

read_request(Socket, Acc) when byte_size(Acc) =< 16384 ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Header, Body] ->
            case re:run(Header, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                    [{capture, [1], binary}]) of
                {match, [Length]} ->
                    Size = binary_to_integer(Length),
                    case Size =< 16384 andalso byte_size(Body) =< Size of
                        true when byte_size(Body) =:= Size -> {ok, Header, Body};
                        true ->
                            case gen_tcp:recv(Socket, Size - byte_size(Body), 2000) of
                                {ok, Rest} -> {ok, Header, <<Body/binary, Rest/binary>>};
                                Error -> Error
                            end;
                        false -> {error, limit}
                    end;
                _ -> {error, missing_length}
            end;
        [_] ->
            case gen_tcp:recv(Socket, 0, 2000) of
                {ok, Bytes} -> read_request(Socket, <<Acc/binary, Bytes/binary>>);
                Error -> Error
            end
    end;
read_request(_, _) -> {error, limit}.

stop({Listener, Acceptor, _, Table, _}) ->
    gen_tcp:close(Listener),
    await_dead(Acceptor),
    lists:foreach(fun({Pid}) -> await_dead(Pid) end, ets:tab2list(Table)),
    true = ets:delete(Table).

await_dead(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(f27_worker_survived) end.
