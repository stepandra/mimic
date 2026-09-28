%% Socket/TLS primitives for the mist ingress. Routing, keys, and policy live
%% in Gleam; this module only frames one explicit HTTP/1.1 upstream connection.
-module(mimic_ingress_ffi).
-export([valid_origin/1, host_header/1, secure_equal/2, utf8_prefix/1, open/5,
         open_preserve/5, next/1, close/1, register/2, stop/1,
         environment/1, now_ms/0, new_session_id/0, wait_forever/0,
         split_head/1, split_line/1]).

-define(MAX_HEAD, 65536).
-define(REGISTRY, mimic_ingress_local_servers).

valid_origin(Origin) ->
    case parse_origin(Origin) of
        {ok, _, _, _} -> true;
        _ -> false
    end.

host_header(Origin) ->
    case parse_origin(Origin) of
        {ok, Scheme, Host, Port} -> {ok, host_header(Scheme, Host, Port)};
        Error -> Error
    end.

host_header(<<"http">>, Host, 80) -> Host;
host_header(<<"https">>, Host, 443) -> Host;
host_header(_, Host, Port) ->
    <<Host/binary, ":", (integer_to_binary(Port))/binary>>.

parse_origin(Origin) ->
    try
        Uri = uri_string:parse(Origin),
        Scheme = maps:get(scheme, Uri),
        Host = maps:get(host, Uri),
        true = (maps:get(path, Uri, <<>>) =:= <<>> orelse
                maps:get(path, Uri, <<>>) =:= <<"/">>),
        false = maps:is_key(userinfo, Uri),
        false = maps:is_key(query, Uri),
        false = maps:is_key(fragment, Uri),
        true = (Host =/= <<>>),
        true = (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>),
        Port = maps:get(port, Uri, case Scheme of
                                      <<"http">> -> 80;
                                      _ -> 443
                                  end),
        true = is_integer(Port) andalso Port > 0 andalso Port =< 65535,
        %% Plaintext credentials must never leave the local host.
        true = (Scheme =:= <<"https">> orelse
                Host =:= <<"127.0.0.1">> orelse
                Host =:= <<"localhost">> orelse Host =:= <<"[::1]">>),
        {ok, Scheme, Host, Port}
    catch _:_ -> {error, <<"invalid upstream origin">>}
    end.

secure_equal(A, B) when is_binary(A), is_binary(B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B)).

utf8_prefix(Data) ->
    case unicode:characters_to_binary(Data, utf8, utf8) of
        Complete when is_binary(Complete) -> {ok, {Complete, <<>>}};
        {incomplete, Complete, Tail} when byte_size(Tail) < 4 ->
            {ok, {Complete, Tail}};
        _ -> {error, <<"invalid UTF-8 stream">>}
    end.

open(Origin, Target, Method, Headers, Body) ->
    open_mode(Origin, Target, Method, Headers, Body, false).

open_preserve(Origin, Target, Method, Headers, Body) ->
    open_mode(Origin, Target, Method, Headers, Body, true).

open_mode(Origin, Target, Method, Headers, Body, Preserve) ->
    case parse_origin(Origin) of
        {error, _} = Error -> Error;
        {ok, Scheme, Host, Port} ->
            case safe_line(Target) andalso byte_size(Target) > 0 andalso
                 safe_line(Method)
                 andalso binary:at(Target, 0) =:= $/
                 andalso lists:all(fun({Name, Value}) ->
                     safe_line(Name) andalso safe_line(Value)
                 end, Headers) andalso
                 (not Preserve orelse valid_preserved_headers(Headers, Body)) of
                false -> {error, <<"invalid request target or header">>};
                true ->
                    case connect(Scheme, Host, Port) of
                        {ok, Transport, Socket} ->
                            HostHeader = host_header(Scheme, Host, Port),
                            Encoded = [[Name, <<": ">>, Value, <<"\r\n">>]
                                       || {Name, Value} <- Headers],
                            Request = case Preserve of
                                true -> [Method, <<" ">>, Target,
                                         <<" HTTP/1.1\r\n">>, Encoded,
                                         <<"\r\n">>, Body];
                                false -> [Method, <<" ">>, Target,
                                          <<" HTTP/1.1\r\nHost: ">>, HostHeader,
                                          <<"\r\nConnection: close\r\nAccept-Encoding: identity\r\n">>,
                                          Encoded, <<"Content-Length: ">>,
                                          integer_to_binary(byte_size(Body)),
                                          <<"\r\n\r\n">>, Body]
                            end,
                            case send(Transport, Socket, Request) of
                                ok ->
                                    case read_head(Transport, Socket, <<>>) of
                                        {ok, Head, Rest} ->
                                            case parse_head(Head) of
                                                {ok, Status, ResponseHeaders, Mode} ->
                                                    {ok, {Status, ResponseHeaders,
                                                          {upstream, Transport, Socket, Rest, Mode}}};
                                                Error -> close_socket(Transport, Socket), Error
                                            end;
                                        Error -> close_socket(Transport, Socket), Error
                                    end;
                                {error, _} ->
                                    close_socket(Transport, Socket),
                                    {error, <<"upstream send failed">>}
                            end;
                        Error -> Error
                    end
            end
    end.

