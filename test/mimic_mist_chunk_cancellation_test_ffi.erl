%% Synthetic loopback sockets and bounded barriers only. Lifecycle/runtime
%% assertions live in Gleam. No credential values or request bytes are retained.
-module(mimic_mist_chunk_cancellation_test_ffi).
-export([run/0, run_headers/0, with_fixture/2, port/1, directory/1, release/1,
         await_peer_eof/2, requests/1, with_cleanup/2, stop_server/1,
         with_client/5, first/1, headers/1, close_client/1, reset_client/1,
         half_close/1, send_tail/2, read_all/1,
         tail_unchanged/3, connection_abi/1, socket_owner/2, await/2,
         raw_exchange/2, configure_pressure/2, pressure_deadline/1,
         remaining_ms/1, pressure_pause/1, pressure_sample/7,
         report_pressure_probe/7]).

run() ->
    run_module(mist_chunk_cancellation_test, 20),
    run_module(mist_content_type_boundary_test, 1),
    run_module(f44_http_boundary_test, 20),
    halt(0).

run_headers() ->
    run_module(mist_content_type_boundary_test, 1),
    halt(0).

run_module(Module, Scale) ->
    Tests = lists:sort([Name || {Name, 0} <- Module:module_info(exports),
                               lists:suffix("_test", atom_to_list(Name))]),
    io:format("MODULE ~p (~p tests)~n", [Module, length(Tests)]),
    lists:foreach(fun(Name) ->
        io:format("CASE ~p:~p~n", [Module, Name]),
        case eunit:test(fun() -> Module:Name() end,
                        [verbose, {scale_timeouts, Scale}]) of
            ok -> ok;
            _ -> halt(1)
        end
    end, Tests).

with_cleanup(Work, Cleanup) ->
    try Work() after Cleanup() end.

with_fixture(Mode, Work) ->
    {ok, Cwd} = file:get_cwd(),
    Dir = filename:join([Cwd, "build", "integration",
                        "mist-cancel-" ++ integer_to_list(
                            erlang:unique_integer([positive, monotonic]))]),
    ok = filelib:ensure_dir(filename:join(Dir, "unused")),
    StateDir = filename:join(Dir, "state"),
    ok = file:make_dir(StateDir),
    ok = file:change_mode(StateDir, 8#700),
    Table = ets:new(mimic_mist_cancel_fixture, [set, public]),
    ets:insert(Table, [{peer_eof, false}, {requests, 0}]),
    Owner = self(),
    Ready = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        peer(Owner, Ready, Table, Mode)
    end),
    try
        receive
            {Ready, Port} -> Work({Pid, Port, Table, unicode:characters_to_binary(Dir)});
            {'DOWN', Monitor, process, Pid, _} -> error(fixture_start_failed)
        after 2000 -> error(fixture_start_timeout)
        end
    after
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 1000 -> error(fixture_cleanup_timeout)
        end,
        demonitor(Monitor, [flush]),
        ets:delete(Table),
        remove_directory(Dir)
    end.

port({_, Port, _, _}) -> Port.
directory({_, _, _, Dir}) -> Dir.
release({Pid, _, _, _}) -> Pid ! advance, nil.
requests({_, _, Table, _}) -> ets:lookup_element(Table, requests, 2).

await_peer_eof({_, _, Table, _}, Timeout) ->
    await(fun() -> ets:lookup_element(Table, peer_eof, 2) end, Timeout).

await(Check, Timeout) ->
    Until = erlang:monotonic_time(millisecond) + Timeout,
    await_until(Check, Until).

await_until(Check, Until) ->
    case Check() of
        true -> true;
        false ->
            case erlang:monotonic_time(millisecond) >= Until of
                true -> false;
                false -> timer:sleep(5), await_until(Check, Until)
            end
    end.

