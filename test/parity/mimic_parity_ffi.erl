-module(mimic_parity_ffi).
-export([sha256/1, private_directory/0, run/3, fail/0, pid/0]).

sha256(Text) ->
    binary:encode_hex(crypto:hash(sha256, Text), lowercase).

private_directory() ->
    {ok, Cwd} = file:get_cwd(),
    Root = filename:join([Cwd, "build", "parity-results"]),
    ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
    ok = file:change_mode(Root, 8#700),
    Name = "mimic-parity-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    Path = filename:join(Root, Name),
    case file:make_dir(Path) of
        ok ->
            ok = file:change_mode(Path, 8#700),
            {ok, unicode:characters_to_binary(Path)};
        _ -> {error, <<"cannot create private parity directory">>}
    end.

%% OS boundary only: argv execution, bounded output/time and a clean environment.
%% Drivers own and reap their service children; no shell interpolation.
run([], _, _) -> {error, <<"empty driver argv">>};
run([Command | Args], Plan, Home) ->
    Executable = os:find_executable(binary_to_list(Command)),
    case Executable of
        false -> {error, <<"driver executable unavailable">>};
        _ ->
            Clear = [{K, false} || {K, _} <- os:env(),
                      not lists:member(K, ["PATH", "TMPDIR", "SystemRoot"])],
            Env = [{"HOME", binary_to_list(Home)},
                   {"XDG_CONFIG_HOME", binary_to_list(Home)},
                   {"XDG_CACHE_HOME", binary_to_list(Home)},
                   {"PARITY_OFFLINE", "1"} |
                   [P || P = {K, _} <- Clear,
                         not lists:member(K, ["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "PARITY_OFFLINE"])]],
            try
                Port = open_port({spawn_executable, Executable},
                    [binary, exit_status, use_stdio, hide,
                     {args, [binary_to_list(A) || A <- Args ++ [Plan]]},
                     {env, Env}]),
                Deadline = erlang:monotonic_time(millisecond) + 60000,
                collect(Port, Deadline, <<>>)
            catch _:_ -> {error, <<"driver launch failed">>} end
    end.

collect(Port, Deadline, Output) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when byte_size(Output) + byte_size(Data) =< 1048576 ->
            collect(Port, Deadline, <<Output/binary, Data/binary>>);
        {Port, {data, _}} ->
            close(Port), {error, <<"driver output exceeds 1 MiB">>};
        {Port, {exit_status, 0}} -> {ok, Output};
        {Port, {exit_status, _}} -> {error, <<"driver exited unsuccessfully">>}
    after Timeout ->
        close(Port), {error, <<"driver deadline exceeded">>}
    end.

close(Port) -> try port_close(Port) catch _:_ -> ok end.

fail() -> erlang:halt(1).
pid() -> unicode:characters_to_binary(os:getpid()).
