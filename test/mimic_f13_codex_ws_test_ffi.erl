%% F13 synthetic socket primitives only. Fixture/protocol/lifecycle policy is
%% in Gleam. No live endpoints, shell commands, or credential ownership here.
-module(mimic_f13_codex_ws_test_ffi).
-export([listen/3, accept/1, read/1, write/2, close/1,
         saturate/1, drain_eof/2, now_ms/0, blocked_helpers/1,
         await_cleanup/4, no_write_helpers/1, await_physical_close/2,
         diagnostic_start/0, endpoints/1, prepare_cleanup/4, await_prepared/2]).

listen(false, _, _) ->
    case gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}},
                            {reuseaddr, true}, {show_econnreset, true}]) of
        {ok, Socket} ->
            {ok, {_, Port}} = inet:sockname(Socket),
            {ok, {{tcp, Socket, none}, Port}};
        _ -> {error, <<"synthetic WS listen failed">>}
    end;
listen(true, Cert, Key) ->
    _ = ssl:start(),
    case mimic_recorder_tls_ffi:make_leaf(binary_to_list(Cert),
                                          binary_to_list(Key), "127.0.0.1") of
        {ok, Temp, Leaf, LeafKey} ->
            case ssl:listen(0, [binary, {active, false}, {ip, {127,0,0,1}},
                                {reuseaddr, true}, {certfile, Leaf},
                                {keyfile, LeafKey},
                                {alpn_preferred_protocols, [<<"http/1.1">>]}]) of
                {ok, Socket} ->
                    {ok, {_, Port}} = ssl:sockname(Socket),
                    {ok, {{tls, Socket, {some, Temp}}, Port}};
                _ ->
                    mimic_recorder_tls_ffi:cleanup(Temp),
                    {error, <<"synthetic WSS listen failed">>}
            end;
        _ -> {error, <<"synthetic WSS leaf failed">>}
    end.

accept({tcp, Listener, _}) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Socket} -> {ok, {tcp, Socket, none}};
        _ -> {error, <<"synthetic WS accept failed">>}
    end;
accept({tls, Listener, _}) ->
    case ssl:transport_accept(Listener, 5000) of
        {ok, Transport} ->
            case ssl:handshake(Transport, 5000) of
                {ok, Socket} -> {ok, {tls, Socket, none}};
                _ ->
                    ssl:close(Transport),
                    {error, <<"synthetic WSS handshake failed">>}
            end;
        _ -> {error, <<"synthetic WSS accept failed">>}
    end.

read({Kind, Socket, _}) ->
    Result = case Kind of
        tcp -> gen_tcp:recv(Socket, 0, 5000);
        tls -> ssl:recv(Socket, 0, 5000)
    end,
    case Result of
        {ok, Data} -> {ok, Data};
        _ -> {error, <<"synthetic WS read failed">>}
    end.

write({Kind, Socket, _}, Bytes) ->
    Result = case Kind of
        tcp -> gen_tcp:send(Socket, Bytes);
        tls -> ssl:send(Socket, Bytes)
    end,
    case Result of
        ok -> {ok, nil};
        _ -> {error, <<"synthetic WS write failed">>}
    end.

close({Kind, Socket, Temp}) ->
    case Kind of
        tcp -> gen_tcp:close(Socket);
        tls -> ssl:close(Socket)
    end,
    case Temp of
        {some, Directory} -> mimic_recorder_tls_ffi:cleanup(Directory);
        none -> ok
    end,
    nil.