peer(Owner, Ready, Table, Mode) ->
    Parent = monitor(process, Owner),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
                                     {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Owner ! {Ready, Port},
    try
        {ok, Socket} = gen_tcp:accept(Listen, 5000),
        try
            receive_request(Socket, <<>>),
            ets:update_counter(Table, requests, 1),
            ok = gen_tcp:send(Socket,
                <<"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                  "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n">>),
            ok = gen_tcp:send(Socket, chunk(prefix())),
            ok = inet:setopts(Socket, [{active, once}]),
            peer_wait(Socket, Table, Mode, Parent)
        after gen_tcp:close(Socket) end
    after gen_tcp:close(Listen) end.

peer_wait(Socket, Table, Mode, Parent) ->
    receive
        {tcp_closed, Socket} ->
            ets:insert(Table, {peer_eof, true});
        {tcp_error, Socket, _} ->
            %% Do not relabel reset/timeout as the requested measured peer EOF.
            ets:insert(Table, {peer_reset, true});
        {tcp, Socket, _} ->
            error(unexpected_second_upstream_request);
        {'DOWN', Parent, process, _, _} -> ok;
        advance ->
            case Mode of
                <<"normal">> ->
                    ok = gen_tcp:send(Socket, [
                        chunk(<<"data: synthetic second\n\n">>),
                        chunk(<<"data: synthetic third\n\n">>), <<"0\r\n\r\n">>]);
                <<"error">> ->
                    ok = gen_tcp:send(Socket, <<"invalid chunk size\r\n">>);
                _ -> ok
            end,
            peer_wait(Socket, Table, <<"idle">>, Parent)
    after 20_000 ->
        %% Never mark timeout-driven closure as a successful cancellation.
        error(fixture_idle_timeout)
    end.

prefix() -> <<"data: {\"type\":\"synthetic.metadata\"}\n\n">>.
chunk(Bytes) -> [integer_to_binary(byte_size(Bytes), 16), <<"\r\n">>,
                 Bytes, <<"\r\n">>].

receive_request(Socket, Bytes) when byte_size(Bytes) =< 1_048_576 ->
    case binary:match(Bytes, <<"\r\n\r\n">>) of
        {Offset, 4} ->
            HeaderBytes = Offset + 4,
            Head = binary:part(Bytes, 0, HeaderBytes),
            {match, [Length]} = re:run(Head,
                <<"\\r\\ncontent-length:[\\t ]*([0-9]+)\\r\\n">>,
                [caseless, {capture, [1], binary}]),
            Total = HeaderBytes + binary_to_integer(Length),
            receive_request_body(Socket, Bytes, Total);
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 2000),
            receive_request(Socket, <<Bytes/binary, Data/binary>>)
    end;
receive_request(_, _) -> error(fixture_request_limit).

receive_request_body(_, Bytes, Total) when byte_size(Bytes) >= Total -> ok;
receive_request_body(Socket, Bytes, Total) when Total =< 1_048_576 ->
    {ok, Data} = gen_tcp:recv(Socket, Total - byte_size(Bytes), 2000),
    receive_request_body(Socket, <<Bytes/binary, Data/binary>>, Total);
receive_request_body(_, _, _) -> error(fixture_request_limit).

stop_server(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> nil
    after 2000 -> error(server_cleanup_timeout)
    end.

with_client(Port, Request, Tls, ReadPrefix, Work) ->
    {Transport, Socket} = case Tls of
        true ->
            {ok, Ssl} = ssl:connect({127,0,0,1}, Port,
                [binary, {active, false}, {verify, verify_none}], 2000),
            {ssl, Ssl};
        false ->
            {ok, Tcp} = gen_tcp:connect({127,0,0,1}, Port,
                [binary, {active, false}, {recbuf, 4096}], 2000),
            {tcp, Tcp}
    end,
    try
        ok = send(Transport, Socket, Request),
        {ok, Head, Rest} = read_head(Transport, Socket, <<>>),
        {Prefix, Pending} = case ReadPrefix of
            true ->
                {chunk, Bytes, After} = read_chunk(Transport, Socket, Rest),
                {Bytes, After};
            false -> {<<>>, Rest}
        end,
        %% Private, explicit client state. Only read_all can consume this
        %% capability after prefix parsing; sealing it forbids that entry.
        PrefixTime = case ReadPrefix of
            true -> monotonic_ms();
            false -> undefined
        end,
        Phase = ets:new(mimic_mist_client_phase, [set, private]),
        ets:insert(Phase, [{sealed, false}, {read_all_calls, 0},
                           {prefix_ms, PrefixTime}, {client_socket, Socket},
                           {recbuf_set_attempted, false}]),
        try Work({Transport, Socket, Pending, Head, Prefix, Phase})
        after ets:delete(Phase) end
    after close(Transport, Socket) end.

first({_, _, _, _, First, _}) -> First.
headers({_, _, _, Headers, _, _}) -> Headers.
close_client({Transport, Socket, _, _, _, _}) -> close(Transport, Socket), nil.
reset_client({tcp, Socket, _, _, _, _}) ->
    inet:setopts(Socket, [{linger, {true, 0}}]),
    gen_tcp:close(Socket),
    nil.
half_close({tcp, Socket, _, _, _, _}) ->
    ok = gen_tcp:shutdown(Socket, write), nil.
send_tail({Transport, Socket, _, _, _, _}, Bytes) ->
    ok = send(Transport, Socket, Bytes), nil.

read_all({Transport, Socket, Pending, _, First, Phase}) ->
    case ets:lookup_element(Phase, sealed, 2) of
        true -> error(client_read_after_pressure_seal);
        false -> ok
    end,
    ets:update_counter(Phase, read_all_calls, 1),
    read_chunks(Transport, Socket, Pending, First).

read_chunks(Transport, Socket, Pending, Acc) ->
    case read_chunk(Transport, Socket, Pending) of
        {chunk, Bytes, Rest} ->
            read_chunks(Transport, Socket, Rest, <<Acc/binary, Bytes/binary>>);
        {done, <<>>} ->
            %% Extra terminal chunks or reordered bytes may not be swallowed.
            {error, closed} = recv(Transport, Socket, 0, 1000),
            {Acc, true};
        closed -> {Acc, false}
    end.

read_head(Transport, Socket, Bytes) when byte_size(Bytes) =< 16_384 ->
    case binary:match(Bytes, <<"\r\n\r\n">>) of
        {Offset, 4} ->
            Size = Offset + 4,
            <<Head:Size/binary, Rest/binary>> = Bytes,
            {ok, Head, Rest};
        nomatch ->
            {ok, Data} = recv(Transport, Socket, 0, 2000),
            read_head(Transport, Socket, <<Bytes/binary, Data/binary>>)
    end;
read_head(_, _, _) -> error(client_head_limit).

read_chunk(Transport, Socket, Pending) ->
    case line(Transport, Socket, Pending) of
        closed -> closed;
        {SizeText, Rest} ->
            Size = binary_to_integer(SizeText, 16),
            case take(Transport, Socket, Rest, Size + 2) of
                closed -> closed;
                {<<Data:Size/binary, "\r\n">>, After} ->
                    case Size of
                        0 -> {done, After};
                        _ -> {chunk, Data, After}
                    end
            end
    end.

line(Transport, Socket, Pending) when byte_size(Pending) =< 1_048_576 ->
    case binary:match(Pending, <<"\r\n">>) of
        {Size, 2} ->
            <<Line:Size/binary, "\r\n", Rest/binary>> = Pending,
            {Line, Rest};
        nomatch ->
            case recv(Transport, Socket, 0, 2000) of
                {ok, Bytes} -> line(Transport, Socket, <<Pending/binary, Bytes/binary>>);
                {error, closed} -> closed;
                {error, econnreset} -> closed;
                _ -> error(client_read_timeout)
            end
    end;
line(_, _, _) -> error(client_line_limit).

take(_, _, Pending, Size) when byte_size(Pending) >= Size ->
    <<Bytes:Size/binary, Rest/binary>> = Pending,
    {Bytes, Rest};
take(Transport, Socket, Pending, Size) when Size =< 16_777_218 ->
    case recv(Transport, Socket, Size - byte_size(Pending), 2000) of
        {ok, Bytes} -> take(Transport, Socket, <<Pending/binary, Bytes/binary>>, Size);
        {error, closed} -> closed;
        {error, econnreset} -> closed;
        _ -> error(client_read_timeout)
    end;
take(_, _, _, _) -> error(client_chunk_limit).

send(tcp, Socket, Bytes) -> gen_tcp:send(Socket, Bytes);
send(ssl, Socket, Bytes) -> ssl:send(Socket, Bytes).
recv(tcp, Socket, Size, Timeout) -> gen_tcp:recv(Socket, Size, Timeout);
recv(ssl, Socket, Size, Timeout) -> ssl:recv(Socket, Size, Timeout).
close(tcp, Socket) -> gen_tcp:close(Socket);
close(ssl, Socket) -> ssl:close(Socket).

raw_exchange(Port, Parts) ->
    case gen_tcp:connect({127,0,0,1}, Port,
                        [binary, {active, false}], 1000) of
        {ok, Socket} ->
            try
                lists:foreach(fun(Part) ->
                    ok = gen_tcp:send(Socket, Part),
                    timer:sleep(5)
                end, Parts),
                raw_receive(Socket, <<>>)
            after gen_tcp:close(Socket) end;
        _ -> {error, <<"raw client connect failed">>}
    end.

raw_receive(Socket, Acc) when byte_size(Acc) =< 1_048_576 ->
    case gen_tcp:recv(Socket, 0, 1000) of
        {ok, Bytes} -> raw_receive(Socket, <<Acc/binary, Bytes/binary>>);
        {error, closed} -> {ok, Acc};
        {error, econnreset} -> {ok, Acc};
        _ -> {error, <<"raw client read timeout">>}
    end;
raw_receive(_, _) -> {error, <<"raw client response limit">>}.

monotonic_ms() -> erlang:monotonic_time(millisecond).

pressure_deadline({tcp, _, _, _, _, Phase}) ->
    case ets:lookup_element(Phase, prefix_ms, 2) of
        Time when is_integer(Time) -> Time + 1000;
        _ -> error(pressure_requires_parsed_prefix)
    end.

remaining_ms(Deadline) -> max(0, Deadline - monotonic_ms()).

pressure_pause(Deadline) ->
    case remaining_ms(Deadline) of
        0 -> nil;
        Remaining -> timer:sleep(min(5, Remaining)), nil
    end.

configure_pressure(Socket, Client = {tcp, ClientSocket, Pending, _, _, Phase})
        when is_port(Socket), is_port(ClientSocket) ->
    case remaining_ms(pressure_deadline(Client)) of
        0 -> {error, <<"shared pressure deadline expired before setup">>};
        _ -> configure_pressure_options(Socket, ClientSocket, Pending, Phase, Client)
    end;
configure_pressure(_, _) ->
    {error, <<"pressure requires the existing TCP port backend">>}.

configure_pressure_options(Socket, ClientSocket, Pending, Phase, Client) ->
    case configure_pressure_peer(Client) of
        {error, _} = Error -> Error;
        {ok, _} = ClientOptions ->
            configure_pressure_server(Socket, ClientSocket, Pending, Phase,
                Client, ClientOptions)
    end.

configure_pressure_peer(Client = {tcp, ClientSocket, Pending, _, _, Phase}) ->
    Requested = [{recbuf, 4096}],
    Before = inet:getopts(ClientSocket, [recbuf, active]),
    OwnerBefore = erlang:port_info(ClientSocket, connected),
    Ready = ets:info(Phase, owner) =:= self()
        andalso OwnerBefore =:= {connected, self()}
        andalso ets:lookup_element(Phase, client_socket, 2) =:= ClientSocket
        andalso ets:lookup_element(Phase, sealed, 2) =:= false
        andalso ets:lookup_element(Phase, recbuf_set_attempted, 2) =:= false
        andalso ets:lookup_element(Phase, read_all_calls, 2) =:= 0
        andalso is_integer(ets:lookup_element(Phase, prefix_ms, 2))
        andalso byte_size(Pending) =:= 0
        andalso remaining_ms(pressure_deadline(Client)) > 0
        andalso case Before of
            {ok, Options} -> proplists:get_value(active, Options) =:= false;
            _ -> false
        end,
    case Ready of
        false ->
            io:format("MIST_PRESSURE_CLIENT_SETUP ~p~n", [#{
                client_socket => ClientSocket, current_owner => self(),
                socket_owner_before => OwnerBefore, requested => Requested,
                before => Before, set => not_attempted, 'after' => not_observed
            }]),
            {error, <<"pressure client identity/passive phase unsupported">>};
        true ->
            %% This is the one post-prefix setup, not a repeated clamp. Seal
            %% reads and consume the attempt before the public setter.
            ets:insert(Phase, [{sealed, true}, {recbuf_set_attempted, true}]),
            Set = inet:setopts(ClientSocket, Requested),
            After = inet:getopts(ClientSocket, [recbuf, active]),
            OwnerAfter = erlang:port_info(ClientSocket, connected),
            io:format("MIST_PRESSURE_CLIENT_SETUP ~p~n", [#{
                client_socket => ClientSocket, current_owner => self(),
                socket_owner_before => OwnerBefore, socket_owner_after => OwnerAfter,
                requested => Requested, before => Before, set => Set, 'after' => After,
                peer_reads_sealed => true, read_all_calls_after_prefix => 0
            }]),
            case {Set, After} of
                {ok, {ok, Peer}} ->
                    case bounded_buffer(proplists:get_value(recbuf, Peer))
                        andalso proplists:get_value(active, Peer) =:= false
                        andalso OwnerAfter =:= {connected, self()}
                        andalso remaining_ms(pressure_deadline(Client)) > 0 of
                        true -> After;
                        false -> {error, <<"pressure client readback unsupported">>}
                    end;
                _ -> {error, <<"pressure client recbuf setup unsupported">>}
            end
    end.

