-module(mimic_live_ffi).
-include_lib("kernel/include/file.hrl").
-export([now_ms/0, sha256/1, read_regular/3]).

%% OS/crypto primitives only. Admission, HTTP, budgets and lifetime are Gleam.
now_ms() -> erlang:monotonic_time(millisecond).
sha256(Bytes) -> binary:encode_hex(crypto:hash(sha256, Bytes), lowercase).

%% Explicit CLI fixture inputs, never HOME/environment/credential discovery.
%% The opened descriptor is rechecked; no unbounded read_file or FIFO read.
read_regular(Path, Limit, Private) when Limit > 0, Limit =< 1048576 ->
    Name = binary_to_list(Path),
    case file:read_link_info(Name) of
        {ok, Before = #file_info{type = regular, size = Size, mode = Mode}}
          when Size =< Limit, (not Private orelse Mode band 8#077 =:= 0) ->
            case file:open(Name, [read, binary, raw]) of
                {ok, Fd} ->
                    Result = case file:read_file_info(Fd) of
                        {ok, #file_info{type = regular, inode = Inode,
                                       major_device = Dev, size = Size2,
                                       mode = Mode2}}
                          when Inode =:= Before#file_info.inode,
                               Dev =:= Before#file_info.major_device,
                               Size2 =< Limit,
                               (not Private orelse Mode2 band 8#077 =:= 0) ->
                            case file:read(Fd, Limit + 1) of
                                {ok, Bytes} when byte_size(Bytes) =< Limit ->
                                    utf8(Bytes);
                                eof -> {ok, <<>>};
                                _ -> invalid()
                            end;
                        _ -> invalid()
                    end,
                    _ = file:close(Fd),
                    Result;
                _ -> invalid()
            end;
        _ -> invalid()
    end;
read_regular(_, _, _) -> invalid().

utf8(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Value when is_binary(Value) -> {ok, Value};
        _ -> invalid()
    end.
invalid() -> {error, <<"live_fixture_file_invalid">>}.
