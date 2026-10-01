-module(mimic_devin_chat_projection_test_ffi).
-export([with_servers/3, port/1, counts/1]).

%% Synthetic HTTP sockets only. Never retain/log token-bearing requests.
%% A monitored scope owns the private state directory and both fixture servers.
with_servers(Response, CloseAfter, Fun) ->
    Owner = self(),
    {Guard, Monitor} = spawn_monitor(fun() ->
        scope(Owner, erlang:monitor(process, Owner), [])
    end),
    Directory = filename:absname(filename:join(["build", "f23",
        "state-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))])),
    ok = filelib:ensure_dir(Directory),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Guard ! {own, {directory, Directory}},
    First = start(Response, CloseAfter, Guard),
    Second = start(<<"HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>,
        true, Guard),
    try Fun(list_to_binary(Directory), First, Second)
    after
        Ref = make_ref(),
        Guard ! {finish, Ref},
        receive {Ref, cleaned} -> ok after 3000 -> error(f23_cleanup_timeout) end,
        receive {'DOWN', Monitor, process, Guard, normal} -> ok
        after 1000 -> error(f23_scope_survived) end
    end.

scope(Owner, Monitor, Owned) ->
    receive
        {own, Resource} -> scope(Owner, Monitor, [Resource | Owned]);
        {'ETS-TRANSFER', _, _, f23} -> scope(Owner, Monitor, Owned);
        {finish, Ref} ->
            cleanup(Owned), Owner ! {Ref, cleaned};
        {'DOWN', Monitor, process, Owner, _} -> cleanup(Owned)
    end.

cleanup(Owned) ->
    lists:foreach(fun
        ({server, Server}) -> stop(Server);
        ({directory, Path}) ->
            ok = file:del_dir_r(Path),
            {error, enoent} = file:read_link_info(Path)
    end, Owned).

start(Response, CloseAfter, Guard) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Table = ets:new(?MODULE, [public, {heir, Guard, f23}]),
    Counts = atomics:new(3, []),
    Acceptor = spawn(fun() -> accept(Listener, Response, CloseAfter, Table, Counts) end),
    Server = {Listener, Acceptor, Port, Table, Counts},
    Guard ! {own, {server, Server}},
    Server.

port({_, _, Port, _, _}) -> Port.
counts({_, _, _, _, C}) ->
    {atomics:get(C, 1), atomics:get(C, 2), atomics:get(C, 3)}.

accept(Listener, Response, CloseAfter, Table, Counts) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            atomics:add_get(Counts, 1, 1),
            Worker = spawn(fun() ->
                receive {serve, S} -> serve(S, Response, CloseAfter, Counts) end
            end),
            ets:insert(Table, {Worker}),
            ok = gen_tcp:controlling_process(Socket, Worker),
            Worker ! {serve, Socket},
            accept(Listener, Response, CloseAfter, Table, Counts);
        {error, closed} -> ok;
        {error, _} -> ok
    end.

serve(Socket, Response, CloseAfter, Counts) ->
    case read_request(Socket, <<>>) of
        ok ->
            atomics:add_get(Counts, 2, 1),
            ok = gen_tcp:send(Socket, Response),
            case CloseAfter of
                true -> ok;
                false -> await_eof(Socket, Counts)
            end;
        _ -> ok
    end,
    gen_tcp:close(Socket).

read_request(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Header, Body] ->
            {match, [Length]} = re:run(Header,
                <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>, [{capture, [1], binary}]),
            Remaining = binary_to_integer(Length) - byte_size(Body),
            case Remaining > 0 of
                true ->
                    case gen_tcp:recv(Socket, Remaining, 5000) of
                        {ok, _} -> ok;
                        Error -> Error
                    end;
                false -> ok
            end;
        [_] when byte_size(Acc) < 8388608 ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Bytes} -> read_request(Socket, <<Acc/binary, Bytes/binary>>);
                Error -> Error
            end;
        _ -> {error, limit}
    end.

await_eof(Socket, Counts) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {error, closed} -> atomics:add_get(Counts, 3, 1), ok;
        {ok, _} -> await_eof(Socket, Counts);
        _ -> ok %% A timeout is NOT recorded as peer EOF.
    end.

stop({Listener, Acceptor, _, Table, _}) ->
    gen_tcp:close(Listener),
    await_dead(Acceptor),
    %% Acceptor has stopped adding workers before cleanup enumerates them.
    lists:foreach(fun({Pid}) -> await_dead(Pid) end, ets:tab2list(Table)),
    true = ets:delete(Table).

await_dead(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(f23_worker_survived) end.
