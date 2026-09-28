-module(mimic_provider_runtime_ffi).
-export([claim_store/1, release_store/1, protect/1, mutate_runtime/4]).
-include_lib("kernel/include/file.hrl").

%% Atomic local-filesystem ownership primitive. No PID guessing or stale-lock
%% takeover. A hard VM crash leaves the directory locked for operator recovery.
claim_store(Directory) ->
    Owner = self(),
    Ref = make_ref(),
    Guard = spawn(fun() -> claim(Directory, Owner, Ref) end),
    receive
        {Ref, locked} -> {ok, Guard};
        {Ref, failed} -> {error, <<"Runtime store unavailable or already owned">>}
    after 5000 ->
        exit(Guard, kill),
        {error, <<"Runtime store guard timed out">>}
    end.

claim(Directory, Owner, Ref) ->
    Monitor = erlang:monitor(process, Owner),
    Lock = filename:join(Directory, <<".provider-runtime-owner">>),
    File = filename:join(Lock, <<"nonce">>),
    Nonce = crypto:strong_rand_bytes(32),
    case mimic_auth_ffi:validate_directory(Directory) of
        {ok, nil} ->
            case file:make_dir(Lock) of
                ok ->
                    case file:change_mode(Lock, 8#700) =:= ok andalso
                         file:write_file(File, Nonce, [binary, exclusive]) =:= ok andalso
                         file:change_mode(File, 8#600) =:= ok of
                        true ->
                            Owner ! {Ref, locked},
                            receive
                                {release, Owner, Reply} ->
                                    release_owned(Lock, File, Nonce),
                                    Owner ! {Reply, released};
                                {'DOWN', Monitor, process, Owner, _} ->
                                    release_owned(Lock, File, Nonce)
                            end;
                        false -> Owner ! {Ref, failed}
                    end;
                _ -> Owner ! {Ref, failed}
            end;
        _ -> Owner ! {Ref, failed}
    end.

release_store(Guard) ->
    Ref = make_ref(),
    Guard ! {release, self(), Ref},
    receive {Ref, released} -> nil after 5000 -> nil end.

release_owned(Lock, File, Nonce) ->
    case {file:read_link_info(File), file:read_file(File)} of
        {{ok, #file_info{type=regular}}, {ok, Nonce}} ->
            _ = file:delete(File),
            _ = file:del_dir(Lock),
            ok;
        _ -> ok
    end.

%% Trusted callback exceptions must never reach the VM crash logger, which can
%% include arguments containing credentials. Do not return reason/stack values.
protect(Fun) ->
    try {ok, Fun()} catch _:_ -> {error, nil} end.

%% Atomic compare-and-replace filesystem primitive. Every supported runtime
%% write/delete takes this same per-record mutex, including management writes.
%% Stale mutation guards fail closed after a VM crash; no stale lock takeover.
mutate_runtime(Directory, Name, Expected, Contents) ->
    Caller = self(),
    Ref = make_ref(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        %% Deliberately unlinked: cancellation of the requesting actor must not
        %% interrupt the atomic filesystem operation or bypass lock cleanup.
        Result = try mutate_owned(Directory, Name, Expected, Contents)
                 catch _:_ -> {error, <<"Runtime credential mutation failed">>} end,
        Caller ! {Ref, Result}
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Worker, _} ->
            {error, <<"Runtime credential mutation failed">>}
    after 5000 ->
        erlang:demonitor(Monitor, [flush]),
        %% The owner still finishes/cleans the mutation. Timeout/cancellation
        %% never promises rollback; callers may only inspect the current record.
        {error, <<"Runtime credential mutation timed out">>}
    end.

mutate_owned(Directory, Name, Expected, Contents) ->
    Lock = filename:join(Directory, <<".mutation-", Name/binary>>),
    case mimic_auth_ffi:validate_directory(Directory) of
        {ok, nil} ->
            case file:make_dir(Lock) of
                ok ->
                    try
                        _ = file:change_mode(Lock, 8#700),
                        Current = case Expected of
                            none -> match;
                            {some, Value} ->
                                case mimic_auth_ffi:secure_read(Directory, Name) of
                                    {ok, Value} -> match;
                                    _ -> changed
                                end
                        end,
                        case {Current, Contents} of
                            {changed, _} -> {error, <<"Runtime credential changed during refresh">>};
                            {match, {some, Data}} -> mimic_auth_ffi:secure_write(Directory, Name, Data);
                            {match, none} -> mimic_auth_ffi:secure_delete(Directory, Name)
                        end
                    after file:del_dir(Lock) end;
                _ -> {error, <<"Runtime credential mutation unavailable">>}
            end;
        _ -> {error, <<"Runtime credential mutation unavailable">>}
    end.
