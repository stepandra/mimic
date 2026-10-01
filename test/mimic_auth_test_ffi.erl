-module(mimic_auth_test_ffi).
-export([state_directory/0, mode/1, free_port/0, make_symlink/2, attempt/1,
         h2_callback_status/2]).
-include_lib("kernel/include/file.hrl").

state_directory() ->
    Path = filename:absname(filename:join(
        "build", "auth-test-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))))),
    ok = file:make_dir(Path),
    ok = file:change_mode(Path, 8#700),
    list_to_binary(Path).

mode(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{mode = Mode}} -> Mode band 8#777;
        _ -> -1
    end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    ok = gen_tcp:close(Socket),
    Port.

make_symlink(Target, Link) ->
    ok = file:make_symlink(Target, Link),
    nil.

%% A failed test HTTP client must still report to its parent, not strand it.
attempt(Call) ->
    try {ok, Call()}
    catch _:_ -> {error, nil}
    end.

%% Synthetic prior-knowledge HTTP/2 negative probe; bounded to loopback.
h2_callback_status(Port, Path) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}], 2000) of
        {ok, Socket} ->
            try
                Headers = [{<<":method">>, <<"GET">>},
                           {<<":scheme">>, <<"http">>},
                           {<<":authority">>, <<"127.0.0.1:", (integer_to_binary(Port))/binary>>},
                           {<<":path">>, Path}],
                {ok, {Block, _}} = hpack:encode(Headers, hpack:new_context()),
                ok = gen_tcp:send(Socket,
                    [<<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
                     <<0:24, 4:8, 0:8, 0:32>>,
                     <<(byte_size(Block)):24, 1:8, 5:8, 1:32, Block/binary>>]),
                h2_status(Socket, 16, erlang:monotonic_time(millisecond) + 2000)
            catch _:_ -> {error, nil}
            after gen_tcp:close(Socket)
            end;
        _ -> {error, nil}
    end.

h2_status(_, 0, _) -> {error, nil};
h2_status(Socket, Left, Deadline) ->
    Timeout = Deadline - erlang:monotonic_time(millisecond),
    true = Timeout > 0,
    {ok, <<Size:24, Type:8, Flags:8, _:1, Stream:31>>} =
        gen_tcp:recv(Socket, 9, Timeout),
    true = Size =< 65536,
    Payload = case Size of
        0 -> <<>>;
        _ ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            true = Remaining > 0,
            {ok, Bytes} = gen_tcp:recv(Socket, Size, Remaining),
            Bytes
    end,
    case {Type, Flags, Stream} of
        {1, F, 1} when F band 4 =/= 0 ->
            {ok, {Headers, _}} = hpack:decode(Payload, hpack:new_context()),
            {ok, binary_to_integer(proplists:get_value(<<":status">>, Headers))};
        {4, 0, 0} ->
            ok = gen_tcp:send(Socket, <<0:24, 4:8, 1:8, 0:32>>),
            h2_status(Socket, Left - 1, Deadline);
        _ -> h2_status(Socket, Left - 1, Deadline)
    end.
