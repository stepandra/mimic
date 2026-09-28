-module(mimic_corpus_ffi).
-export([blake3/1, compress/1, decompress/1, store/3, read/2, ids/1,
         remove_older_than/2, test_root/0]).
-include_lib("kernel/include/file.hrl").

-define(MAX_BYTES, 16777216).

%% CLI processes use argument vectors, never a shell. Temporary data is already
%% redacted by Gleam and is created mode 0600; clean it up even on failure.
blake3(Data) ->
    case with_temp(Data, fun(Path) -> run("b3sum", [Path]) end) of
        {ok, Output} ->
            case re:run(Output, <<"^([0-9a-f]{64}) ">>, [{capture, [1], binary}]) of
                {match, [Hash]} -> {ok, Hash};
                _ -> {error, <<"Invalid b3sum output">>}
            end;
        Error -> Error
    end.

compress(Data) ->
    with_temp(Data, fun(Path) -> run("zstd", ["-q", "-c", "--", Path]) end).

decompress(Data) ->
    case with_temp(Data, fun(Path) -> run("zstd", ["-d", "-q", "-c", "--", Path]) end) of
        {ok, Output} ->
            case unicode:characters_to_binary(Output, utf8, utf8) of
                Output -> {ok, Output};
                _ -> {error, <<"Corpus is not UTF-8">>}
            end;
        Error -> Error
    end.

with_temp(Data, Function) when byte_size(Data) =< ?MAX_BYTES ->
    Path = filename:join(temp_dir(), "mimic-" ++
                         binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16),
                                                           lowercase))),
    case file:open(Path, [write, binary, exclusive]) of
        {ok, File} ->
            try
                case file:change_mode(Path, 8#600) of
                    ok ->
                        case file:write(File, Data) of
                            ok ->
                                ok = file:close(File),
                                Function(Path);
                            {error, Reason} -> {error, io_error(Reason)}
                        end;
                    {error, Reason} -> {error, io_error(Reason)}
                end
            after
                file:close(File),
                file:delete(Path)
            end;
        {error, Reason} -> {error, io_error(Reason)}
    end;
with_temp(_, _) -> {error, <<"Corpus exceeds 16 MiB safety limit">>}.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end.

test_root() ->
    unicode:characters_to_binary(filename:join(
      temp_dir(), "mimic-test-" ++ binary_to_list(
        binary:encode_hex(crypto:strong_rand_bytes(12), lowercase)))).

run(Name, Args) ->
    case os:find_executable(Name) of
        false -> {error, unicode:characters_to_binary(Name ++ " executable unavailable")};
        Executable ->
            Port = open_port({spawn_executable, Executable},
                             [binary, exit_status, {args, Args}]),
            collect(Port, <<>>)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} when byte_size(Acc) + byte_size(Data) =< ?MAX_BYTES ->
            collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {data, _}} ->
            port_close(Port),
            {error, <<"External command output exceeds 16 MiB">>};
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, _}} -> {error, <<"BLAKE3/zstd command failed">>}
    after 30000 ->
        port_close(Port),
        {error, <<"BLAKE3/zstd command timed out">>}
    end.