configure_pressure_server(Socket, ClientSocket, Pending, Phase, Client, ClientOptions) ->
    Requested = [{sndbuf, 4096}, {high_watermark, 4096}, {low_watermark, 1024}],
    Preserved = [active, exit_on_close, send_timeout],
    Before = inet:getopts(Socket, Preserved),
    Set = inet:setopts(Socket, Requested),
    ServerOptions = inet:getopts(Socket,
        [sndbuf, high_watermark, low_watermark | Preserved]),
    io:format("MIST_PRESSURE_SETTINGS ~p~n", [#{
        requested => Requested, server_readback => ServerOptions,
        client_readback => ClientOptions, unchanged_options_before => Before
    }]),
    Valid = case {Set, Before, ServerOptions, ClientOptions} of
        {ok, {ok, Old}, {ok, Server}, {ok, Peer}} ->
            pressure_setup_options_valid(Server, Peer)
            andalso lists:all(fun(Name) ->
                proplists:get_value(Name, Old) =:=
                    proplists:get_value(Name, Server)
            end, Preserved)
            andalso byte_size(Pending) =:= 0
            andalso remaining_ms(pressure_deadline(Client)) > 0
            andalso ets:lookup_element(Phase, read_all_calls, 2) =:= 0
            andalso erlang:port_info(ClientSocket, connected) =:= {connected, self()};
        _ -> false
    end,
    case Valid of
        true ->
            ets:insert(Phase, [{sealed, true}, {configured_socket, Socket}]),
            {ok, nil};
        false -> {error, <<"pressure socket settings/read phase unsupported">>}
    end.

