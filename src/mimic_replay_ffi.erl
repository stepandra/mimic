-module(mimic_replay_ffi).
-export([uuid/0, timestamp_ms/0, exchange/5]).

%% Only OS/crypto/socket primitives live here. No HTTP client library rewrites
%% the request frame supplied by Gleam.
uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    unicode:characters_to_binary(
      io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                    [A, B, C band 16#fff, (D band 16#3fff) bor 16#8000, E])).

timestamp_ms() -> integer_to_binary(erlang:system_time(millisecond)).

exchange(Tls, HostBin, Port, Frame, Method) ->
    Host = binary_to_list(HostBin),
    Started = erlang:monotonic_time(millisecond),
    try
        case connect(Tls, Host, Port) of
            {ok, Socket} ->
                try
                    case send(Tls, Socket, Frame) of
                        ok ->
                            case recv(Tls, Socket) of
                                {ok, First} ->
                                    Ttft = erlang:monotonic_time(millisecond) - Started,
                                    case receive_frame(Tls, Socket, First, 0, Started + 15000, Method) of
                                        {ok, Raw} ->
                                            case unicode:characters_to_list(Raw, utf8) of
                                                Chars when is_list(Chars) -> {ok, {Raw, Ttft}};
                                                _ -> {error, <<"Non-UTF-8 HTTP response unsupported">>}
                                            end;
                                        Error -> Error
                                    end;
                                {error, Reason} -> {error, reason(Reason)}
                            end;
                        {error, Reason} -> {error, reason(Reason)}
                    end
                after close(Tls, Socket) end;
            {error, Reason} -> {error, reason(Reason)}
        end
    catch _:Unexpected -> {error, reason(Unexpected)} end.

connect(false, Host, Port) ->
    gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw},
                                 {send_timeout, 5000}], 5000);
