-module(mimic_devin_f28_status_test_ffi).
-export([with_servers/4, with_script/4, port/1, counts/1, finally/2, await_pull/1]).

%% Synthetic numeric-loopback only. Inspection receives request bytes transiently.
%% Fixtures retain safe counters, never a transcript, authorization or body.
with_servers(Response, Hold, Inspect, Fun) ->
    with_script([{0, Response}], Hold, Inspect, Fun).

with_script(Packets, Hold, Inspect, Fun) ->
    Owner = self(),
    {Guard, Monitor} = spawn_monitor(fun() ->
        scope(Owner, erlang:monitor(process, Owner), [])
    end),
    Directory = filename:absname(filename:join(["build", "f28",
        "state-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))])),
    ok = filelib:ensure_dir(Directory),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Guard ! {own, {directory, Directory}},
    First = start(Packets, Hold, Inspect, Guard),
    Second = start([{0, <<"HTTP/1.1 503 Synthetic\r\nContent-Length: 0\r\n\r\n">>}],
        false, fun(_, _) -> false end, Guard),
    try Fun(list_to_binary(Directory), First, Second)
    after
        Ref = make_ref(),
        Guard ! {finish, Ref},
        receive {Ref, cleaned} -> ok after 4000 -> error(f28_cleanup_timeout) end,
        receive {'DOWN', Monitor, process, Guard, normal} -> ok
        after 1000 -> error(f28_scope_survived) end
    end.

finally(Fun, Cleanup) -> try Fun() after Cleanup() end.

scope(Owner, Monitor, Owned) ->
    receive
        {own, Resource} -> scope(Owner, Monitor, [Resource | Owned]);
        {'ETS-TRANSFER', _, _, f28} -> scope(Owner, Monitor, Owned);
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

start(Packets, Hold, Inspect, Guard) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Table = ets:new(?MODULE, [public, {heir, Guard, f28}]),
    Counts = atomics:new(4, []),
    Acceptor = spawn(fun() -> accept(Listener, Packets, Hold, Inspect, Table, Counts) end),
    Server = {Listener, Acceptor, Port, Table, Counts},
    Guard ! {own, {server, Server}},
    Server.

port({_, _, Port, _, _}) -> Port.
counts({_, _, _, _, C}) ->
    {atomics:get(C, 1), atomics:get(C, 2), atomics:get(C, 3), atomics:get(C, 4)}.

accept(Listener, Packets, Hold, Inspect, Table, Counts) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            atomics:add_get(Counts, 1, 1),
            %% Linking closes the spawn-to-registration cleanup race.
            Worker = spawn_link(fun() ->
                receive {serve, S} -> serve(S, Packets, Hold, Inspect, Counts) end
            end),
            ets:insert(Table, {Worker}),
            ok = gen_tcp:controlling_process(Socket, Worker),
            Worker ! {serve, Socket},
            accept(Listener, Packets, Hold, Inspect, Table, Counts);
        {error, _} -> ok
    end.

serve(Socket, Packets, Hold, Inspect, Counts) ->
    try
        case read_request(Socket, <<>>) of
            {ok, Header, Body} ->
                atomics:add_get(Counts, 2, 1),
                case Inspect(Header, Body) of
                    true -> atomics:add_get(Counts, 3, 1);
                    false -> ok
                end,
                send_packets(Socket, Packets),
                case Hold of
                    true ->
                        %% Only actual peer EOF is closure evidence.
                        case gen_tcp:recv(Socket, 0, 20000) of
                            {error, closed} -> atomics:add_get(Counts, 4, 1);
                            _ -> ok
                        end;
                    false -> ok
                end;
            _ -> ok
        end
    after gen_tcp:close(Socket) end.

send_packets(_, []) -> ok;
send_packets(Socket, [{Delay, Bytes} | Rest]) ->
    receive after Delay -> ok end,
    case gen_tcp:send(Socket, Bytes) of
        ok -> send_packets(Socket, Rest);
        {error, _} -> ok
    end.

read_request(Socket, Acc) when byte_size(Acc) =< 16384 ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Header, Body] ->
            case re:run(Header, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                    [{capture, [1], binary}]) of
                {match, [Length]} ->
                    Size = binary_to_integer(Length),
                    case Size > 0 andalso Size =< 8192 andalso byte_size(Body) =< Size of
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
                {ok, Chunk} -> read_request(Socket, <<Acc/binary, Chunk/binary>>);
                Error -> Error
            end
    end;
read_request(_, _) -> {error, limit}.

%% Prove the owner is actually inside a shared pending read, not just ready
%% to call finish. Only module/function atoms are inspected; no frame args.
await_pull(Pid) -> await_pull(Pid, erlang:monotonic_time(millisecond) + 1000).
await_pull(Pid, Until) ->
    Pending = case process_info(Pid, current_stacktrace) of
        {current_stacktrace, Frames = [
                {gleam_erlang_ffi, select, 2, _},
                {'mimic@providers@runtime', ask, 4, _} | _]} ->
            lists:any(fun
                ({'mimic@providers@runtime', read, _, _}) -> true;
                ({'mimic@providers@runtime', read_with_deadline, _, _}) -> true;
                ({'mimic@providers@runtime', Function, _, _}) ->
                    %% Gleam result.try tail-calls a generated continuation.
                    %% The selector frame above proves it is in a blocked read,
                    %% not just about to call finish or running another callback.
                    case atom_to_binary(Function, utf8) of
                        <<"-read_with_deadline/", _/binary>> -> true;
                        _ -> false
                    end;
                (_) -> false
            end, Frames);
        _ -> false
    end,
    case Pending of
        true -> true;
        false ->
            case erlang:monotonic_time(millisecond) < Until of
                true -> receive after 2 -> await_pull(Pid, Until) end;
                false -> false
            end
    end.

stop({Listener, Acceptor, _, Table, _}) ->
    gen_tcp:close(Listener),
    kill_and_wait(Acceptor),
    lists:foreach(fun({Worker}) -> kill_and_wait(Worker) end, ets:tab2list(Table)),
    ets:delete(Table),
    nil.

kill_and_wait(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 -> error(f28_worker_survived) end.