pressure_setup_options_valid(Server, Peer) ->
    bounded_buffer(proplists:get_value(recbuf, Peer))
    andalso pressure_inflight_options_valid(Server, Peer).

pressure_inflight_options_valid(Server, Peer) ->
    %% The client recbuf bound induces pressure at setup; its later numeric
    %% readback is diagnostic, not a promise of a stable OS buffer size.
    %% Admission still requires the exact sustained send path below.
    bounded_buffer(proplists:get_value(sndbuf, Server))
    andalso proplists:get_value(high_watermark, Server) =:= 4096
    andalso proplists:get_value(low_watermark, Server) =:= 1024
    andalso proplists:get_value(active, Peer) =:= false.

bounded_buffer(Value) -> is_integer(Value) andalso Value > 0 andalso Value =< 65536.

%% Keep only integer-arity MFAs. Never retain arguments, locations, mailbox
%% contents, request bytes or credentials from process introspection.
safe_mfa({Module, Function, Arity})
        when is_atom(Module), is_atom(Function), is_integer(Arity) ->
    {Module, Function, Arity};
safe_mfa({Module, Function, Arity, _})
        when is_atom(Module), is_atom(Function), is_integer(Arity) ->
    {Module, Function, Arity};
safe_mfa(_) -> unobservable.

