-module(mimic_watch_ffi).
-include_lib("kernel/include/file.hrl").
-export([observe/4, ready/3, ack/3]).

%% Queued observations survive process restarts. An exclusive lock serializes
%% updates across VMs; a stale lock fails closed and requires operator recovery.
path(Dir, Config) ->
    {watch, Package, Provider, _, _} = Config,
    Hash = binary:encode_hex(crypto:hash(sha256, <<Provider/binary, 0, Package/binary>>), lowercase),
    filename:join([Dir, "watch", Hash]).
lock(Dir, Fun) ->
    case filelib:ensure_dir(filename:join(Dir, "watch/x")) of
        ok ->
            case trusted(Dir) of
                true ->
                    case {file:change_mode(Dir, 8#700),
                          file:change_mode(filename:join(Dir, "watch"), 8#700)} of
                        {ok, ok} ->
                            Lock = filename:join(Dir, ".watch-lock"),
                            case file:make_dir(Lock) of
                                ok -> try Fun() after file:del_dir(Lock) end;
                                {error, eexist} -> {error, <<"watch locked; inspect before recovery">>};
                                {error, _} -> {error, <<"watch lock failure">>}
                            end;
                        _ -> {error, <<"watch state directory not private">>}
                    end;
                false -> {error, <<"untrusted watch state directory">>}
            end;
        _ -> {error, <<"watch state directory unavailable">>}
    end.
trusted(Dir) ->
    case {file:read_link_info(Dir), file:read_link_info(filename:join(Dir, "watch"))} of
        {{ok, #file_info{type = directory}}, {ok, #file_info{type = directory}}} -> true;
        _ -> false
    end.
read(Path) ->
    Dir = filename:dirname(filename:dirname(Path)),
    case trusted(Dir) of
        false -> {error, <<"untrusted watch state directory">>};
        true ->
            case file:read_link_info(Path) of
                {ok, #file_info{type = regular}} ->
                    case file:read_file(Path) of
                        {ok, Bytes} ->
                            try {ok, binary_to_term(Bytes, [safe])}
                            catch _:_ -> {error, <<"invalid watch state">>} end;
                        _ -> {error, <<"watch state unreadable">>}
                    end;
                {error, enoent} -> {error, <<"no pending release">>};
                _ -> {error, <<"watch state unreadable">>}
            end
    end.
write(Path, Term) ->
    Tmp = <<Path/binary, ".", (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary>>,
    case file:open(Tmp, [write, binary, exclusive, raw]) of
        {ok, Io} ->
            M = file:change_mode(Tmp, 8#600),
            W = file:write(Io, term_to_binary(Term)),
            S = file:sync(Io),
            C = file:close(Io),
            case {M, W, S, C} of
                {ok, ok, ok, ok} ->
                    case file:rename(Tmp, Path) of
                        ok -> {ok, Term};
                        _ -> file:delete(Tmp), {error, <<"watch rename failed">>}
                    end;
                _ -> file:delete(Tmp), {error, <<"watch write failed">>}
            end;
        _ -> {error, <<"watch temporary file failed">>}
    end.
observe(Dir, {watch, Package, Provider, _, Debounce} = Config, Version, Now)
    when is_binary(Version), byte_size(Version) > 0, is_integer(Now), Now >= 0, Debounce > 0 ->
    lock(Dir, fun() ->
        Path = path(Dir, Config),
        case read(Path) of
            {ok, {pending, Package, Provider, Version, _} = Same} -> {ok, Same};
            {ok, {delivered, Version}} -> {error, <<"release already queued">>};
            _ -> write(Path, {pending, Package, Provider, Version, Now + Debounce})
        end
    end);
observe(_, _, _, _) -> {error, <<"invalid watch observation">>}.
ready(Dir, Config, Now) ->
    case read(path(Dir, Config)) of
        {ok, {pending, _, _, _, At} = Pending} when Now >= At -> {ok, Pending};
        {ok, _} -> {error, <<"release is still debouncing">>};
        Error -> Error
    end.
ack(Dir, Config, Version) ->
    lock(Dir, fun() ->
        Path = path(Dir, Config),
        {watch, Package, Provider, _, _} = Config,
        case read(Path) of
            {ok, {pending, Package, Provider, Version, _}} ->
                case write(Path, {delivered, Version}) of
                    {ok, _} -> {ok, nil};
                    Error -> Error
                end;
            _ -> {error, <<"newer release is pending">>}
        end
    end).