%% Test-only match of the owned Gleam Connection layout (not SSL's opaque ABI).
%% Leave a proven physical output backlog while the peer is gate-held. The next
%% production Pong send must block, rather than merely exercising a fast socket.
saturate({connection, Wrapped, TCP, _Decoder, _Pending, _Timeout, _Poll,
          _MaxMessage, _MaxFrame}) ->
    try
        ok = inet:setopts(TCP, [{sndbuf, 4096}, {send_timeout, 20},
                                {send_timeout_close, false}]),
        Data = binary:copy(<<"synthetic-pressure">>, 500000),
        Sent = case Wrapped of
            {tcp, Socket} -> gen_tcp:send(Socket, Data);
            {tls, Socket} -> ssl:send(Socket, Data)
        end,
        case {Sent, inet:getstat(TCP, [send_pend]), inet:peername(TCP)} of
            {Result, {ok, [{send_pend, Pending}]}, {ok, _}}
              when Pending >= 65536, Result =:= ok;
                   Pending >= 65536, Result =:= {error, timeout} ->
                {ok, Pending};
            _ -> {error, <<"synthetic output pressure was not established">>}
        end
    catch
        _:_ -> {error, <<"synthetic pressure setup failed">>}
    end;
saturate(_) -> {error, <<"synthetic Connection layout mismatch">>}.

%% Only an actual closed/reset read is physical termination; timeouts or
%% arbitrary TLS protocol errors are not. Keep reset distinct from graceful EOF.
%% Drain prebuffered pressure bytes without parsing/fabricating provider events.
drain_eof(Socket, Timeout) ->
    Start = now_ms(),
    put(f13_drain_bytes, 0),
    put(f13_drain_reads, 0),
    drain(Socket, Start, Start + Timeout).

drain({Kind, Socket, _} = Wrapped, Start, Deadline) ->
    case now_ms() < Deadline of
        false -> {error, <<"synthetic peer EOF deadline expired">>};
        true ->
            Result = case Kind of
                tcp -> gen_tcp:recv(Socket, 0, Deadline - now_ms());
                tls -> ssl:recv(Socket, 0, Deadline - now_ms())
            end,
            case Result of
                {ok, Bytes} ->
                    put(f13_drain_bytes, get(f13_drain_bytes) + byte_size(Bytes)),
                    put(f13_drain_reads, get(f13_drain_reads) + 1),
                    drain(Wrapped, Start, Deadline);
                {error, closed} -> {ok, {now_ms() - Start, <<"eof">>}};
                {error, econnreset} -> {ok, {now_ms() - Start, <<"reset">>}};
                {error, timeout} ->
                    diagnostic({peer_timeout, now_ms() - Start,
                                get(f13_drain_bytes), get(f13_drain_reads)}),
                    {error, <<"synthetic peer termination: timeout">>};
                {error, {tls_alert, {user_canceled, _}}} ->
                    {error, <<"synthetic peer termination: TLS user-canceled">>};
                {error, {tls_alert, {internal_error, _}}} ->
                    {error, <<"synthetic peer termination: TLS internal-error">>};
                {error, {tls_alert, _}} ->
                    {error, <<"synthetic peer termination: TLS alert">>};
                _ -> {error, <<"synthetic peer termination: other error">>}
            end
    end.

now_ms() -> erlang:monotonic_time(millisecond).

%% Readiness is a measured process/socket condition, not a fixed sleep-order
%% assumption. Inspect only process graph/status; never stack arguments/data.
blocked_helpers(Owner) -> blocked_helpers(Owner, now_ms() + 100).
blocked_helpers(Owner, Deadline) ->
    Candidates = case process_info(Owner, monitors) of
        {monitors, OwnerMonitors} ->
            [P || {process, P} <- OwnerMonitors, is_pid(P)];
        _ -> []
    end,
    Pairs = lists:flatmap(fun(Guardian) ->
        case process_info(Guardian, monitors) of
            {monitors, GuardMonitors} ->
                Senders = [P || {process, P} <- GuardMonitors, P =/= Owner],
                [{Guardian, S} || S <- Senders, waiting(S)];
            _ -> []
        end
    end, Candidates),
    case Pairs of
        [Pair] -> {ok, Pair};
        _ ->
            case now_ms() < Deadline of
                true ->
                    receive after 1 -> blocked_helpers(Owner, Deadline) end;
                false -> {error, <<"synthetic blocked WS sender not observed">>}
            end
    end.

waiting(Pid) ->
    case {process_info(Pid, status), process_info(Pid, current_function)} of
        {{status, waiting}, {current_function, {Module, _, _}}}
          when Module =:= prim_inet; Module =:= gen; Module =:= gen_statem ->
            true;
        _ -> false
    end.

await_cleanup(Connection, Guardian, Sender, Timeout) ->
    Start = now_ms(),
    {connection, _, TCP, _, _, _, _, _, _} = Connection,
    SocketMonitor = inet:monitor(TCP),
    GuardianMonitor = erlang:monitor(process, Guardian),
    SenderMonitor = erlang:monitor(process, Sender),
    Deadline = Start + Timeout,
    Closed = await_down(SocketMonitor, TCP, Deadline),
    GuardStopped = await_down(GuardianMonitor, Guardian, Deadline),
    SendStopped = await_down(SenderMonitor, Sender, Deadline),
    _ = inet:cancel_monitor(SocketMonitor),
    erlang:demonitor(GuardianMonitor, [flush]),
    erlang:demonitor(SenderMonitor, [flush]),
    case Closed andalso GuardStopped andalso SendStopped of
        true -> {ok, now_ms() - Start};
        false -> {error, <<"synthetic socket/helper cleanup unconfirmed">>}
    end.

await_physical_close(Connection, Timeout) ->
    Start = now_ms(),
    {connection, _, TCP, _, _, _, _, _, _} = Connection,
    Monitor = inet:monitor(TCP),
    Closed = await_down(Monitor, TCP, Start + Timeout),
    _ = inet:cancel_monitor(Monitor),
    case Closed of
        true -> {ok, now_ms() - Start};
        false -> {error, <<"synthetic physical close unconfirmed">>}
    end.

await_down(Monitor, Object, Deadline) ->
    receive {'DOWN', Monitor, _, Object, _} -> true
    after max(0, Deadline - now_ms()) -> false
    end.

no_write_helpers(Owner) ->
    case process_info(Owner, monitors) of
        {monitors, Monitors} ->
            not lists:any(fun({process, _}) -> true; (_) -> false end, Monitors);
        _ -> false
    end.

diagnostic_start() ->
    put(mimic_f13_diagnostic, true),
    nil.

endpoints({Kind, Socket, _}) ->
    Local = case Kind of tcp -> inet:sockname(Socket); tls -> ssl:sockname(Socket) end,
    Peer = case Kind of tcp -> inet:peername(Socket); tls -> ssl:peername(Socket) end,
    case {Local, Peer} of
        {{ok, {{127,0,0,1}, L}}, {ok, {{127,0,0,1}, P}}} -> {ok, {L, P}};
        _ -> {error, <<"synthetic reciprocal endpoints unavailable">>}
    end.

%% Install exact monitors while all objects are proven alive, BEFORE kill.
prepare_cleanup({connection, Wrapped, TCP, _, _, _, _, _, _},
                Owner, Helpers, {PeerLocal, PeerRemote}) ->
    try
        true = is_process_alive(Owner),
        true = lists:all(fun is_process_alive/1, Helpers),
        {ok, {{127,0,0,1}, PeerRemote}} = inet:sockname(TCP),
        {ok, {{127,0,0,1}, PeerLocal}} = inet:peername(TCP),
        {connected, PhysicalOwner} = erlang:port_info(TCP, connected),
        true = is_process_alive(PhysicalOwner),
        case Wrapped of
            {tcp, TCP} -> true = PhysicalOwner =:= Owner;
            {tls, _} -> ok
        end,
        case Helpers of
            [Guardian, Sender] ->
                {monitors, GM} = process_info(Guardian, monitors),
                true = lists:member({process, Owner}, GM),
                true = lists:member({process, Sender}, GM),
                {links, GL} = process_info(Guardian, links),
                true = lists:member(Sender, GL);
            [] -> ok
        end,
        Monitors = [{inet:monitor(TCP), TCP, port} |
                    [{erlang:monitor(process, P), P, process} || P <- Helpers]],
        diagnostic({prekill_identity, reciprocal, PhysicalOwner =:= Owner,
                    length(Helpers)}),
        {ok, Monitors}
    catch
        _:_ -> {error, <<"synthetic prekill identity or helper validation failed">>}
    end.

await_prepared(Monitors, Timeout) ->
    Start = now_ms(),
    Results = [receive
                   {'DOWN', M, Type, Object, Reason} ->
                       diagnostic({preinstalled_down, Type, down_category(Reason)}),
                       Reason =/= noproc andalso Reason =/= nosock
               after max(0, Start + Timeout - now_ms()) -> false
               end || {M, Object, Type} <- Monitors],
    lists:foreach(fun({M, _, port}) -> inet:cancel_monitor(M);
                     ({M, _, process}) -> erlang:demonitor(M, [flush])
                  end, Monitors),
    case lists:all(fun(X) -> X end, Results) of
        true -> {ok, now_ms() - Start};
        false -> {error, <<"synthetic preinstalled cleanup unconfirmed">>}
    end.

down_category(normal) -> normal;
down_category(killed) -> killed;
down_category(noproc) -> noproc;
down_category(nosock) -> nosock;
down_category(shutdown) -> shutdown;
down_category(_) -> other.

diagnostic(Event) ->
    io:format("[F13_DIAG] ~p ~p~n", [now_ms(), Event]).