safe_stack(Stack) when is_list(Stack) ->
    [Mfa || Frame <- Stack, Mfa <- [safe_mfa(Frame)], Mfa =/= unobservable];
safe_stack(_) -> [].

send_path(Stack) ->
    %% The recorded Gleam 1.18.1 output keeps mist:send_chunk/2 because it
    %% replaces the error AFTER transport.send. glisten_tcp_ffi:send/2 also
    %% keeps a frame to translate ok -> {ok,nil}. transport.send and gen_tcp
    %% wrappers may tail-call: those optional frames are NOT required.
    %% pressure_send/4 emits WriteReturned AFTER the call, pinning its exact
    %% callsite. If these retained frames become unobservable, fail closed.
    %% Installed OTP 29.0.4 tail-calls send/3 into private prim_inet:send/4,
    %% which owns port_command/3 and the synchronous driver-reply wait.
    lists:member({mist_chunk_cancellation_test, pressure_send, 4}, Stack)
    andalso lists:member({mist, send_chunk, 2}, Stack)
    andalso lists:member({glisten_tcp_ffi, send, 2}, Stack)
    andalso lists:any(fun
        ({erlang, port_command, Arity}) -> Arity =:= 2 orelse Arity =:= 3;
        ({prim_inet, send, Arity}) ->
            Arity =:= 2 orelse Arity =:= 3 orelse Arity =:= 4;
        ({prim_inet, send_recv_reply, Arity}) -> Arity =:= 2 orelse Arity =:= 3;
        (_) -> false
    end, Stack).

