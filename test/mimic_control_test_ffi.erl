-module(mimic_control_test_ffi).
-export([private_directory/0, ingress_request/2, validate_from_other_cwd/1]).

private_directory() ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    Path = filename:absname(filename:join(
        <<".mimic/test">>, <<"control-", Suffix/binary>>)),
    case filelib:ensure_dir(filename:join(Path, <<"marker">>)) of
        ok ->
            case file:change_mode(Path, 8#700) of
                ok -> {ok, Path};
                _ -> {error, <<"test directory permissions failed">>}
            end;
        _ -> {error, <<"test directory creation failed">>}
    end.

ingress_request(Port, Key) ->
    application:ensure_all_started(inets),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/messages",
    Headers = [{"x-api-key", binary_to_list(Key)}],
    Body = "{\"model\":\"synthetic\",\"max_tokens\":1,\"messages\":[]}",
    case httpc:request(post, {Url, Headers, "application/json", Body},
                       [{timeout, 5000}], []) of
        {ok, {{_, Status, _}, _, ResponseBody}} ->
            {ok, {Status, unicode:characters_to_binary(ResponseBody)}};
        _ -> {error, <<"loopback ingress request failed">>}
    end.

%% A separate BEAM avoids changing the test runner's process-global cwd.
%% /tmp is not normally owned by the operator; the private state directory is.
validate_from_other_cwd(Directory) ->
    Ebin = filename:dirname(code:which(mimic_auth_ffi)),
    Expr = "case mimic_auth_ffi:validate_directory("
           "list_to_binary(os:getenv(\"MIMIC_TEST_STATE_DIR\"))) "
           "of {ok,nil} -> halt(0); _ -> halt(1) end.",
    Port = open_port({spawn_executable, os:find_executable("erl")},
                     [binary, exit_status, {cd, "/tmp"},
                      {env, [{"MIMIC_TEST_STATE_DIR", binary_to_list(Directory)}]},
                      {args, ["-noshell", "-pa", Ebin, "-eval", Expr]}]),
    await_child(Port).

await_child(Port) ->
    receive
        {Port, {data, _}} -> await_child(Port);
        {Port, {exit_status, 0}} -> {ok, nil};
        {Port, {exit_status, _}} -> {error, <<"private state rejected from another cwd">>}
    after 15000 ->
        port_close(Port),
        {error, <<"cwd regression child timed out">>}
    end.
