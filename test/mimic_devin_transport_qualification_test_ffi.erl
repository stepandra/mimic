-module(mimic_devin_transport_qualification_test_ffi).
-export([tls_start/6, tls_port/1, tls_stats/1, tls_requests/1, tls_alpn/1,
         tls_stop/1, with_resources/1, directory/1, phase/2]).

%% One monitored cleanup guard per test, including EUnit timeout/owner exit.
%% It knows only paths and fixture handles created by THIS module.
with_resources(Fun) ->
    Owner = self(),
    {Guard, Monitor} = spawn_monitor(fun() ->
        resources(Owner, erlang:monitor(process, Owner), [])
    end),
    put(f22_guard, Guard),
    try Fun()
    after
        Ref = make_ref(),
        Guard ! {finish, Ref},
        receive {Ref, cleaned} -> ok after 2000 -> error(f22_cleanup_timeout) end,
        receive {'DOWN', Monitor, process, Guard, normal} -> ok
        after 1000 -> error(f22_cleanup_guard_survived) end,
        erase(f22_guard)
    end.

resources(Owner, Monitor, Owned) ->
    receive
        {add, Resource} -> resources(Owner, Monitor, [Resource | Owned]);
        {remove, Resource} -> resources(Owner, Monitor, lists:delete(Resource, Owned));
        {'ETS-TRANSFER', _, Owner, f22} -> resources(Owner, Monitor, Owned);
        {finish, Ref} ->
            cleanup_resources(Owned),
            Owner ! {Ref, cleaned};
        {'DOWN', Monitor, process, Owner, _} -> cleanup_resources(Owned)
    end.

cleanup_resources(Owned) ->
    %% Fixtures were added after their containing state/CA directories.
    lists:foreach(fun
        ({server, Server}) -> tls_stop(Server);
        ({directory, Path}) ->
            case file:read_link_info(Path) of
                {error, enoent} -> ok;
                {ok, _} -> ok = file:del_dir_r(Path)
            end,
            {error, enoent} = file:read_link_info(Path)
    end, Owned),
    phase(<<"cleanup resources=0">>, fun() -> nil end).

register(Resource) ->
    case get(f22_guard) of
        undefined -> error(f22_resource_scope_required);
        Guard -> Guard ! {add, Resource}
    end.

