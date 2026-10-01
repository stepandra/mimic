-module(mimic_containment_ffi).
-export([open/2, receive_event/2, send/2, close/1, clock/0, nonce/0, utf8/1,
         stdin/0, owner_boundary/0, fixtures/0, record_boundary/1,
         companion/1, kill_owned/1]).

%% Never invoke a shell or inherit the operator's environment. Docker is
%% selected by an explicit absolute executable and explicit unix socket.
open(Executable, Args) ->
    try
        Cleared = maps:from_list(
                    [{hd(string:split(Item, "=")), false} || Item <- os:getenv()]),
        Env = maps:to_list(maps:merge(Cleared,
                    #{"HOME" => "/nonexistent", "DOCKER_CONFIG" => "/nonexistent",
                      "LANG" => "C", "TZ" => "UTC"})),
        Port = open_port({spawn_executable, binary_to_list(Executable)},
            [binary, exit_status, use_stdio, stderr_to_stdout, hide,
             {args, [binary_to_list(A) || A <- Args]},
             {env, Env}]),
        {ok, Port}
    catch _:_ -> {error, <<"containment_os_launch_unavailable">>} end.

receive_event(Port, Wait) ->
    receive
        {Port, {data, {eol, Line}}} -> {data, Line};
        {Port, {data, {noeol, _}}} -> fault;
        %% A chunk may end mid-codepoint. Accumulate bounded bytes first, then
        %% validate complete UTF-8, rather than corrupt/reject valid split text.
        {Port, {data, Bytes}} -> {data, Bytes};
        {Port, {exit_status, Code}} -> {exited, Code};
        {Port, eof} -> closed;
        {'EXIT', Port, _} -> fault
    after Wait -> idle end.

send(Port, Data) ->
    try true = port_command(Port, Data), {ok, nil}
    catch _:_ -> {error, <<"containment_channel_closed">>} end.

close(Port) ->
    try port_close(Port) catch _:_ -> ok end,
    nil.

clock() -> erlang:monotonic_time(millisecond).
nonce() -> binary:encode_hex(crypto:strong_rand_bytes(24), lowercase).

utf8(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Bytes -> {ok, Bytes};
        _ -> {error, <<"containment_unsupported_binary_output">>}
    end.

stdin() ->
    try {ok, open_port({fd, 0, 1}, [binary, eof, {line, 128}])}
    catch _:_ -> {error, <<"containment_lease_channel_unavailable">>} end.

%% The BEAM VM must be PID1, not a process underneath a shell or Docker --init.
%% Only SETUID/SETGID remain in the trusted owner; targets must drop both.
owner_boundary() ->
    try
        {unix, linux} = os:type(),
        <<"1">> = list_to_binary(os:getpid()),
        true = filelib:is_regular("/.dockerenv"),
        {ok, Status} = file:read_file("/proc/self/status"),
        true = contains(Status, <<"Uid:\t0\t0\t0\t0">>),
        true = contains(Status, <<"NoNewPrivs:\t1">>),
        true = contains(Status, <<"CapEff:\t00000000000000c0">>),
        {ok, ["lo"]} = file:list_dir("/sys/class/net"),
        {ok, Mounts} = file:read_file("/proc/mounts"),
        [Root] = [binary:split(L, <<" ">>, [global])
                  || L <- binary:split(Mounts, <<"\n">>, [global]),
                     length(binary:split(L, <<" ">>, [global])) > 3,
                     lists:nth(2, binary:split(L, <<" ">>, [global])) =:= <<"/">>],
        true = lists:member(<<"ro">>, binary:split(lists:nth(4, Root), <<",">>, [global])),
        {ok, nil}
    catch _:_ -> {error, <<"containment_namespace_owner_boundary_missing">>} end.

contains(Haystack, Needle) -> binary:match(Haystack, Needle) =/= nomatch.

record_boundary(Data) ->
    try
        {ok, File} = file:open("/tmp/mimic-f02-owner", [write, binary, exclusive]),
        ok = file:write(File, Data),
        ok = file:close(File),
        ok = file:change_mode("/tmp/mimic-f02-owner", 8#444),
        {ok, nil}
    catch _:_ -> {error, <<"containment_owner_marker_failed">>} end.

%% Fixed, harmless listening fixtures. Only the selftest path calls this.
%% The denied listener is really reachable in the namespace, not an unused port.
fixtures() ->
    try
        {ok, Allowed} = gen_tcp:listen(39001, [binary, {active, false},
                                             {ip, {127,0,0,1}}, {reuseaddr, true}]),
        {ok, Denied} = gen_tcp:listen(39002, [binary, {active, false},
                                            {ip, {127,0,0,1}}, {reuseaddr, true}]),
        spawn(fun() -> fixture_loop(Allowed) end),
        spawn(fun() -> fixture_loop(Denied) end),
        ok = file:write_file("/tmp/f02-owner-private", <<"synthetic-owner-only">>),
        ok = file:change_mode("/tmp/f02-owner-private", 8#600),
        {ok, nil}
    catch _:_ -> {error, <<"containment_synthetic_fixture_failed">>} end.

fixture_loop(Socket) ->
    case gen_tcp:accept(Socket) of
        {ok, Client} ->
            gen_tcp:send(Client, <<"synthetic-local-fixture\n">>),
            gen_tcp:close(Client),
            fixture_loop(Socket);
        _ -> ok
    end.

%% A real *separate* BEAM coordinator for the parent-SIGKILL fault.
%% Code paths are our compiled artifact, not a caller-selected program.
companion(Args) ->
    try
        Erl = os:find_executable("erl"),
        true = is_list(Erl),
        Paths = lists:usort([filename:dirname(code:which(M))
                            || M <- ['mimic@containment@companion',
                                     'gleam@list', 'gleam@json', argv],
                               code:which(M) =/= non_existing]),
        CodeArgs = lists:append([["-pa", Path] || Path <- Paths]),
        open(list_to_binary(Erl),
             [list_to_binary(A) || A <- ["-noshell", "-noinput", "+S", "1:1",
                   "+A", "1"] ++ CodeArgs ++ ["-eval",
                   "erlang:halt('mimic@containment@companion':boot()).", "-extra"]]
             ++ Args)
    catch _:_ -> {error, <<"containment_sigkill_companion_unavailable">>} end.

%% Only signal a child whose handle we opened. Never accept arbitrary host PIDs.
kill_owned(Port) ->
    try
        {os_pid, Pid} = erlang:port_info(Port, os_pid),
        {ok, Killer} = open(<<"/bin/kill">>,
                           [<<"-KILL">>, integer_to_binary(Pid)]),
        receive
            {Killer, {exit_status, 0}} -> {ok, nil};
            {Killer, {exit_status, _}} -> {error, <<"containment_owned_sigkill_failed">>}
        after 2000 ->
            close(Killer), {error, <<"containment_owned_sigkill_timeout">>}
        end
    catch _:_ -> {error, <<"containment_owned_child_missing">>} end.
