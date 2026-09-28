-module(mimic_control_ffi).
-export([put_drift/2, list_drift/1]).
-include_lib("kernel/include/file.hrl").

valid_id(Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                       (C >= $a andalso C =< $f) end, binary_to_list(Id));
valid_id(_) -> false.

index_dir(Directory) ->
    filename:join([Directory, <<"control">>, <<"drift">>]).

put_drift(Directory, Id) ->
    case valid_id(Id) of
        false -> {error, <<"invalid drift report id">>};
        true ->
            Dir = index_dir(Directory),
            case filelib:ensure_dir(filename:join(Dir, <<"marker">>)) of
                ok ->
                    Path = filename:join(Dir, Id),
                    case file:open(Path, [write, exclusive, raw, binary]) of
                        {ok, Io} ->
                            Sync = file:sync(Io),
                            Close = file:close(Io),
                            case {Sync, Close} of
                                {ok, ok} -> {ok, nil};
                                _ -> {error, <<"could not persist drift index">>}
                            end;
                        {error, eexist} ->
                            case file:read_link_info(Path) of
                                {ok, #file_info{type = regular, size = 0}} -> {ok, nil};
                                _ -> {error, <<"invalid drift index entry">>}
                            end;
                        _ -> {error, <<"could not write drift index">>}
                    end;
                _ -> {error, <<"could not create drift index">>}
            end
    end.

list_drift(Directory) ->
    case file:list_dir(index_dir(Directory)) of
        {ok, Names} ->
            Ids = [unicode:characters_to_binary(Name) || Name <- Names],
            case lists:all(fun valid_id/1, Ids) of
                true -> {ok, lists:sort(Ids)};
                false -> {error, <<"invalid drift index">>}
            end;
        {error, enoent} -> {ok, []};
        _ -> {error, <<"could not read drift index">>}
    end.
