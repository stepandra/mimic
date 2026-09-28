-module(mimic_f_test_ffi).
-export([dir/0, sign_review/3, sign_abandon/2, sign_rollback/1,
         remove_active/2, replace_active/3, remove_artifact/2,
         seed_registry/4, poison_artifact/2, symlink_state/1,
         crash_advance/3, clear_effect/2, drive_deadline/0,
         fresh_load/2, corrupt_evidence/2]).
dir() ->
    <<"build/f-tests/", (integer_to_binary(erlang:unique_integer([positive])))/binary,
      "-", (binary:encode_hex(crypto:strong_rand_bytes(4), lowercase))/binary>>.

key(Variable) ->
    Key = binary:encode_hex(crypto:strong_rand_bytes(32), lowercase),
    os:putenv(Variable, binary_to_list(Key)),
    Key.
sign_review(Id, Reviewer, Candidate) ->
    sign(key("MIMIC_REVIEW_KEY"), <<Id/binary, 0, Reviewer/binary, 0, Candidate/binary>>).
sign_abandon(Id, Reason) ->
    sign(key("MIMIC_REVIEW_KEY"), <<Id/binary, 0, "abandon", 0, Reason/binary>>).
sign_rollback(Provider) ->
    sign(key("MIMIC_PROMOTION_KEY"), <<Provider/binary, 0, "rollback">>).
sign(Key, Message) ->
    binary:encode_hex(crypto:mac(hmac, sha256, Key, Message), lowercase).
hash(Value) -> binary:encode_hex(crypto:hash(sha256, Value), lowercase).
remove_active(Dir, Provider) ->
    file:delete(filename:join([Dir, "active", hash(Provider)])),
    nil.
replace_active(Dir, Provider, Owner) ->
    Path = filename:join([Dir, "active", hash(Provider)]),
    file:write_file(Path, term_to_binary(Owner)),
    nil.
remove_artifact(Dir, Digest) ->
    file:delete(filename:join([Dir, "artifacts", Digest])),
    nil.
poison_artifact(Dir, Content) ->
    Path = filename:join([Dir, "artifacts", hash(Content)]),
    file:write_file(Path, <<"partial">>),
    nil.
seed_registry(Dir, Provider, Current, Previous) ->
    Path = filename:join([Dir, "registry", hash(Provider)]),
    filelib:ensure_dir(Path),
    file:write_file(Path, term_to_binary({registry, Current, Previous})),
    nil.
symlink_state(Dir) ->
    Link = <<Dir/binary, "-link">>,
    ok = file:make_symlink(filename:absname(Dir), Link),
    Link.
crash_advance(Dir, Id, Budget) ->
    {Pid, Ref} = spawn_monitor(fun() ->
        'mimic@workshop':advance(Dir, Id, Budget,
            fun(_, _) -> erlang:exit(self(), kill) end)
    end),
    receive
        {'DOWN', Ref, process, Pid, killed} -> nil
    after 5000 ->
        erlang:exit(Pid, kill),
        erlang:error(crash_fixture_timed_out)
    end.
clear_effect(Dir, Id) ->
    %% Test-only simulation of operator action after confirming DOWN.
    ok = file:del_dir(filename:join([Dir, "effects", hash(Id)])),
    nil.
fresh_load(Dir, Id) ->
    Erl = os:find_executable("erl"),
    BeamDir = filename:dirname(code:which('mimic@workshop')),
    %% The eval expression is fixed. State identifiers travel as environment
    %% values, never interpolated into shell or Erlang source.
    Eval = "D=list_to_binary(os:getenv(\"MIMIC_F_DIR\")), "
           "I=list_to_binary(os:getenv(\"MIMIC_F_ID\")), "
           "case 'mimic@workshop':load(D,I) of {ok,_}->halt(0); _->halt(1) end.",
    Port = open_port({spawn_executable, Erl},
        [exit_status, use_stdio, stderr_to_stdout, binary,
         {args, ["-noshell", "-noinput", "-pa", BeamDir, "-eval", Eval]},
         {env, [{"MIMIC_F_DIR", binary_to_list(Dir)},
                {"MIMIC_F_ID", binary_to_list(Id)}]}]),
    fresh_result(Port).
fresh_result(Port) ->
    receive
        {Port, {data, _}} -> fresh_result(Port);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, _}} -> false
    after 10000 ->
        try port_close(Port) catch _:_ -> ok end,
        false
    end.
corrupt_evidence(Dir, Id) ->
    Path = filename:join([Dir, "runs", hash(Id)]),
    {ok, Bytes} = file:read_file(Path),
    Run = binary_to_term(Bytes, [safe]),
    Bad = {evidence, invalid_stage, hash(<<"synthetic">>), true, none, <<"synthetic">>},
    ok = file:write_file(Path, term_to_binary(setelement(6, Run, [Bad]))),
    nil.
drive_deadline() ->
    Yes = os:find_executable("yes"),
    Port = open_port({spawn_executable, Yes},
        [exit_status, binary, use_stdio, stderr_to_stdout]),
    mimic_drive_ffi:wait(Port, erlang:monotonic_time(millisecond) + 50).