pressure_snapshot(Socket, Writer, Executor, Coordinator,
                  Client = {tcp, ClientSocket, Pending, _, _, Phase},
                  Deadline, Index) ->
    Info = case process_info(Executor,
        [status, current_function, current_stacktrace, message_queue_len]) of
        undefined -> [];
        Values -> Values
    end,
    Stack = safe_stack(proplists:get_value(current_stacktrace, Info, [])),
    Status = proplists:get_value(status, Info, ended),
    ServerOptions = inet:getopts(Socket, [sndbuf, high_watermark, low_watermark]),
    ClientOptions = inet:getopts(ClientSocket, [recbuf, active]),
    Sealed = ets:lookup_element(Phase, sealed, 2)
        andalso ets:lookup_element(Phase, read_all_calls, 2) =:= 0
        andalso ets:lookup_element(Phase, configured_socket, 2) =:= Socket
        andalso ets:lookup_element(Phase, client_socket, 2) =:= ClientSocket
        andalso ets:lookup_element(Phase, recbuf_set_attempted, 2)
        andalso erlang:port_info(ClientSocket, connected) =:= {connected, self()}
        andalso byte_size(Pending) =:= 0,
    OptionsValid = case {ServerOptions, ClientOptions} of
        {{ok, Server}, {ok, Peer}} -> pressure_inflight_options_valid(Server, Peer);
        _ -> false
    end,
    Owned = erlang:port_info(Socket, connected) =:= {connected, Coordinator},
    Alive = is_process_alive(Executor),
    Path = send_path(Stack),
    InTime = Deadline =:= pressure_deadline(Client)
        andalso remaining_ms(Deadline) > 0,
    Blocked = Writer =:= Executor andalso Alive andalso Owned andalso Sealed
        andalso OptionsValid andalso InTime andalso Index >= 1 andalso Index =< 8
        andalso (Status =:= waiting orelse Status =:= suspended) andalso Path,
    #{stage => before_client_reset, blocked_send_path => Blocked,
      pressure_index => Index, writer => Writer, executor => Executor,
      coordinator => Coordinator, executor_alive => Alive, status => Status,
      current_function => safe_mfa(proplists:get_value(current_function, Info)),
      send_path_mfas => Stack, send_path_observable => Path,
      executor_message_queue_len => proplists:get_value(message_queue_len, Info),
      downstream_server_socket => Socket, downstream_client_socket => ClientSocket,
      socket_owner_is_coordinator => Owned, peer_reads_sealed => Sealed,
      read_all_calls_after_prefix => ets:lookup_element(Phase, read_all_calls, 2),
      client_read_category => first_chunk_parsed,
      client_buffered_bytes => byte_size(Pending),
      server_readback => ServerOptions, client_readback => ClientOptions,
      socket_counters => inet:getstat(Socket,
          [send_pend, send_cnt, send_oct, recv_cnt, recv_oct]),
      remaining_ms => remaining_ms(Deadline),
      active_leases => not_sampled_pre_reset}.

