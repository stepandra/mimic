-module(mimic_provider_runtime_test_ffi).
-export([tls_start/3, tls_port/1, tls_requests/1, tls_closed/1, tls_stop/1,
         second_vm_rejected/1, stale_guard/1, chmod/2, persistence_phase/2,
         killed_mutator_cleanup/1, session_phase/2, unsafe_string/1,
         capture_logs/1, log/2]).

%% Test-only synthetic loopback socket fixture. No provider endpoints/accounts.
tls_start(Cert, Key, Response) ->
    _ = ssl:start(),
    case mimic_recorder_tls_ffi:make_leaf(binary_to_list(Cert), binary_to_list(Key), "127.0.0.1") of
        {ok, Temp, Leaf, LeafKey} ->
            case ssl:listen(0, [binary, {active, false}, {reuseaddr, true},
                    {ip, {127,0,0,1}}, {certfile, Leaf}, {keyfile, LeafKey},
                    {alpn_preferred_protocols, [<<"http/1.1">>]}]) of
                {ok, Listener} ->
                    {ok, {_, Port}} = ssl:sockname(Listener),
                    Table = ets:new(?MODULE, [public, ordered_set]),
                    Closed = atomics:new(1, []),
                    Pid = spawn(fun() -> accept(Listener, Response, Table, Closed) end),
                    {ok, {Listener, Pid, Port, Table, Closed, Temp}};
                _ -> mimic_recorder_tls_ffi:cleanup(Temp), {error, <<"TLS listen failed">>}
            end;
        _ -> {error, <<"TLS fixture leaf failed">>}
    end.

accept(Listener, Response, Table, Closed) ->
    case ssl:transport_accept(Listener) of
        {ok, Socket} ->
            Pid = spawn(fun() ->
                receive ready ->
                    try serve(Socket, Response, Table)
                    after ssl:close(Socket), atomics:add_get(Closed, 1, 1) end
                end
            end),
            ets:insert(Table, {{worker, Pid}, Pid}),
            ok = ssl:controlling_process(Socket, Pid),
            Pid ! ready,
            accept(Listener, Response, Table, Closed);
        _ -> ok
    end.

serve(Transport, Response, Table) ->
    case ssl:handshake(Transport, 5000) of
        {ok, Socket} ->
            case read_request(Socket, []) of
                {ok, Request} ->
                    ets:insert(Table, {{request, erlang:unique_integer([monotonic])}, Request}),
                    ssl:send(Socket, Response),
                    %% Closing or cancelling must produce EOF, not another request.
                    case binary:match(Response, <<"Connection: close">>) of
                        nomatch -> ssl:recv(Socket, 0, 10000);
                        _ -> ok
                    end;
                _ -> ok
            end;
        _ -> ok
    end.

read_request(Socket, Acc) ->
    ok = ssl:setopts(Socket, [{packet, line}]),
    case ssl:recv(Socket, 0, 5000) of
        {ok, <<"\r\n">>} ->
            Headers = iolist_to_binary(lists:reverse([<<"\r\n">> | Acc])),
            Length = case re:run(Headers, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                                 [{capture, [1], binary}]) of
                {match, [Value]} -> binary_to_integer(Value);
                _ -> 0
            end,
            ok = ssl:setopts(Socket, [{packet, raw}]),
            case Length of
                0 -> {ok, Headers};
                _ -> case ssl:recv(Socket, Length, 5000) of
                    {ok, Body} -> {ok, <<Headers/binary, Body/binary>>};
                    Error -> Error
                end
            end;
        {ok, Line} -> read_request(Socket, [Line | Acc]);
        Error -> Error
    end.

tls_port({_, _, Port, _, _, _}) -> Port.
tls_requests({_, _, _, Table, _, _}) ->
    [Raw || {{request, _}, Raw} <- ets:tab2list(Table)].
tls_closed({_, _, _, _, Closed, _}) -> atomics:get(Closed, 1).
tls_stop({Listener, Pid, _, Table, _, Temp}) ->
    ssl:close(Listener),
    exit(Pid, kill),
    [exit(Worker, kill) || {{worker, _}, Worker} <- ets:tab2list(Table)],
    ets:delete(Table),
    mimic_recorder_tls_ffi:cleanup(Temp),
    nil.

%% A real second BEAM VM, not another actor in the current runtime.
second_vm_rejected(Directory) ->
    Erl = os:find_executable("erl"),
    Ebin = filename:dirname(code:which(mimic_provider_runtime_ffi)),
    Code = "case mimic_provider_runtime_ffi:claim_store(list_to_binary(hd(init:get_plain_arguments()))) of "
           "{error,_}->halt(0);{ok,P}->mimic_provider_runtime_ffi:release_store(P),halt(1) end.",
    Port = open_port({spawn_executable, Erl}, [binary, exit_status, use_stdio, stderr_to_stdout,
        {args, ["+S", "1", "-noshell", "-pa", filename:absname(Ebin),
                "-eval", Code, "-extra", binary_to_list(Directory)]}]),
    wait_exit(Port).

