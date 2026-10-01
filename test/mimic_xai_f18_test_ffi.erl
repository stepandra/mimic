%% Synthetic F18 test synchronization only; no transport or domain authority.
-module(mimic_xai_f18_test_ffi).
-export([new_switch/0, allowed/1, revoke/1, new_clock/1, clock_now/1, set_clock/2,
         start_accept_probe/0, accept_count/1, stop_accept_probe/1]).

new_switch() ->
    Switch = atomics:new(1, [{signed, false}]),
    ok = atomics:put(Switch, 1, 1),
    Switch.

allowed(Switch) ->
    atomics:get(Switch, 1) =:= 1.

revoke(Switch) ->
    ok = atomics:put(Switch, 1, 0),
    nil.

new_clock(Value) ->
    Clock = atomics:new(1, [{signed, false}]),
    ok = atomics:put(Clock, 1, Value),
    Clock.

clock_now(Clock) ->
    atomics:get(Clock, 1).

set_clock(Clock, Value) ->
    ok = atomics:put(Clock, 1, Value),
    nil.

%% A numeric-loopback TCP accept oracle, NOT an HTTP/WS implementation.
%% Increment before closing accepted sockets so any erroneous open returning
%% from peer closure cannot race ahead of the observed count. No byte capture.
start_accept_probe() ->
    case gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]) of
        {ok, Listen} ->
            {ok, {_, Port}} = inet:sockname(Listen),
            Count = atomics:new(1, [{signed, false}]),
            Worker = spawn_link(fun() -> accept_probe(Listen, Count) end),
            {ok, {{Listen, Worker, Count}, Port}};
        _ ->
            {error, <<"synthetic accept probe unavailable">>}
    end.

accept_probe(Listen, Count) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            atomics:add(Count, 1, 1),
            gen_tcp:close(Socket),
            accept_probe(Listen, Count);
        _ ->
            ok
    end.

accept_count({_, _, Count}) ->
    atomics:get(Count, 1).

stop_accept_probe({Listen, Worker, _}) ->
    Monitor = erlang:monitor(process, Worker),
    gen_tcp:close(Listen),
    receive
        {'DOWN', Monitor, process, Worker, _} -> {ok, nil}
    after 500 ->
        exit(Worker, kill),
        receive
            {'DOWN', Monitor, process, Worker, _} ->
                {error, <<"synthetic accept probe stop deadline">>}
        end
    end.
