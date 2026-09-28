-module(mimic_auth_ffi).
-export([secure_read/2, secure_read_quota/1, secure_write/3, secure_list/1, secure_delete/2, validate_directory/1,
         get_env/1, now_ms/0, strong_random_bytes/1, sha256/1]).
-include_lib("kernel/include/file.hrl").

strong_random_bytes(Size) -> crypto:strong_rand_bytes(Size).
sha256(Input) -> crypto:hash(sha256, Input).
now_ms() -> erlang:system_time(millisecond).

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, <<"Missing OAuth configuration environment variable">>};
        "" -> {error, <<"Empty OAuth configuration environment variable">>};
        Value -> {ok, list_to_binary(Value)}
    end.

validate_directory(Directory) ->
    try
        ok = private_directory(binary_to_list(Directory)),
        {ok, nil}
    catch _:_ -> {error, <<"Auth state directory must already exist as a private 0700 directory">>} end.

secure_list(Directory) ->
    try
        Dir = binary_to_list(Directory),
        ok = private_directory(Dir),
        {ok, Names} = file:list_dir(Dir),
        Encoded = [list_to_binary(string:slice(Name, 11, length(Name) - 16)) ||
            Name <- Names,
            lists:prefix("credential-", Name),
            lists:suffix(".json", Name),
            length(Name) > 16],
        {ok, Encoded}
    catch _:_ -> {error, <<"Credential listing failed">>} end.

secure_delete(Directory, Name) ->
    try
        Dir = binary_to_list(Directory),
        File = filename:join(Dir, binary_to_list(Name)),
        ok = private_directory(Dir),
        ok = private_file(File),
        ok = file:delete(File),
        {ok, nil}
    catch _:_ -> {error, <<"Credential delete failed">>} end.

%% This backend intentionally does not implement age encryption. Plaintext is
%% only allowed in an operator-selected private directory. Never include paths
%% or contents in returned errors (paths can encode sensitive identifiers).
secure_read(Directory, Name) ->
    try
        Dir = binary_to_list(Directory),
        File = filename:join(Dir, binary_to_list(Name)),
        ok = private_directory(Dir),
        ok = private_file(File),
        case file:read_file(File) of
            {ok, Bytes} -> {ok, Bytes};
            _ -> {error, <<"Credential read failed">>}
        end
    catch _:_ -> {error, <<"Credential read failed">>} end.

secure_read_quota(Directory) ->
    try
        Dir = binary_to_list(Directory),
        File = filename:join(Dir, "quota-ledger.json"),
        ok = private_directory(Dir),
        case file:read_link_info(File) of
            {error, enoent} -> {error, <<"Quota ledger missing">>};
            _ ->
                ok = private_file(File),
                case file:read_file(File) of
                    {ok, Bytes} -> {ok, Bytes};
                    _ -> {error, <<"Quota ledger read failed">>}
                end
        end
    catch _:_ -> {error, <<"Quota ledger read failed">>} end.

secure_write(Directory, Name, Contents) ->
    try
        Dir = binary_to_list(Directory),
        File = filename:join(Dir, binary_to_list(Name)),
        ok = private_directory(Dir),
        ok = target_available(File),
        Tmp = filename:join(Dir, ".pending-" ++
            binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(24)))),
        case file:open(Tmp, [write, binary, exclusive, raw]) of
            {ok, Fd} ->
                try
                    ok = file:change_mode(Tmp, 8#600),
                    ok = file:write(Fd, Contents),
                    ok = file:sync(Fd),
                    ok = file:close(Fd),
                    ok = target_available(File),
                    ok = file:rename(Tmp, File),
                    ok = sync_directory(Dir),
                    {ok, nil}
                catch _:_ ->
                    _ = file:close(Fd),
                    _ = file:delete(Tmp),
                    {error, <<"Credential write failed">>}
                end;
            _ -> {error, <<"Credential write failed">>}
        end
    catch _:_ -> {error, <<"Credential write failed">>} end.

private_directory(Dir) ->
    case filename:pathtype(Dir) of
        absolute -> ok;
        _ -> error(not_absolute)
    end,
    case file:read_link_info(Dir) of
        {ok, #file_info{type = directory, mode = Mode, uid = Uid}} ->
            true = (Mode band 8#777) =:= 8#700,
            true = Uid =:= current_uid(),
            ok;
        _ -> error(insecure_directory)
    end.

private_file(File) ->
    case file:read_link_info(File) of
        {ok, #file_info{type = regular, mode = Mode, uid = Uid}} ->
            true = (Mode band 8#777) =:= 8#600,
            true = Uid =:= current_uid(),
            ok;
        _ -> error(insecure_file)
    end.

target_available(File) ->
    case file:read_link_info(File) of
        {error, enoent} -> ok;
        {ok, _} -> private_file(File);
        _ -> error(target_unavailable)
    end.

%% file:sync on a directory is not portable across BEAM-supported hosts.
%% File data is synced before rename; directory durability on crash remains
%% platform-dependent.
sync_directory(_Dir) -> ok.

current_uid() ->
    %% A shipment may launch from a directory owned by another user. Query
    %% the effective UID, not the ownership of "." or HOME. No shell or
    %% interpolated input crosses this OS boundary; failure is fail-closed.
    Port = open_port({spawn_executable, "/usr/bin/id"},
                     [binary, exit_status, {args, ["-u"]}]),
    receive
        {Port, {data, Output}} ->
            Uid = binary_to_integer(string:trim(Output)),
            receive
                {Port, {exit_status, 0}} -> Uid
            after 5000 -> error(uid_lookup_timeout)
            end
    after 5000 -> error(uid_lookup_timeout)
    end.