wait_exit(Port) ->
    receive
        {Port, {data, _}} -> wait_exit(Port);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, _}} -> false
    after 10000 -> port_close(Port), false
    end.

stale_guard(Directory) ->
    Lock = filename:join(Directory, <<".provider-runtime-owner">>),
    ok = file:make_dir(Lock),
    ok = file:write_file(filename:join(Lock, <<"nonce">>), <<"synthetic-stale-owner">>),
    nil.

chmod(Directory, Mode) ->
    ok = file:change_mode(Directory, Mode), nil.

persistence_phase(Directory, Restart) ->
    run_phase(Directory, Restart, "provider_runtime_test:persistence_phase").

session_phase(Directory, Restart) ->
    run_phase(Directory, Restart, "provider_runtime_v3_test:session_phase").

run_phase(Directory, Restart, Function) ->
    Erl = os:find_executable("erl"),
    Paths = [filename:absname(P) || P <- code:get_path()],
    Code = Function ++ "(list_to_binary(hd(init:get_plain_arguments())),"
           ++ atom_to_list(Restart) ++ "),halt(0).",
    Port = open_port({spawn_executable, Erl}, [binary, exit_status, use_stdio, stderr_to_stdout,
        {args, ["+S", "1", "-noshell", "-pa"] ++ Paths ++
                ["-eval", Code, "-extra", binary_to_list(Directory)]}]),
    wait_exit(Port).

%% Test-only injection of invalid UTF-8 across an FFI String boundary.
unsafe_string(Bytes) -> Bytes.

%% Test-only logger sink. Raw events never leave this process; tests assert that
%% their deliberately synthetic token/body marker is absent from diagnostics.
capture_logs(Fun) ->
    Ref = make_ref(),
    ok = logger:add_handler(mimic_runtime_test_sink, ?MODULE,
        #{level => all, config => #{owner => self(), ref => Ref}}),
    try
        logger:notice("runtime-v3-log-sink-ready"),
        Value = Fun(),
        ok = logger:remove_handler(mimic_runtime_test_sink),
        {Value, collect_logs(Ref, [])}
    after logger:remove_handler(mimic_runtime_test_sink) end.

log(Event, #{config := #{owner := Owner, ref := Ref}}) ->
    Owner ! {Ref, unicode:characters_to_binary(logger_formatter:format(Event, #{}))},
    ok.

collect_logs(Ref, Acc) ->
    receive {Ref, Message} -> collect_logs(Ref, [Message | Acc])
    after 20 -> lists:reverse(Acc) end.

%% Kill the public primitive's caller while its filesystem critical section is
%% active, as runtime shutdown kills an auth worker waiting for persistence.
%% Large synthetic bytes widen the observation window; this tests a filesystem
%% primitive, not acceptance of oversized runtime credential records.
killed_mutator_cleanup(Directory) ->
    Name = <<"runtime-cancellation-fixture.json">>,
    Lock = filename:join(Directory, <<".mutation-", Name/binary>>),
    Data = binary:copy(<<"synthetic">>, 2 * 1024 * 1024),
    {Caller, Monitor} = spawn_monitor(fun() ->
        mimic_provider_runtime_ffi:mutate_runtime(Directory, Name, none, {some, Data})
    end),
    case await_lock(Lock, Caller, 1000) of
        true ->
            exit(Caller, kill),
            receive {'DOWN', Monitor, process, Caller, _} -> ok after 1000 -> error(caller_not_stopped) end,
            await_mutation(Directory, Name, 1000);
        false ->
            erlang:demonitor(Monitor, [flush]),
            false
    end.

await_lock(_Lock, _Caller, 0) -> false;
await_lock(Lock, Caller, Remaining) ->
    case {file:read_link_info(Lock), is_process_alive(Caller)} of
        {{ok, _}, true} -> true;
        {_, false} -> false;
        _ -> timer:sleep(1), await_lock(Lock, Caller, Remaining - 1)
    end.

await_mutation(_Directory, _Name, 0) -> false;
await_mutation(Directory, Name, Remaining) ->
    case mimic_provider_runtime_ffi:mutate_runtime(Directory, Name, none, {some, <<"after">>}) of
        {ok, nil} -> mimic_auth_ffi:secure_read(Directory, Name) =:= {ok, <<"after">>};
        _ -> timer:sleep(1), await_mutation(Directory, Name, Remaining - 1)
    end.
