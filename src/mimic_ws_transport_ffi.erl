-module(mimic_ws_transport_ffi).
-export([connect_with_ca/5, write_until/4, abort/2]).

%% WS-only socket primitives. The Gleam actor remains the sole logical writer.
%% Public STARTTLS retains the physical TCP handle; no private SSL tuple ABI,
%% credential policy, reconnect, payload logging or graceful TLS close here.
connect_with_ca(Host, Port, TLS, Timeout, CA) ->
    Deadline = now_ms() + Timeout,
    Options = [binary, {active, false}, {packet, raw}, {linger, {false, 0}},
               {send_timeout, Timeout}, {send_timeout_close, true}],
    try gen_tcp:connect(binary_to_list(Host), Port, Options, left(Deadline)) of
        {ok, TCP} ->
            try finish_connect(Host, TLS, TCP, Deadline, CA) of
                {ok, _} = Ready -> Ready;
                {error, _} = Failure -> cleanup(TCP, Failure)
            catch
                _:_ -> cleanup(TCP, {error, <<"WS TLS setup failed">>})
            end;
        {error, _} -> {error, <<"WS TCP connect failed">>}
    catch
        _:_ -> {error, <<"WS TCP setup failed">>}
    end.

finish_connect(_, false, TCP, Deadline, _) ->
    case now_ms() < Deadline of
        true -> {ok, {{tcp, TCP}, TCP}};
        false -> {error, <<"WS connect deadline expired">>}
    end;
