-module(mimic_responses_bytes_ffi).
-export([split_line/1]).

%% Only a binary primitive: UTF-8, SSE and lifecycle decisions live in Gleam.
split_line(Bytes) ->
    case binary:match(Bytes, [<<"\r">>, <<"\n">>]) of
        nomatch -> {Bytes, 0, <<>>};
        {At, 1} ->
            <<Prefix:At/binary, Separator, Rest/binary>> = Bytes,
            {Prefix, Separator, Rest}
    end.