pressure_sample(Socket, Writer, Executor, Coordinator, Client, Deadline, Index) ->
    Snapshot = pressure_snapshot(Socket, Writer, Executor, Coordinator,
        Client, Deadline, Index),
    case maps:get(blocked_send_path, Snapshot) of
        true -> io:format("MIST_PRESSURE_SAMPLE ~p~n", [Snapshot]);
        false -> ok
    end,
    maps:get(blocked_send_path, Snapshot) andalso remaining_ms(Deadline) > 0.

report_pressure_probe(Socket, Writer, Executor, Coordinator, Client, Deadline, Index) ->
    Snapshot = pressure_snapshot(Socket, Writer, Executor, Coordinator,
        Client, Deadline, Index),
    io:format("MIST_PRESSURE_PROBE ~p~n", [Snapshot]),
    nil.

connection_abi({connection, _, _, _, _}) -> true;
connection_abi(_) -> false.

socket_owner({connection, _, Socket, tcp, _}, Expected) ->
    erlang:port_info(Socket, connected) =:= {connected, Expected};
socket_owner(_, _) -> false.

%% The completion subject is owned by the original request actor. Inspect its
%% mailbox before/after the non-consuming peek, without receiving the tail.
tail_unchanged({connection, {framed, _, Completion, _}, _, _, _}, Tail, Peek) ->
    {messages, Before} = process_info(self(), messages),
    Result = Peek(),
    {messages, After} = process_info(self(), messages),
    BeforeTails = subject_tails(Completion, Before),
    AfterTails = subject_tails(Completion, After),
    Result andalso BeforeTails =:= [Tail] andalso AfterTails =:= [Tail];
tail_unchanged(_, _, _) -> false.

subject_tails(Subject, Messages) ->
    %% gleam_erlang Subject is {subject, Owner, Reference}.
    Ref = element(3, Subject),
    [Tail || {Tag, Tail} <- Messages, Tag =:= Ref].

remove_directory(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(fun(Name) ->
                Path = filename:join(Dir, Name),
                case filelib:is_dir(Path) of
                    true -> remove_directory(Path);
                    false -> ok = file:delete(Path)
                end
            end, Names),
            ok = file:del_dir(Dir);
        {error, enoent} -> ok
    end.
