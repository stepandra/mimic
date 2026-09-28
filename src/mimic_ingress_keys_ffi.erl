%% Filesystem and cryptographic primitives for managed client API keys.
%% No plaintext secret is stored; only salted HMAC verifiers are written.
-module(mimic_ingress_keys_ffi).
-export([store/3, remove/2, verify/2, list/1]).
-include_lib("kernel/include/file.hrl").

store(Dir, Id, Secret) ->
    case validated_dir(Dir) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            Name = filename(Id),
            Final = filename:join(Path, Name),
            global:trans({{?MODULE, Path, Name}, ?MODULE}, fun() ->
                case file:read_link_info(Final) of
                    {ok, _} -> {error, <<"key id already exists">>};
                    {error, enoent} ->
                        Salt = crypto:strong_rand_bytes(32),
                        Hash = crypto:mac(hmac, sha256, Salt, Secret),
                        Data = <<(base64:encode(Salt))/binary, ":",
                                 (base64:encode(Hash))/binary>>,
                        Temp = filename:join(Path, ".key-" ++
                                integer_to_list(erlang:unique_integer([positive]))),
                        case file:open(Temp, [write, binary, exclusive, raw]) of
                            {ok, File} ->
                                %% Chmod before writing; private directory blocks
                                %% inspection even during the temporary file.
                                Result = case file:change_mode(Temp, 8#600) of
                                    ok -> file:write(File, Data);
                                    Err -> Err
                                end,
                                file:close(File),
                                case Result of
                                    ok ->
                                        case file:rename(Temp, Final) of
                                            ok -> {ok, nil};
                                            _ -> file:delete(Temp),
                                                 {error, <<"could not install key">>}
                                        end;
                                    _ -> file:delete(Temp),
                                         {error, <<"could not write key verifier">>}
                                end;
                            _ -> {error, <<"could not create key verifier">>}
                        end;
                    _ -> {error, <<"could not inspect key id">>}
                end
            end)
    end.

remove(Dir, Id) ->
    case validated_dir(Dir) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            Name = filename(Id),
            global:trans({{?MODULE, Path, Name}, ?MODULE}, fun() ->
                case file:delete(filename:join(Path, Name)) of
                    ok -> {ok, nil};
                    {error, enoent} -> {error, <<"key id not found">>};
                    _ -> {error, <<"could not revoke key">>}
                end
            end)
    end.

verify(Dir, Secret) ->
    case validated_dir(Dir) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    Matches = [check(Path, Name, Secret) || Name <- Names,
                        is_key_file(Name)],
                    {ok, lists:any(fun(X) -> X end, Matches)};
                _ -> {error, <<"could not list key registry">>}
            end
    end.

list(Dir) ->
    case validated_dir(Dir) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    Ids = lists:filtermap(fun(Name) ->
                        case is_key_file(Name) of
                            true -> decode_name(Name);
                            false -> false
                        end
                    end, Names),
                    {ok, lists:sort(Ids)};
                _ -> {error, <<"could not list key registry">>}
            end
    end.

check(Path, Name, Secret) ->
    File = filename:join(Path, Name),
    case file:read_link_info(File) of
        {ok, #file_info{type = regular, mode = Mode}} when Mode band 8#777 =:= 8#600 ->
            case file:read_file(File) of
                {ok, Data} ->
                    try
                        [Salt64, Hash64] = binary:split(Data, <<":">>),
                        Salt = base64:decode(Salt64),
                        Hash = base64:decode(Hash64),
                        true = byte_size(Salt) =:= 32 andalso byte_size(Hash) =:= 32,
                        Candidate = crypto:mac(hmac, sha256, Salt, Secret),
                        crypto:hash_equals(Hash, Candidate)
                    catch _:_ -> false
                    end;
                _ -> false
            end;
        _ -> false
    end.

validated_dir(Dir) ->
    Path = binary_to_list(Dir),
    case filename:pathtype(Path) of
        absolute ->
            case file:read_link_info(Path) of
                {ok, #file_info{type = directory, mode = Mode}}
                  when Mode band 8#777 =:= 8#700 ->
                    {ok, Path};
                _ -> {error, <<"key registry needs a precreated 0700 state directory">>}
            end;
        _ -> {error, <<"key registry requires an absolute state directory">>}
    end.

filename(Id) ->
    "key-" ++ binary_to_list(base64:encode(Id, #{mode => urlsafe, padding => false}))
    ++ ".hash".

is_key_file(Name) ->
    lists:prefix("key-", Name) andalso lists:suffix(".hash", Name).

decode_name(Name) ->
    Encoded = lists:sublist(Name, 5, length(Name) - 9),
    try
        Id = base64:decode(list_to_binary(Encoded),
                           #{mode => urlsafe, padding => false}),
        {true, Id}
    catch _:_ -> false
    end.
