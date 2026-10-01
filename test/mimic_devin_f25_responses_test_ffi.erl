-module(mimic_devin_f25_responses_test_ffi).
-export([focused/0, with_servers/5, port/1, counts/1, finally/2]).

%% SYNTHETIC numeric-loopback only; no native SDK/CPA/live qualification.
focused() ->
    eunit:test([devin_responses_projection_test, devin_catalog_test,
        devin_chat_projection_test, devin_messages_projection_test,
        responses_tool_identity_test], [verbose, {scale_timeouts, 10}]) =:= ok.

finally(Fun, Cleanup) -> try Fun() after Cleanup() end.

with_servers(First, Second, Hold, Inspect, Fun) ->
    Owner = self(),
    {Guard, Monitor} = spawn_monitor(fun() ->
        scope(Owner, erlang:monitor(process, Owner), [])
    end),
    Directory = filename:absname(filename:join(["build", "f25",
        "state-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))])),
    ok = filelib:ensure_dir(Directory),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Guard ! {own, {directory, Directory}},
    One = start(First, Hold, Inspect, Guard),
    Two = start(Second, false, Inspect, Guard),
    try Fun(list_to_binary(Directory), One, Two)
    after
        Ref = make_ref(),
        Guard ! {finish, Ref},
        receive {Ref, cleaned} -> ok after 3000 -> error(f25_cleanup_timeout) end,
        receive {'DOWN', Monitor, process, Guard, normal} -> ok
        after 1000 -> error(f25_scope_survived) end
    end.

scope(Owner, Monitor, Owned) ->
    receive
        {own, Resource} -> scope(Owner, Monitor, [Resource | Owned]);
        {'ETS-TRANSFER', _, _, f25} -> scope(Owner, Monitor, Owned);
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

start(Response, Hold, Inspect, Guard) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Table = ets:new(?MODULE, [public, {heir, Guard, f25}]),
    Counts = atomics:new(4, []),
    Acceptor = spawn(fun() -> accept(Listener, Response, Hold, Inspect, Table, Counts) end),
    Server = {Listener, Acceptor, Port, Table, Counts},
    Guard ! {own, {server, Server}},
    Server.

port({_, _, Port, _, _}) -> Port.
counts({_, _, _, _, Counts}) ->
    {atomics:get(Counts, 1), atomics:get(Counts, 2),
        atomics:get(Counts, 3), atomics:get(Counts, 4)}.

accept(Listener, Response, Hold, Inspect, Table, Counts) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            atomics:add_get(Counts, 1, 1),
            Worker = spawn(fun() ->
                receive {serve, S} -> serve(S, Response, Hold, Inspect, Counts) end
            end),
            ets:insert(Table, {Worker}),
            ok = gen_tcp:controlling_process(Socket, Worker),
            Worker ! {serve, Socket},
            accept(Listener, Response, Hold, Inspect, Table, Counts);
        {error, _} -> ok
    end.

serve(Socket, Response, Hold, Inspect, Counts) ->
    try
        case read_request(Socket, <<>>) of
            {ok, Header, Body} ->
                atomics:add_get(Counts, 2, 1),
                %% Return/persist ONLY this boolean, never credential-bearing
                %% headers/body. Their temporary binaries die with the worker.
                case Inspect(Header, Body) of
                    true -> atomics:add_get(Counts, 3, 1);
                    false -> ok
                end,
                ok = gen_tcp:send(Socket, Response),
                case Hold of true -> await_eof(Socket, Counts); false -> ok end;
            _ -> ok
        end
    after gen_tcp:close(Socket) end.

read_request(Socket, Acc) when byte_size(Acc) =< 65536 ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Header, Body] ->
            case re:run(Header, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                    [{capture, [1], binary}]) of
                {match, [Length]} ->
                    Size = binary_to_integer(Length),
                    case Size =< 65536 andalso byte_size(Body) =< Size of
                        true when byte_size(Body) =:= Size ->
                            {ok, Header, Body};
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

await_eof(Socket, Counts) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {error, closed} -> atomics:add_get(Counts, 4, 1), ok;
        {ok, _} -> await_eof(Socket, Counts);
        _ -> ok %% Never count a timeout/fixture teardown as peer EOF.
    end.

stop({Listener, Acceptor, _, Table, _}) ->
    gen_tcp:close(Listener),
    await_dead(Acceptor),
    lists:foreach(fun({Pid}) -> await_dead(Pid) end, ets:tab2list(Table)),
    true = ets:delete(Table).

await_dead(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(f25_worker_survived) end.
