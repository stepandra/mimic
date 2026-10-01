-module(mimic_containment_boot).
-export([boot/0]).

%% Executable-only VM wrapper, never called by feature/library code.
%% The Gleam owner decides WHY/WHEN to stop. The watchdog is an OS shutdown
%% backstop if reporting, startup or VM I/O stalls; it never spawns a target.
boot() ->
    case os:getpid() =:= "1" andalso os:type() =:= {unix, linux} of
        false -> erlang:error(containment_boot_requires_namespace_pid1);
        true ->
            spawn(fun() ->
                timer:sleep(310000),
                erlang:halt(124, [{flush, false}])
            end),
            {Code, Report} = 'mimic@containment@owner':boot(),
            %% Reporting cannot hold descendants alive after a terminal event,
            %% even if the parent's stdout channel is full or already gone.
            spawn(fun() ->
                timer:sleep(100),
                erlang:halt(Code, [{flush, false}])
            end),
            io:put_chars(standard_io, [Report, $\n]),
            erlang:halt(Code, [{flush, false}])
    end.