valid_id(Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    case re:run(Id, <<"^[0-9a-f]{64}$">>) of
        {match, _} -> true;
        _ -> false
    end;
valid_id(_) -> false.

path(Root, Id) ->
    filename:join(Root, <<Id/binary, ".json.zst">>).

store(Root, Id, Data) when is_binary(Root), is_binary(Data) ->
    case valid_id(Id) andalso byte_size(Data) =< ?MAX_BYTES of
        false -> {error, <<"Invalid corpus ID or size">>};
        true ->
            Destination = path(Root, Id),
            case filelib:ensure_dir(Destination) of
                ok -> atomic_store(Destination, Data);
                {error, Reason} -> {error, io_error(Reason)}
            end
    end.

atomic_store(Destination, Data) ->
    Suffix = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Temp = <<Destination/binary, ".", Suffix/binary>>,
    case file:open(Temp, [write, binary, exclusive]) of
        {ok, File} ->
            try
                case file:change_mode(Temp, 8#600) of
                    ok ->
                        case file:write(File, Data) of
                            ok ->
                                case file:sync(File) of
                                    ok ->
                                        ok = file:close(File),
                                        case file:make_link(Temp, Destination) of
                                            ok -> {ok, nil};
                                            {error, eexist} -> verify_existing(Destination, Data);
                                            {error, Reason} -> {error, io_error(Reason)}
                                        end;
                                    {error, Reason} -> {error, io_error(Reason)}
                                end;
                            {error, Reason} -> {error, io_error(Reason)}
                        end;
                    {error, Reason} -> {error, io_error(Reason)}
                end
            after
                file:close(File),
                file:delete(Temp)
            end;
        {error, Reason} -> {error, io_error(Reason)}
    end.

verify_existing(Destination, Data) ->
    case read_regular(Destination) of
        {ok, Data} -> {ok, nil};
        {ok, _} -> {error, <<"Existing corpus object differs from new content">>};
        Error -> Error
    end.

read(Root, Id) ->
    case valid_id(Id) of
        false -> {error, <<"Invalid corpus ID">>};
        true -> read_regular(path(Root, Id))
    end.

%% Check the directory entry, then bound reads on the opened descriptor. Matching
%% device/inode prevents a swapped symlink from escaping the entry check.
read_regular(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size} = Entry}
          when Size =< ?MAX_BYTES ->
            case file:open(Path, [read, binary, raw]) of
                {ok, File} ->
                    try
                        case file:read_file_info(File) of
                            {ok, #file_info{type = regular, size = OpenSize,
                                            inode = Inode, major_device = Device}}
                              when OpenSize =< ?MAX_BYTES,
                                   Inode =:= Entry#file_info.inode,
                                   Device =:= Entry#file_info.major_device ->
                                case file:read(File, ?MAX_BYTES + 1) of
                                    {ok, Data} when byte_size(Data) =< ?MAX_BYTES ->
                                        {ok, Data};
                                    eof -> {ok, <<>>};
                                    {ok, _} -> {error, <<"Corpus exceeds 16 MiB safety limit">>};
                                    {error, Reason} -> {error, io_error(Reason)}
                                end;
                            _ -> {error, <<"Corpus object changed or is not a regular file">>}
                        end
                    after file:close(File) end;
                {error, Reason} -> {error, io_error(Reason)}
            end;
        {ok, #file_info{type = regular}} ->
            {error, <<"Corpus exceeds 16 MiB safety limit">>};
        {ok, _} -> {error, <<"Corpus object is not a regular file">>};
        {error, Reason} -> {error, io_error(Reason)}
    end.

ids(Root) ->
    case file:list_dir(Root) of
        {ok, Names} ->
            Ids = [list_to_binary(filename:rootname(Name, ".json.zst")) ||
                       Name <- Names, filename:extension(Name) =:= ".zst",
                       valid_id(list_to_binary(filename:rootname(Name, ".json.zst")))],
            {ok, lists:sort(Ids)};
        {error, enoent} -> {ok, []};
        {error, Reason} -> {error, io_error(Reason)}
    end.

remove_older_than(Root, Days) when Days > 0 ->
    case ids(Root) of
        {ok, Ids} ->
            Threshold = erlang:system_time(second) - Days * 86400,
            rotate(Root, Ids, Threshold, 0);
        Error -> Error
    end.

rotate(_Root, [], _Threshold, Count) -> {ok, Count};
rotate(Root, [Id | Rest], Threshold, Count) ->
    Path = path(Root, Id),
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = MTime}} when MTime < Threshold ->
            case file:delete(Path) of
                ok -> rotate(Root, Rest, Threshold, Count + 1);
                {error, Reason} -> {error, io_error(Reason)}
            end;
        {ok, _} -> rotate(Root, Rest, Threshold, Count);
        {error, Reason} -> {error, io_error(Reason)}
    end.

io_error(Reason) -> unicode:characters_to_binary(file:format_error(Reason)).