valid_preserved_headers(Headers, Body) ->
    Names = [{string:lowercase(N), V} || {N, V} <- Headers],
    Hosts = [V || {<<"host">>, V} <- Names],
    Lengths = [V || {<<"content-length">>, V} <- Names],
    Encoding = [string:lowercase(V) || {<<"accept-encoding">>, V} <- Names],
    length(Hosts) =:= 1 andalso length(Lengths) =:= 1 andalso
    valid_length(hd(Lengths), byte_size(Body)) andalso
    not lists:keymember(<<"transfer-encoding">>, 1, Names) andalso
    not lists:keymember(<<"content-encoding">>, 1, Names) andalso
    lists:all(fun(V) -> V =:= <<"identity">> end, Encoding).

valid_length(Value, Size) ->
    try binary_to_integer(Value) =:= Size
    catch _:_ -> false
    end.

safe_line(Value) when is_binary(Value) ->
    binary:match(Value, <<"\r">>) =:= nomatch andalso
    binary:match(Value, <<"\n">>) =:= nomatch;
safe_line(_) -> false.

connect(<<"http">>, _Host, Port) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}], 5000) of
        {ok, Socket} -> {ok, tcp, Socket};
        _ -> {error, <<"upstream connection failed">>}
    end;
connect(<<"https">>, Host, Port) ->
    ssl:start(),
    Options = [binary, {active, false}, {verify, verify_peer},
               {cacerts, public_key:cacerts_get()},
               {server_name_indication, binary_to_list(Host)},
               {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case ssl:connect(binary_to_list(Host), Port, Options, 5000) of
        {ok, Socket} -> {ok, ssl, Socket};
        _ -> {error, <<"verified TLS connection failed">>}
    end.

send(tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
send(ssl, Socket, Data) -> ssl:send(Socket, Data).
recv(tcp, Socket) -> gen_tcp:recv(Socket, 0, 30000);
recv(ssl, Socket) -> ssl:recv(Socket, 0, 30000).
close_socket(tcp, Socket) -> gen_tcp:close(Socket);
close_socket(ssl, Socket) -> ssl:close(Socket).

read_head(Transport, Socket, Acc) ->
    case split_head(Acc) of
        more ->
            case recv(Transport, Socket) of
                {ok, More} -> read_head(Transport, Socket, <<Acc/binary, More/binary>>);
                _ -> {error, <<"upstream did not send HTTP headers">>}
            end;
        Result -> Result
    end.

%% Bound only the header before CRLFCRLF, not coalesced body bytes. Allow up
%% to three delimiter-prefix bytes while waiting for the final delimiter.
split_head(Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} when Pos =< ?MAX_HEAD ->
            <<Head:Pos/binary, _Delimiter:4/binary, Rest/binary>> = Acc,
            {ok, Head, Rest};
        {_, 4} -> {error, <<"upstream headers too large">>};
        nomatch when byte_size(Acc) > ?MAX_HEAD + 3 ->
            {error, <<"upstream headers too large">>};
        nomatch -> more
    end.

parse_head(Head) ->
    try
        [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
        [Version, Code | _] = binary:split(StatusLine, <<" ">>, [global]),
        true = (Version =:= <<"HTTP/1.1">> orelse Version =:= <<"HTTP/1.0">>),
        Status = binary_to_integer(Code),
        true = Status >= 100 andalso Status =< 599,
        Headers = [parse_header(Line) || Line <- Lines],
        Chunked = lists:any(fun({N, V}) ->
            N =:= <<"transfer-encoding">> andalso string:lowercase(V) =:= <<"chunked">>
        end, Headers),
        Lengths = [binary_to_integer(V) || {<<"content-length">>, V} <- Headers],
        Mode = case {Chunked, Lengths} of
                   {true, []} -> chunked;
                   {true, _} -> error(ambiguous_length);
                   {false, [N]} when N >= 0 -> {length, N};
                   {false, []} -> until_close;
                   _ -> error(ambiguous_length)
               end,
        {ok, Status, Headers, Mode}
    catch _:_ -> {error, <<"invalid upstream HTTP response">>}
    end.

parse_header(Line) ->
    [Name, Value] = binary:split(Line, <<":">>),
    {string:lowercase(Name), string:trim(Value)}.

%% Demand-driven reads: mist asks for exactly one next body segment after the
%% previous client send completes. This bounds buffering for long SSE streams.
next({upstream, Transport, Socket, _Buffer, {length, 0}}) ->
    close_socket(Transport, Socket),
    {ok, none};
next({upstream, Transport, Socket, Buffer, {length, N}}) ->
    case take(Transport, Socket, Buffer, N) of
        {ok, Data, Rest} ->
            {ok, {some, {Data, {upstream, Transport, Socket, Rest,
                                 {length, N - byte_size(Data)}}}}};
        Error -> Error
    end;
next({upstream, Transport, Socket, Buffer, until_close}) ->
    case Buffer of
        <<>> ->
            case recv(Transport, Socket) of
                {ok, Data} -> {ok, {some, {Data,
                    {upstream, Transport, Socket, <<>>, until_close}}}};
                {error, closed} -> {ok, none};
                _ -> {error, <<"upstream body read failed">>}
            end;
        _ -> {ok, {some, {Buffer, {upstream, Transport, Socket, <<>>, until_close}}}}
    end;
next({upstream, Transport, Socket, Buffer, chunked}) ->
    case read_line(Transport, Socket, Buffer) of
        {ok, SizeLine, Rest} ->
            [Hex | _] = binary:split(SizeLine, <<";">>),
            try
                Size = binary_to_integer(Hex, 16),
                true = Size >= 0 andalso Size =< 1048576,
                case Size of
                    0 ->
                        case read_line(Transport, Socket, Rest) of
                            {ok, <<>>, _} -> {ok, none};
                            _ -> {error, <<"upstream trailers unsupported">>}
                        end;
                    _ ->
                        case take_exact(Transport, Socket, Rest, Size + 2) of
                            {ok, <<Data:Size/binary, "\r\n">>, Remaining} ->
                                {ok, {some, {Data, {upstream, Transport, Socket,
                                                    Remaining, chunked}}}};
                            _ -> {error, <<"malformed chunked upstream response">>}
                        end
                end
            catch _:_ -> {error, <<"invalid upstream chunk size">>}
            end;
        Error -> Error
    end.

take(_Transport, _Socket, Buffer, N) when byte_size(Buffer) > 0 ->
    Size = min(N, byte_size(Buffer)),
    <<Data:Size/binary, Rest/binary>> = Buffer,
    {ok, Data, Rest};
take(Transport, Socket, <<>>, N) ->
    case recv(Transport, Socket) of
        {ok, Buffer} -> take(Transport, Socket, Buffer, N);
        _ -> {error, <<"upstream truncated response">>}
    end.

take_exact(_Transport, _Socket, Buffer, N) when byte_size(Buffer) >= N ->
    <<Data:N/binary, Rest/binary>> = Buffer,
    {ok, Data, Rest};
take_exact(Transport, Socket, Buffer, N) ->
    case recv(Transport, Socket) of
        {ok, More} -> take_exact(Transport, Socket, <<Buffer/binary, More/binary>>, N);
        _ -> {error, <<"upstream truncated chunk">>}
    end.

read_line(Transport, Socket, Buffer) ->
    case split_line(Buffer) of
        more ->
            case recv(Transport, Socket) of
                {ok, More} -> read_line(Transport, Socket, <<Buffer/binary, More/binary>>);
                _ -> {error, <<"upstream truncated chunk header">>}
            end;
        Result -> Result
    end.

%% The chunk size line is bounded, not the first chunk coalesced after it.
split_line(Buffer) ->
    case binary:match(Buffer, <<"\r\n">>) of
        {Pos, 2} when Pos =< 8192 ->
            <<Line:Pos/binary, _Delimiter:2/binary, Rest/binary>> = Buffer,
            {ok, Line, Rest};
        {_, 2} -> {error, <<"upstream chunk header too large">>};
        nomatch when byte_size(Buffer) > 8193 ->
            {error, <<"upstream chunk header too large">>};
        nomatch -> more
    end.

close({upstream, Transport, Socket, _, _}) ->
    close_socket(Transport, Socket),
    nil.

register(Port, Pid) ->
    ensure_registry(),
    ets:insert(?REGISTRY, {Port, Pid}),
    nil.

stop(Port) ->
    ensure_registry(),
    case ets:lookup(?REGISTRY, Port) of
        [{Port, Pid}] ->
            ets:delete(?REGISTRY, Port),
            exit(Pid, shutdown),
            {ok, nil};
        [] -> {error, <<"ingress is not running">>}
    end.

ensure_registry() ->
    case ets:whereis(?REGISTRY) of
        undefined -> global:trans({?MODULE, registry}, fun() ->
            case ets:whereis(?REGISTRY) of
                undefined ->
                    Parent = self(),
                    spawn(fun() ->
                        ets:new(?REGISTRY, [named_table, public, set]),
                        Parent ! registry_ready,
                        receive stop -> ok end
                    end),
                    receive registry_ready -> ok end;
                _ -> ok
            end
        end);
        _ -> ok
    end.

environment(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.
now_ms() -> erlang:system_time(millisecond).
new_session_id() -> binary:encode_hex(crypto:strong_rand_bytes(16)).
wait_forever() -> receive stop -> nil end.