finish_connect(Host, true, TCP, Deadline, CA) ->
    _ = ssl:start(),
    Trust = case CA of
        none -> {cacerts, public_key:cacerts_get()};
        {some, File} -> {cacertfile, binary_to_list(File)}
    end,
    TLSOptions = [binary, {active, false}, {packet, raw},
                  {verify, verify_peer}, Trust,
                  {server_name_indication, binary_to_list(Host)},
                  {customize_hostname_check,
                   [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
                  {alpn_advertised_protocols, [<<"http/1.1">>]}],
    case now_ms() < Deadline of
        false -> {error, <<"WS connect deadline expired">>};
        true ->
            case ssl:connect(TCP, TLSOptions, left(Deadline)) of
                {ok, SSL} ->
                    case {now_ms() < Deadline, ssl:negotiated_protocol(SSL)} of
                        {true, {ok, <<"http/1.1">>}} -> {ok, {{tls, SSL}, TCP}};
                        {true, {error, protocol_not_negotiated}} ->
                            {ok, {{tls, SSL}, TCP}};
                        _ -> {error, <<"WS TLS ALPN or deadline rejected">>}
                    end;
                {error, _} -> {error, <<"WS verified TLS connect failed">>}
            end
    end.

%% Set the actual physical send timeout before each send, with no restoration.
%% The absolute watchdog also bounds TLS sends spanning multiple records or
%% blocked SSL API calls. A short-lived OS guardian independently monitors the
%% caller/deadline and exactly one linked sender. Caller death cannot orphan an
%% SSL send whose physical socket is owned by SSL rather than by that caller.
write_until(Socket, TCP, Data, Deadline) ->
    try perform_write(Socket, TCP, Data, Deadline)
    catch
        _:_ -> cleanup_until(TCP, {error, <<"WS write primitive failed">>},
                             min(now_ms() + 100, Deadline + 100))
    end.

perform_write(Socket, TCP, Data, Deadline) ->
    case now_ms() < Deadline of
        false -> cleanup(TCP, {error, <<"WS write deadline expired">>});
        true ->
            Caller = self(),
            Diagnostic = get(mimic_f13_diagnostic),
            {Guardian, Monitor} = spawn_monitor(fun() ->
                put(mimic_f13_diagnostic, Diagnostic),
                process_flag(trap_exit, true),
                Result = try guarded_send(Caller, Socket, TCP, Data, Deadline)
                catch
                    _:_ -> cleanup_until(TCP, {error, <<"WS write guardian failed">>},
                                         min(now_ms() + 100, Deadline + 100))
                end,
                exit({ws_guardian_result, Result})
            end),
            receive
                {'DOWN', Monitor, process, Guardian, {ws_guardian_result, {ok, nil}}} ->
                    case now_ms() < Deadline of
                        true -> {ok, nil};
                        false -> cleanup_until(TCP, {error, <<"WS write deadline expired">>},
                                               Deadline + 100)
                    end;
                {'DOWN', Monitor, process, Guardian, {ws_guardian_result, Failure}} ->
                    Failure;
                {'DOWN', Monitor, process, Guardian, _} ->
                    cleanup(TCP, {error, <<"WS socket write failed">>})
            after left(Deadline + 100) ->
                %% Unexpected guardian failure is never success. Abort before
                %% killing it; its link also kills the sole sender. Do not add
                %% another cleanup allowance after the absolute budget.
                _ = abort(TCP, Deadline + 100),
                exit(Guardian, kill),
                receive {'DOWN', Monitor, process, Guardian, _} -> ok
                after left(Deadline + 100) -> erlang:demonitor(Monitor, [flush])
                end,
                {error, <<"WS write guardian cleanup unconfirmed">>}
            end
    end.

guarded_send(Caller, Socket, TCP, Data, Deadline) ->
    OwnerMonitor = erlang:monitor(process, Caller),
    Diagnostic = get(mimic_f13_diagnostic),
    {Sender, SenderMonitor} = spawn_opt(fun() ->
        put(mimic_f13_diagnostic, Diagnostic),
        trace(sender_started),
        Result = try
            case inet:setopts(TCP, [{send_timeout, left(Deadline)},
                                    {send_timeout_close, true}]) of
                ok -> trace(send_options_ok), send(Socket, Data);
                {error, _} -> trace(send_options_failed), failed
            end
        catch
            _:_ -> failed
        end,
        %% Only a sanitized enum is carried by DOWN, never raw reasons/payload.
        exit({ws_write_result, Result})
    end, [link, monitor]),
    Result = receive
        {'DOWN', SenderMonitor, process, Sender, {ws_write_result, ok}} ->
            trace(sender_down_ok),
            case now_ms() < Deadline andalso is_process_alive(Caller) of
                true -> {ok, nil};
                false ->
                    cleanup_until(TCP, {error, <<"WS write deadline or owner lost">>},
                                  min(now_ms() + 100, Deadline + 100))
            end;
        {'DOWN', SenderMonitor, process, Sender, _} ->
            trace(sender_down_failed),
            cleanup_until(TCP, {error, <<"WS socket write failed">>},
                          min(now_ms() + 100, Deadline + 100));
        {'DOWN', OwnerMonitor, process, Caller, _} ->
            trace(owner_down),
            stop_sender(TCP, Sender, SenderMonitor, Deadline,
                        <<"WS write owner terminated">>)
    after left(Deadline) ->
        trace(write_deadline),
        stop_sender(TCP, Sender, SenderMonitor, Deadline,
                    <<"WS write deadline expired">>)
    end,
    erlang:demonitor(OwnerMonitor, [flush]),
    Result.

stop_sender(TCP, Sender, Monitor, Deadline, Reason) ->
    CleanupDeadline = min(now_ms() + 100, Deadline + 100),
    Closed = abort(TCP, CleanupDeadline),
    trace({abort_result, category(Closed)}),
    exit(Sender, kill),
    Stopped = receive
        {'DOWN', Monitor, process, Sender, _} -> true
    after left(CleanupDeadline) -> false
    end,
    case {Closed, Stopped} of
        {{ok, nil}, true} -> {error, Reason};
        _ ->
            erlang:demonitor(Monitor, [flush]),
            {error, <<"WS physical write cleanup failed">>}
    end.

send({tcp, Socket}, Data) ->
    case gen_tcp:send(Socket, Data) of ok -> ok; {error, _} -> failed end;
send({tls, Socket}, Data) ->
    case ssl:send(Socket, Data) of ok -> ok; {error, _} -> failed end.

%% Abortive physical termination, not graceful TLS EOF or pending-byte delivery.
%% Disabled linger is NOT sufficient: prim_inet.close may drain for 180 seconds.
%% Set abortive linger before close, then require public inet monitor evidence.
%% This supports both inet backends (port/socket), including already-closed
%% handles. A timeout alone is never reported as successful closure.
abort(TCP, Deadline) ->
    trace(abort_enter),
    try inet:monitor(TCP) of
        Monitor ->
            Forced = force_close(TCP),
            trace({force_close_result, category(Forced)}),
            receive
                {'DOWN', Monitor, Type, TCP, Reason}
                  when Type =:= port; Type =:= socket ->
                    trace({raw_down, Type, category(Reason)}),
                    _ = inet:cancel_monitor(Monitor),
                    {ok, nil}
            after left(Deadline) ->
                _ = inet:cancel_monitor(Monitor),
                receive {'DOWN', Monitor, _, _, _} -> ok after 0 -> ok end,
                {error, <<"WS physical socket close unconfirmed">>}
            end
    catch
        _:_ ->
            _ = force_close(TCP),
            {error, <<"WS physical socket cleanup failed">>}
    end.

force_close(TCP) ->
    Configured = try inet:setopts(TCP, [{linger, {true, 0}}])
    catch _:_ -> failed
    end,
    trace({abortive_linger, category(Configured)}),
    case Configured of
        ok ->
            try gen_tcp:close(TCP)
            catch _:_ -> failed
            end;
        _ when is_port(TCP) ->
            %% Public port close bypasses prim_inet's pending-output drain.
            %% Closed/bad handles still require monitor evidence in abort/2.
            try erlang:port_close(TCP)
            catch _:_ -> failed
            end;
        _ -> failed
    end.

cleanup(TCP, Failure) ->
    cleanup_until(TCP, Failure, now_ms() + 100).

cleanup_until(TCP, Failure, Deadline) ->
    case abort(TCP, Deadline) of
        {ok, nil} -> Failure;
        {error, _} = CleanupFailure -> CleanupFailure
    end.

now_ms() -> erlang:monotonic_time(millisecond).
left(Deadline) -> max(0, Deadline - now_ms()).

%% Opt-in test diagnostic; events contain only fixed categories and time.
%% No socket, reason string, write arguments or credentials enter this output.
trace(Event) ->
    case get(mimic_f13_diagnostic) of
        true -> io:format("[F13_DIAG] ~p ~p~n", [now_ms(), Event]);
        _ -> ok
    end.

category(ok) -> ok;
category({ok, nil}) -> ok;
category(normal) -> normal;
category(noproc) -> noproc;
category(nosock) -> nosock;
category(killed) -> killed;
category(shutdown) -> shutdown;
category(failed) -> failed;
category({error, closed}) -> closed;
category({error, einval}) -> einval;
category({error, _}) -> error;
category(_) -> other.
