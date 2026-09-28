-module(mimic_drive_ffi).
-export([docker/1, wait/2]).

%% Only the Docker executable is resolved on the host. Everything from the
%% drive is an argument, never shell text. No host environment is inherited
%% into the container, and output is discarded to avoid logging credentials.
docker(Args) ->
    case os:find_executable("docker") of
        false -> {error, <<"Docker unavailable; no host fallback">>};
        Executable ->
            try
                Name = <<"mimic-drive-",
                    (binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))/binary>>,
                [<<"run">> | Rest] = Args,
                RunArgs = [<<"run">>, <<"--name">>, Name | Rest],
                Port = open_port({spawn_executable, Executable},
                    [exit_status, use_stdio, stderr_to_stdout, binary,
                     {args, [binary_to_list(A) || A <- RunArgs]},
                     {env, [{"DOCKER_CONFIG", false}]}]),
                case wait(Port, erlang:monotonic_time(millisecond) + 300000) of
                    {error, <<"Docker timed out">>} ->
                        case remove_container(Executable, Name) of
                            ok -> {error, <<"Docker timed out; container removed">>};
                            _ -> {error, <<"Docker timed out; container cleanup unverified: ", Name/binary>>}
                        end;
                    Result -> Result
                end
            catch _:_ -> {error, <<"Docker launch failed">>} end
    end.

remove_container(Executable, Name) ->
    try
        Port = open_port({spawn_executable, Executable},
            [exit_status, use_stdio, stderr_to_stdout, binary,
             {args, ["rm", "-f", binary_to_list(Name)]},
             {env, [{"DOCKER_CONFIG", false}]}]),
        case wait(Port, erlang:monotonic_time(millisecond) + 5000) of
            {ok, 0} -> ok;
            _ -> error
        end
    catch _:_ -> error end.

wait(Port, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, _}} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> timeout(Port);
                false -> wait(Port, Deadline)
            end;
        {Port, {exit_status, Status}} -> {ok, Status}
    after Remaining -> timeout(Port)
    end.
timeout(Port) ->
    %% The caller force-removes the uniquely named container after closing
    %% the CLI port, and reports when cleanup cannot be verified.
    try port_close(Port) catch _:_ -> ok end,
    {error, <<"Docker timed out">>}.
