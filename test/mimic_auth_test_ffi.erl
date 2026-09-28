-module(mimic_auth_test_ffi).
-export([state_directory/0, mode/1, free_port/0, make_symlink/2]).
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