connect(true, Host, Port) ->
    application:ensure_all_started(ssl),
    ssl:connect(Host, Port,
                [binary, {active, false}, {verify, verify_peer},
                 {send_timeout, 5000},
                 {cacerts, public_key:cacerts_get()},
                 {server_name_indication, Host},
                 {customize_hostname_check,
                  [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
                 {alpn_advertised_protocols, [<<"http/1.1">>]}], 5000).

send(false, Socket, Frame) -> gen_tcp:send(Socket, Frame);
send(true, Socket, Frame) -> ssl:send(Socket, Frame).
recv(Tls, Socket) -> recv(Tls, Socket, 5000).
recv(false, Socket, Timeout) -> gen_tcp:recv(Socket, 0, Timeout);
recv(true, Socket, Timeout) -> ssl:recv(Socket, 0, Timeout).
close(false, Socket) -> gen_tcp:close(Socket);
close(true, Socket) -> ssl:close(Socket).

receive_frame(_Tls, _Socket, Raw, _Interims, _Deadline, _Method) when byte_size(Raw) > 2097152 ->
    {error, <<"Response exceeds 2 MiB">>};
receive_frame(_Tls, _Socket, _Raw, Interims, _Deadline, _Method) when Interims > 16 ->
    {error, <<"Too many interim HTTP responses">>};
receive_frame(Tls, Socket, Raw, Interims, Deadline, Method) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
      true -> {error, <<"Response deadline exceeded">>};
      false -> receive_frame_before_deadline(Tls, Socket, Raw, Interims, Deadline, Method)
    end.

receive_frame_before_deadline(Tls, Socket, Raw, Interims, Deadline, Method) ->
    case frame_length(Raw, Method) of
        {interim, Length} ->
            %% Interim responses are never the result. The remaining bytes may
            %% already contain the final response, or require another receive.
            Rest = binary:part(Raw, Length, byte_size(Raw) - Length),
            receive_frame(Tls, Socket, Rest, Interims + 1, Deadline, Method);
        {ok, Length, plain} when byte_size(Raw) >= Length ->
            {ok, binary:part(Raw, 0, Length)};
        {ok, Length, {chunked, Body, Trailers, Start}} when byte_size(Raw) >= Length ->
            Head = binary:part(Raw, 0, Start - 4),
            case Trailers of
                <<>> -> {ok, <<Head/binary, "\r\n\r\n", Body/binary>>};
                _ -> {ok, <<Head/binary, "\r\n", Trailers/binary, "\r\n\r\n", Body/binary>>}
            end;
        {ok, _Length, _} -> receive_more(Tls, Socket, Raw, Interims, Deadline, Method);
        incomplete -> receive_more(Tls, Socket, Raw, Interims, Deadline, Method);
        close_delimited -> receive_more(Tls, Socket, Raw, Interims, Deadline, Method);
        {error, Reason} -> {error, Reason}
    end.

receive_more(Tls, Socket, Raw, Interims, Deadline, Method) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
      true -> {error, <<"Response deadline exceeded">>};
      false -> receive_more_with_timeout(Tls, Socket, Raw, Interims, Deadline, Method, min(5000, Remaining))
    end.

receive_more_with_timeout(Tls, Socket, Raw, Interims, Deadline, Method, Timeout) ->
    case recv(Tls, Socket, Timeout) of
        {ok, Next} when byte_size(Raw) + byte_size(Next) > 2097152 ->
            {error, <<"Response exceeds 2 MiB">>};
        {ok, Next} -> receive_frame(Tls, Socket, <<Raw/binary, Next/binary>>, Interims, Deadline, Method);
        {error, closed} ->
            case frame_length(Raw, Method) of
                close_delimited -> {ok, Raw};
                {ok, Length, plain} when byte_size(Raw) >= Length ->
                    {ok, binary:part(Raw, 0, Length)};
                _ -> {error, <<"Truncated HTTP response">>}
            end;
        {error, Reason} -> {error, reason(Reason)}
    end.

frame_length(Raw, Method) ->
    case binary:match(Raw, <<"\r\n\r\n">>) of
        nomatch when byte_size(Raw) > 65536 -> {error, <<"Response headers exceed 64 KiB">>};
        nomatch -> incomplete;
        {At, 4} when At + 4 > 65536 -> {error, <<"Response headers exceed 64 KiB">>};
        {At, 4} ->
            Header = binary:part(Raw, 0, At),
            Lines = binary:split(Header, <<"\r\n">>, [global]),
            case Lines of
                [Status | Fields] ->
                    case {status_code(Status), lists:all(fun valid_header_field/1, Fields)} of
                        {{ok, Code}, true} -> framing(Fields, At + 4, Code, Method, Raw);
                        {{error, Reason}, _} -> {error, Reason};
                        _ -> {error, <<"Malformed response header">>}
                    end;
                _ -> {error, <<"Malformed HTTP response">>}
            end
    end.

status_code(Status) ->
    case binary:split(Status, <<" ">>, [global]) of
        [<<"HTTP/1.1">>, <<A, B, C>> | _] when A >= $1, A =< $5,
                                             B >= $0, B =< $9,
                                             C >= $0, C =< $9 ->
            {ok, (A - $0) * 100 + (B - $0) * 10 + C - $0};
        _ -> {error, <<"Unsupported HTTP response status line">>}
    end.

valid_header_field(Field) ->
    case binary:split(Field, <<":">>) of
        [Name, _Value] -> valid_token(Name);
        _ -> false
    end.

framing(Fields, Start, Status, Method, Raw) ->
    Values = [binary:split(F, <<":">>) || F <- Fields],
    Transfer = [lower(trim(V)) || [K, V] <- Values,
                lower(K) =:= <<"transfer-encoding">>],
    Encoding = [lower(trim(V)) || [K, V] <- Values,
                lower(K) =:= <<"content-encoding">>],
    Lengths = [trim(V) || [K, V] <- Values,
               lower(K) =:= <<"content-length">>],
    UnsupportedEncoding = not lists:all(fun(E) -> E =:= <<"identity">> end, Encoding),
    case {Transfer, Lengths} of
        {[_ | _], [_ | _]} ->
            {error, <<"Ambiguous Transfer-Encoding and Content-Length">>};
        {_, _} when Status =:= 101 ->
            {error, <<"HTTP protocol upgrade unsupported">>};
        {_, _} when Status < 200 ->
            {interim, Start};
        {_, _} when Method =:= <<"HEAD">>; Status =:= 204; Status =:= 304 ->
            {ok, Start, plain};
        _ when UnsupportedEncoding ->
            {error, <<"Encoded response body unsupported">>};
        {[<<"chunked">>], []} ->
            case scan_chunks(Raw, Start, [], 0) of
                {ok, End, Body, Trailers} -> {ok, End, {chunked, Body, Trailers, Start}};
                Other -> Other
            end;
        {[_ | _], _} -> {error, <<"Unsupported Transfer-Encoding or ambiguous response framing">>};
        {[], [N]} ->
            case valid_decimal(N) of
                false -> {error, <<"Invalid response Content-Length">>};
                true ->
                    I = binary_to_integer(N),
                    if I =< 2097152 -> {ok, Start + I, plain};
                       true -> {error, <<"Invalid response Content-Length">>}
                    end
            end;
        {[], []} ->
            close_delimited;
        _ -> {error, <<"Duplicate response Content-Length">>}
    end.

%% Byte-indexed framing belongs beside the raw socket. The body is only
%% converted to a Gleam UTF-8 String after all chunk boundaries are removed.
scan_chunks(Raw, Pos, Chunks, Total) ->
    case line(Raw, Pos) of
        incomplete -> incomplete;
        {error, Reason} -> {error, Reason};
        {ok, SizeLine, DataStart} ->
            [RawHex | Extensions] = chunk_parts(SizeLine, false, [], []),
            Hex = trim_bws(RawHex),
            case valid_hex(Hex) andalso valid_extensions(Extensions) of
                false -> {error, <<"Invalid chunk size or extension">>};
                true ->
                    Size = binary_to_integer(Hex, 16),
                    case {Size, Total + Size =< 2097152} of
                        {_, false} -> {error, <<"Decoded body exceeds 2 MiB">>};
                        {0, true} -> scan_trailers(Raw, DataStart, Chunks);
                        {_, true} ->
                            Next = DataStart + Size,
                            case byte_size(Raw) >= Next + 2 of
                                false -> incomplete;
                                true ->
                                    case binary:part(Raw, Next, 2) of
                                        <<"\r\n">> ->
                                            Chunk = binary:part(Raw, DataStart, Size),
                                            scan_chunks(Raw, Next + 2, [Chunk | Chunks], Total + Size);
                                        _ -> {error, <<"Missing chunk terminator">>}
                                    end
                            end
                    end
            end
    end.

%% Semicolons inside quoted extension values are data, not separators.
chunk_parts(<<>>, _Quoted, Part, Parts) ->
    lists:reverse([list_to_binary(lists:reverse(Part)) | Parts]);
chunk_parts(<<$\\, C, Rest/binary>>, true, Part, Parts) ->
    chunk_parts(Rest, true, [C, $\\ | Part], Parts);
chunk_parts(<<$", Rest/binary>>, Quoted, Part, Parts) ->
    chunk_parts(Rest, not Quoted, [$" | Part], Parts);
chunk_parts(<<$;, Rest/binary>>, false, Part, Parts) ->
    chunk_parts(Rest, false, [], [list_to_binary(lists:reverse(Part)) | Parts]);
chunk_parts(<<C, Rest/binary>>, Quoted, Part, Parts) ->
    chunk_parts(Rest, Quoted, [C | Part], Parts).

scan_trailers(Raw, Pos, Chunks) ->
    case line(Raw, Pos) of
        incomplete -> incomplete;
        {error, Reason} -> {error, Reason};
        {ok, <<>>, End} ->
            %% End is the byte immediately following the final CRLF.
            {ok, End, iolist_to_binary(lists:reverse(Chunks)), <<>>};
        {ok, First, Next} ->
            scan_trailer_lines(Raw, Next, [First], Chunks, Next - Pos)
    end.

scan_trailer_lines(_Raw, _Pos, _Lines, _Chunks, Count) when Count > 65536 ->
    {error, <<"Response trailers exceed 64 KiB">>};
scan_trailer_lines(Raw, Pos, Lines, Chunks, Count) ->
    case line(Raw, Pos) of
        incomplete when Count + byte_size(Raw) - Pos > 65536 ->
            {error, <<"Response trailers exceed 64 KiB">>};
        incomplete -> incomplete;
        {error, Reason} -> {error, Reason};
        {ok, _Line, End} when Count + End - Pos > 65536 ->
            {error, <<"Response trailers exceed 64 KiB">>};
        {ok, <<>>, End} ->
            case lists:all(fun valid_trailer/1, Lines) of
                true ->
                    Trailer = iolist_to_binary(lists:join(<<"\r\n">>, lists:reverse(Lines))),
                    {ok, End, iolist_to_binary(lists:reverse(Chunks)), Trailer};
                false -> {error, <<"Invalid response trailer">>}
            end;
        {ok, Line, Next} -> scan_trailer_lines(Raw, Next, [Line | Lines], Chunks, Count + Next - Pos)
    end.

line(Raw, Pos) when Pos > byte_size(Raw) -> incomplete;
line(Raw, Pos) ->
    case binary:match(Raw, <<"\r\n">>, [{scope, {Pos, byte_size(Raw) - Pos}}]) of
        nomatch when byte_size(Raw) - Pos > 65536 ->
            {error, <<"HTTP framing line exceeds 64 KiB">>};
        nomatch -> incomplete;
        {At, 2} when At - Pos > 65536 ->
            {error, <<"HTTP framing line exceeds 64 KiB">>};
        {At, 2} -> {ok, binary:part(Raw, Pos, At - Pos), At + 2}
    end.

valid_hex(<<>>) -> false;
valid_hex(Bin) ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                        (C >= $a andalso C =< $f) orelse
                        (C >= $A andalso C =< $F) end, binary_to_list(Bin)).
valid_decimal(<<>>) -> false;
valid_decimal(Bin) ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)).
valid_extensions(Extensions) ->
    lists:all(fun valid_extension/1, Extensions).
valid_extension(Extension) ->
    case binary:split(Extension, <<"=">>) of
        [Name] -> valid_token(trim_bws(Name));
        [Name, RawValue] ->
            Value = trim_bws(RawValue),
            valid_token(trim_bws(Name)) andalso
              case Value of
                  <<$", Rest/binary>> -> quoted_extension(Rest);
                  _ -> valid_token(Value)
              end
    end.
trim_bws(Bin) ->
    list_to_binary(lists:reverse(drop_bws(lists:reverse(drop_bws(binary_to_list(Bin)))))).
drop_bws([C | Rest]) when C =:= 32; C =:= 9 -> drop_bws(Rest);
drop_bws(Rest) -> Rest.
quoted_extension(<<$">>) -> true;
quoted_extension(<<>>) -> false;
quoted_extension(<<$\\, C, Rest/binary>>) when C =:= 9; C >= 32, C =< 126 ->
    quoted_extension(Rest);
quoted_extension(<<C, Rest/binary>>) when C =:= 9; C =:= 32;
                                          C >= 33, C =< 126, C =/= $", C =/= $\\ ->
    quoted_extension(Rest);
quoted_extension(_) -> false.
valid_token(<<>>) -> false;
valid_token(Bin) ->
    lists:all(fun(C) ->
        (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        lists:member(C, "!#$%&'*+-.^_`|~")
    end, binary_to_list(Bin)).
valid_trailer(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, _Value] when Name =/= <<>> ->
            valid_token(Name) andalso
              not lists:member(lower(Name),
                [<<"content-length">>, <<"transfer-encoding">>, <<"host">>,
                 <<"authorization">>, <<"content-type">>, <<"content-encoding">>,
                 <<"content-range">>, <<"connection">>, <<"trailer">>]);
        _ -> false
    end.

lower(Bin) -> list_to_binary(string:lowercase(binary_to_list(Bin))).
trim(Bin) -> list_to_binary(string:trim(binary_to_list(Bin))).
reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("Socket error: ~p", [Reason])).