directory(Kind) when Kind =:= <<"state">>; Kind =:= <<"ca">> ->
    Path = filename:absname(filename:join(["build", "f22",
        binary_to_list(Kind) ++ "-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))])),
    ok = filelib:ensure_dir(Path),
    case Kind of
        <<"state">> ->
            ok = file:make_dir(Path),
            ok = file:change_mode(Path, 8#700);
        <<"ca">> -> ok  %% generate_ca requires an absent path.
    end,
    register({directory, Path}),
    list_to_binary(Path).

%% Opt-in, synthetic-only phase evidence. No path/token/body/exception logging.
phase(Name, Fun) ->
    Started = erlang:monotonic_time(millisecond),
    phase_log(Name, <<"start">>, 0),
    try Fun()
    after phase_log(Name, <<"end">>,
        erlang:monotonic_time(millisecond) - Started) end.

phase_log(Name, Boundary, Elapsed) ->
    case os:getenv("F22_PHASE_LOG") of
        false -> ok;
        File ->
            ok = file:write_file(File,
                io_lib:format("F22 phase=~s boundary=~s elapsed_ms=~B~n",
                    [Name, Boundary, Elapsed]), [append])
    end.

%% Synthetic loopback fixture only. Leaf generation reuses the existing
%% recorder primitive; the client under test is the real shared egress stack.
%% Only known synthetic request material is retained, in memory, until stop.
tls_start(Ca, CaKey, CertificateHost, Protocols, Response, CloseAfter) ->
    _ = ssl:start(),
    case mimic_recorder_tls_ffi:make_leaf(binary_to_list(Ca),
            binary_to_list(CaKey), binary_to_list(CertificateHost)) of
        {ok, Temp, Leaf, LeafKey} ->
            Alpn = case Protocols of
                [] -> [];
                _ -> [{alpn_preferred_protocols, Protocols}]
            end,
            case ssl:listen(0, [binary, {active, false}, {reuseaddr, true},
                    {ip, {127,0,0,1}}, {certfile, Leaf}, {keyfile, LeafKey}
                    | Alpn]) of
                {ok, Listener} ->
                    {ok, {_, Port}} = ssl:sockname(Listener),
                    Table = ets:new(?MODULE, [public, ordered_set,
                        {heir, get(f22_guard), f22}]),
                    %% TCP accepts, TLS successes, TLS failures, peer EOFs.
                    Counts = atomics:new(4, []),
                    Pid = spawn(fun() ->
                        accept(Listener, Response, CloseAfter, Table, Counts)
                    end),
                    Server = {Listener, Pid, Port, Table, Counts, Temp},
                    register({server, Server}),
                    {ok, Server};
                _ ->
                    mimic_recorder_tls_ffi:cleanup(Temp),
                    {error, <<"synthetic TLS listen failed">>}
            end;
        _ -> {error, <<"synthetic TLS leaf failed">>}
    end.

accept(Listener, Response, CloseAfter, Table, Counts) ->
    case ssl:transport_accept(Listener) of
        {ok, Socket} ->
            atomics:add_get(Counts, 1, 1),
            Pid = spawn(fun() ->
                receive ready ->
                    try serve(Socket, Response, CloseAfter, Table, Counts)
                    after ssl:close(Socket) end
                end
            end),
            ets:insert(Table, {{worker, Pid}, Pid}),
            ok = ssl:controlling_process(Socket, Pid),
            Pid ! ready,
            accept(Listener, Response, CloseAfter, Table, Counts);
        _ -> ok
    end.

serve(Transport, Response, CloseAfter, Table, Counts) ->
    case ssl:handshake(Transport, 5000) of
        {ok, Socket} ->
            atomics:add_get(Counts, 2, 1),
            Protocol = case ssl:negotiated_protocol(Socket) of
                {ok, Value} -> Value;
                {error, protocol_not_negotiated} -> <<"none">>
            end,
            ets:insert(Table, {{alpn, erlang:unique_integer([monotonic])}, Protocol}),
            case read_request(Socket, []) of
                {ok, Request} ->
                    ets:insert(Table, {{request, erlang:unique_integer([monotonic])}, Request}),
                    ok = ssl:send(Socket, Response),
                    case CloseAfter of
                        true -> ok;
                        false ->
                            %% Count actual client EOF, not fixture teardown or timeout.
                            case ssl:recv(Socket, 0, 10000) of
                                {error, closed} -> atomics:add_get(Counts, 4, 1);
                                _ -> ok
                            end
                    end;
                _ -> ok
            end;
        _ -> atomics:add_get(Counts, 3, 1)
    end.

read_request(Socket, Acc) ->
    ok = ssl:setopts(Socket, [{packet, line}, {packet_size, 8192}]),
    case ssl:recv(Socket, 0, 5000) of
        {ok, <<"\r\n">>} ->
            Header = iolist_to_binary(lists:reverse([<<"\r\n">> | Acc])),
            {match, [Value]} = re:run(Header, <<"Content-Length: ([0-9]+)">>,
                [{capture, [1], binary}]),
            Length = binary_to_integer(Value),
            true = Length > 0 andalso Length =< 8388608,
            ok = ssl:setopts(Socket, [{packet, raw}]),
            case ssl:recv(Socket, Length, 5000) of
                {ok, Body} -> {ok, {Header, Body}};
                Error -> Error
            end;
        {ok, Line} -> read_request(Socket, [Line | Acc]);
        Error -> Error
    end.

tls_port({_, _, Port, _, _, _}) -> Port.
tls_stats({_, _, _, _, Counts, _}) ->
    {atomics:get(Counts, 1), atomics:get(Counts, 2),
     atomics:get(Counts, 3), atomics:get(Counts, 4)}.
tls_requests({_, _, _, Table, _, _}) ->
    [Request || {{request, _}, Request} <- ets:tab2list(Table)].
tls_alpn({_, _, _, Table, _, _}) ->
    [Protocol || {{alpn, _}, Protocol} <- ets:tab2list(Table)].
tls_stop(Server = {Listener, Pid, _, Table, _, Temp}) ->
    %% Stop/await the acceptor BEFORE enumerating workers: no registration race.
    stop_process(Pid),
    _ = ssl:close(Listener),
    Workers = [Worker || {{worker, _}, Worker} <- ets:tab2list(Table)],
    lists:foreach(fun stop_process/1, Workers),
    false = lists:any(fun erlang:is_process_alive/1, [Pid | Workers]),
    ets:delete(Table),
    mimic_recorder_tls_ffi:cleanup(Temp),
    {error, enoent} = file:read_link_info(Temp),
    case get(f22_guard) of
        undefined -> ok;
        Guard -> Guard ! {remove, {server, Server}}
    end,
    phase(<<"tls-stop workers=0 leaf-removed">>, fun() -> nil end),
    nil.

stop_process(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok
    after 1000 -> error(f22_fixture_worker_survived) end.
