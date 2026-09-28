-module(mimic_recorder_tls_ffi).
-export([generate_ca/1, serve/6, make_leaf/3, cleanup/1]).

-define(HEAD_LIMIT, 65536).
-define(REQUEST_LIMIT, 8388608).
-define(RESPONSE_LIMIT, 33554432).
-define(TIMEOUT, 30000).

%% This module owns socket and OS primitives; capture policy lives in Gleam.
%% No request, response, or openssl output is ever logged.
generate_ca(DirBin) ->
    Dir = binary_to_list(DirBin),
    Cert = filename:join(Dir, "ca.pem"),
    Key = filename:join(Dir, "ca-key.pem"),
    case file:make_dir(Dir) of
        ok ->
            ok = file:change_mode(Dir, 8#700),
            case run_openssl(["req", "-x509", "-newkey", "rsa:2048",
                              "-nodes", "-sha256", "-days", "7",
                              "-subj", "/CN=MIMIC local QA CA",
                              "-addext", "basicConstraints=critical,CA:TRUE",
                              "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                              "-keyout", Key, "-out", Cert]) of
                ok ->
                    ok = file:change_mode(Key, 8#600),
                    {ok, {list_to_binary(Cert), list_to_binary(Key)}};
                error ->
                    file:delete(Key), file:delete(Cert),
                    {error, <<"CA generation failed">>}
            end;
        _ -> {error, <<"CA directory must be new and writable">>}
    end.

serve(Port, CaCert, CaKey, Upstream, UpstreamCa, Capture)
  when is_integer(Port), Port >= 0, Port =< 65535 ->
    case parse_upstream(Upstream) of
        {ok, Host, RemotePort, Authority} ->
            case make_leaf(binary_to_list(CaCert), binary_to_list(CaKey), Host) of
                {ok, Tmp, Cert, Key} ->
                    try listen(Port, Host, RemotePort, Authority, Cert, Key,
                               binary_to_list(UpstreamCa), Capture)
                    after cleanup(Tmp) end;
                Error -> Error
            end;
        Error -> Error
    end;
serve(_, _, _, _, _, _) -> {error, <<"Invalid bind port">>}.

listen(Port, Host, RemotePort, Authority, Cert, Key, Trust, Capture) ->
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true},
                               {ip, {127,0,0,1}}, {backlog, 32}]) of
        {ok, Listener} ->
            try accept_loop(Listener, Host, RemotePort, Authority, Cert, Key,
                            Trust, Capture)
            after gen_tcp:close(Listener) end;
        _ -> {error, <<"Unable to bind loopback proxy">>}
    end.

accept_loop(Listener, Host, Port, Authority, Cert, Key, Trust, Capture) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            Worker = spawn(fun() ->
                receive start ->
                    handle(Socket, Host, Port, Authority, Cert, Key, Trust, Capture)
                end
            end),
            case gen_tcp:controlling_process(Socket, Worker) of
                ok -> Worker ! start;
                _ -> gen_tcp:close(Socket), exit(Worker, kill)
            end,
            accept_loop(Listener, Host, Port, Authority, Cert, Key, Trust, Capture);
        {error, closed} -> {ok, nil};
        _ -> {error, <<"Proxy accept failed">>}
    end.

handle(Socket, Host, Port, Authority, Cert, Key, Trust, Capture) ->
    try
        case read_head(tcp, Socket, <<>>, ?HEAD_LIMIT) of
            {ok, ConnectHead, <<>>} ->
                case valid_connect(ConnectHead, Authority) of
                    true ->
                        ok = gen_tcp:send(Socket, <<"HTTP/1.1 200 Connection Established\r\n\r\n">>),
                        server_tls(Socket, Host, Port, Authority, Cert, Key, Trust, Capture);
                    false -> send_error(tcp, Socket, 403)
                end;
            _ -> send_error(tcp, Socket, 400)
        end
    catch _:_ -> ok
    after gen_tcp:close(Socket) end.

server_tls(Socket, Host, Port, Authority, Cert, Key, Trust, Capture) ->
    Opts = [{certfile, Cert}, {keyfile, Key}, {verify, verify_none},
            {active, false}, {alpn_preferred_protocols, [<<"http/1.1">>]}],
    case ssl:handshake(Socket, Opts, ?TIMEOUT) of
        {ok, Client} ->
            try
                Alpn = case ssl:negotiated_protocol(Client) of
                    {ok, <<"http/1.1">>} -> <<"http/1.1">>;
                    {error, protocol_not_negotiated} -> <<"none">>;
                    _ -> <<"unsupported">>
                end,
                case Alpn of
                    <<"unsupported">> -> send_error(ssl, Client, 505);
                    _ -> request(Client, Host, Port, Authority, Trust, Capture, Alpn)
                end
            after ssl:close(Client) end;
        _ -> ok
    end.

request(Client, Host, Port, Authority, Trust, Capture, Alpn) ->
    case read_head(ssl, Client, <<>>, ?HEAD_LIMIT) of
        {ok, Head, Extra} ->
            case request_framing(Head, Host, Authority) of
                {ok, Length} ->
                    case take_exact(ssl, Client, Extra, Length) of
                        {ok, Body, <<>>} ->
                            Raw = <<Head/binary, Body/binary>>,
                            case valid_utf8(Raw) of
                                true ->
                                    %% Gleam's callback must redact before persisting.
                                    Outcome = try Capture(Raw, Authority, Alpn)
                                    catch _:_ -> {error, <<"Capture callback failed">>}
                                    end,
                                    case Outcome of
                                        {ok, _} -> forward(Client, Host, Port, Trust, Raw);
                                        _ -> send_error(ssl, Client, 502)
                                    end;
                                false -> send_error(ssl, Client, 415)
                            end;
                        _ -> send_error(ssl, Client, 400)
                    end;
                {error, Code} -> send_error(ssl, Client, Code)
            end;
        _ -> send_error(ssl, Client, 400)
    end.

forward(Client, Host, Port, Trust, Raw) ->
    CaOpts = case Trust of
        "" -> [{cacerts, public_key:cacerts_get()}];
        _ -> [{cacertfile, Trust}]
    end,
    Opts = [binary, {active, false}, {verify, verify_peer},
            {server_name_indication, Host},
            {customize_hostname_check,
             [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
            {alpn_advertised_protocols, [<<"http/1.1">>]} | CaOpts],
    case ssl:connect(Host, Port, Opts, ?TIMEOUT) of
        {ok, Remote} ->
            try
                case ssl:negotiated_protocol(Remote) of
                    {ok, <<"http/1.1">>} -> relay_if_sent(Client, Remote, Raw);
                    {error, protocol_not_negotiated} -> relay_if_sent(Client, Remote, Raw);
                    _ -> send_error(ssl, Client, 502)
                end
            after ssl:close(Remote) end;
        _ -> send_error(ssl, Client, 502)
    end.

relay_if_sent(Client, Remote, Raw) ->
    case ssl:send(Remote, Raw) of
        ok -> relay_response(Client, Remote);
        _ -> send_error(ssl, Client, 502)
    end.

relay_response(Client, Remote) ->
    case read_head(ssl, Remote, <<>>, ?HEAD_LIMIT) of
        {ok, Head, Extra} ->
            case response_framing(Head) of
                {ok, {length, N}} ->
                    ok = ssl:send(Client, Head),
                    stream_exact(Client, Remote, Extra, N, 0);
                {ok, chunked} ->
                    ok = ssl:send(Client, Head),
                    stream_chunks(Client, Remote, Extra, 0);
                {ok, close} ->
                    ok = ssl:send(Client, Head),
                    stream_close(Client, Remote, Extra, 0);
                _ -> send_error(ssl, Client, 502)
            end;
        _ -> send_error(ssl, Client, 502)
    end.

stream_exact(_Client, _Remote, _Buffer, 0, _Count) -> ok;
stream_exact(Client, Remote, Buffer, Remaining, Count) when Count =< ?RESPONSE_LIMIT ->
    case next_bytes(Remote, Buffer, Remaining) of
        {ok, Data, Rest} ->
            New = Count + byte_size(Data),
            case New =< ?RESPONSE_LIMIT of
                true ->
                    ok = ssl:send(Client, Data),
                    stream_exact(Client, Remote, Rest, Remaining - byte_size(Data), New);
                false -> error
            end;
        _ -> error
    end;
stream_exact(_, _, _, _, _) -> error.

stream_close(Client, Remote, Buffer, Count) ->
    New = Count + byte_size(Buffer),
    case New =< ?RESPONSE_LIMIT of
        false -> error;
        true ->
            case Buffer of <<>> -> ok; _ -> ok = ssl:send(Client, Buffer) end,
            case ssl:recv(Remote, 0, ?TIMEOUT) of
                {ok, Data} -> stream_close(Client, Remote, Data, New);
                {error, closed} -> ok;
                _ -> error
            end
    end.

stream_chunks(Client, Remote, Buffer, Count) when Count =< ?RESPONSE_LIMIT ->
    case read_line(Remote, Buffer, 8192) of
        {ok, Line, Rest} ->
            case parse_chunk_size(Line) of
                {ok, 0} ->
                    %% Trailers are relayed verbatim, bounded by the header cap.
                    case read_trailers(Remote, Rest, 0) of
                        {ok, Trailer} ->
                            ssl:send(Client, <<Line/binary, Trailer/binary>>);
                        _ -> error
                    end;
                {ok, Size} when Size + Count =< ?RESPONSE_LIMIT ->
                    ok = ssl:send(Client, Line),
                    case take_exact(ssl, Remote, Rest, Size + 2) of
                        {ok, Chunk, Tail} ->
                            case binary:part(Chunk, Size, 2) of
                                <<"\r\n">> ->
                                    ok = ssl:send(Client, Chunk),
                                    stream_chunks(Client, Remote, Tail, Count + Size);
                                _ -> error
                            end;
                        _ -> error
                    end;
                _ -> error
            end;
        _ -> error
    end;
stream_chunks(_, _, _, _) -> error.

read_trailers(Remote, Buffer, Count) when Count =< ?HEAD_LIMIT ->
    case read_line(Remote, Buffer, ?HEAD_LIMIT - Count) of
        {ok, <<"\r\n">>, _Rest} -> {ok, <<"\r\n">>};
        {ok, Line, Rest} ->
            case read_trailers(Remote, Rest, Count + byte_size(Line)) of
                {ok, Tail} -> {ok, <<Line/binary, Tail/binary>>};
                Error -> Error
            end;
        _ -> error
    end;
read_trailers(_, _, _) -> error.

parse_chunk_size(Line) ->
    [Hex | _] = binary:split(binary:part(Line, 0, byte_size(Line) - 2), <<";">>),
    try
        N = binary_to_integer(Hex, 16),
        case N >= 0 of true -> {ok, N}; false -> error end
    catch _:_ -> error end.

next_bytes(_Socket, Buffer, Limit) when byte_size(Buffer) > 0 ->
    N = min(byte_size(Buffer), Limit),
    <<Data:N/binary, Rest/binary>> = Buffer,
    {ok, Data, Rest};
next_bytes(Socket, <<>>, _Limit) ->
    case ssl:recv(Socket, 0, ?TIMEOUT) of
        {ok, Data} when byte_size(Data) =< _Limit -> {ok, Data, <<>>};
        {ok, Data} ->
            <<Part:_Limit/binary, Rest/binary>> = Data,
            {ok, Part, Rest};
        _ -> error
    end.

take_exact(_Kind, _Socket, Buffer, N) when byte_size(Buffer) >= N ->
    <<Body:N/binary, Rest/binary>> = Buffer,
    {ok, Body, Rest};
take_exact(Kind, Socket, Buffer, N) when N =< ?RESPONSE_LIMIT ->
    case recv(Kind, Socket) of
        {ok, Data} -> take_exact(Kind, Socket, <<Buffer/binary, Data/binary>>, N);
        _ -> error
    end;
take_exact(_, _, _, _) -> error.

read_head(Kind, Socket, Buffer, Max) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        {Pos, 4} when Pos + 4 =< Max ->
            N = Pos + 4,
            <<Head:N/binary, Rest/binary>> = Buffer,
            {ok, Head, Rest};
        {_, 4} -> error;
        nomatch when byte_size(Buffer) > Max -> error;
        nomatch ->
            case recv(Kind, Socket) of
                {ok, Data} -> read_head(Kind, Socket, <<Buffer/binary, Data/binary>>, Max);
                _ -> error
            end
    end.

read_line(Socket, Buffer, Max) ->
    case binary:match(Buffer, <<"\r\n">>) of
        {Pos, 2} when Pos + 2 =< Max ->
            N = Pos + 2,
            <<Line:N/binary, Rest/binary>> = Buffer,
            {ok, Line, Rest};
        {_, 2} -> error;
        nomatch when byte_size(Buffer) > Max -> error;
        nomatch ->
            case ssl:recv(Socket, 0, ?TIMEOUT) of
                {ok, Data} -> read_line(Socket, <<Buffer/binary, Data/binary>>, Max);
                _ -> error
            end
    end.

recv(tcp, Socket) -> gen_tcp:recv(Socket, 0, ?TIMEOUT);
recv(ssl, Socket) -> ssl:recv(Socket, 0, ?TIMEOUT).

valid_connect(Head, Authority) ->
    case split_headers(Head) of
        {ok, Line, Headers} ->
            Line =:= <<"CONNECT ", Authority/binary, " HTTP/1.1">>
            andalso header(Headers, <<"content-length">>) =:= []
            andalso header(Headers, <<"transfer-encoding">>) =:= [];
        _ -> false
    end.

request_framing(Head, Host, Authority) ->
    case split_headers(Head) of
        {ok, Line, Headers} ->
            HostHeaders = header(Headers, <<"host">>),
            HostBin = list_to_binary(Host),
            HostValid = HostHeaders =:= [Authority]
                orelse (Authority =:= <<HostBin/binary, ":443">>
                        andalso HostHeaders =:= [HostBin]),
            Encoding = header(Headers, <<"content-encoding">>),
            LineValid =
                re:run(Line, <<"^[A-Z]+ /[^ ]* HTTP/1\\.1$">>,
                       [{capture, none}]) =:= match
                andalso not lists:any(fun(C) -> C < 32 orelse C =:= 127 end,
                                      binary_to_list(Line)),
            case {LineValid,
                  header(Headers, <<"transfer-encoding">>), Encoding,
                  HostValid, content_length(Headers)} of
                {true, [], [], true, {ok, N}}
                  when N =< ?REQUEST_LIMIT ->
                    {ok, N};
                {true, [], [], true, absent} -> {ok, 0};
                {_, [_|_], _, _, _} -> {error, 501};
                {_, _, [_|_], _, _} -> {error, 415};
                {_, _, _, _, {ok, N}} when N > ?REQUEST_LIMIT -> {error, 413};
                _ -> {error, 400}
            end;
        _ -> {error, 400}
    end.

response_framing(Head) ->
    case split_headers(Head) of
        {ok, <<"HTTP/1.1 ", Status:3/binary, _/binary>>, Headers} ->
            Encoding = header(Headers, <<"content-encoding">>),
            Transfer = header(Headers, <<"transfer-encoding">>),
            case Encoding of
                [] ->
                    case {Status, Transfer, content_length(Headers),
                          supported_response_type(Headers)} of
                        {<<"204">>, [], absent, _} -> {ok, {length, 0}};
                        {<<"304">>, [], absent, _} -> {ok, {length, 0}};
                        {_, [<<"chunked">>], absent, true} -> {ok, chunked};
                        {_, [], {ok, 0}, false} -> {ok, {length, 0}};
                        {_, [], {ok, N}, true} when N =< ?RESPONSE_LIMIT ->
                            {ok, {length, N}};
                        {_, [], absent, true} -> {ok, close};
                        _ -> error
                    end;
                _ -> error
            end;
        _ -> error
    end.

supported_type(Type) ->
    Lower = string:lowercase(binary_to_list(Type)),
    [Media | _] = string:split(Lower, ";", all),
    Mime = string:trim(Media),
    Mime =:= "application/json"
    orelse (lists:prefix("application/", Mime)
            andalso lists:suffix("+json", Mime))
    orelse Mime =:= "text/event-stream"
    orelse Mime =:= "text/plain".

supported_response_type(Headers) ->
    case header(Headers, <<"content-type">>) of
        [Type] -> supported_type(Type);
        [] -> false;
        _ -> false
    end.

content_length(Headers) ->
    case header(Headers, <<"content-length">>) of
        [] -> absent;
        [Value] ->
            try
                N = binary_to_integer(Value),
                case N >= 0 andalso integer_to_binary(N) =:= Value of
                    true -> {ok, N};
                    false -> error
                end
            catch _:_ -> error end;
        _ -> error
    end.

split_headers(Head) ->
    try
        Size = byte_size(Head) - 4,
        <<Prefix:Size/binary, "\r\n\r\n">> = Head,
        [Line | Lines] = binary:split(Prefix, <<"\r\n">>, [global]),
        true = valid_utf8(Head),
        Headers = lists:map(fun(H) ->
            [Name, Value] = binary:split(H, <<":">>),
            true = byte_size(Name) > 0,
            true = re:run(Name, <<"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$">>,
                          [{capture, none}]) =:= match,
            true = not lists:any(fun(C) ->
                (C < 32 andalso C =/= 9) orelse C =:= 127
            end, binary_to_list(Value)),
            {string:lowercase(Name), string:trim(Value, both, " \t")}
        end, Lines),
        {ok, Line, Headers}
    catch _:_ -> error end.

header(Headers, Name) ->
    [Value || {Key, Value} <- Headers, Key =:= Name].

valid_utf8(Data) ->
    case unicode:characters_to_binary(Data, utf8, utf8) of
        Data -> true;
        _ -> false
    end.

send_error(Kind, Socket, Code) ->
    Text = case Code of
        400 -> <<"Bad Request">>;
        403 -> <<"Forbidden">>;
        413 -> <<"Content Too Large">>;
        415 -> <<"Unsupported Media Type">>;
        501 -> <<"Not Implemented">>;
        505 -> <<"HTTP Version Not Supported">>;
        _ -> <<"Bad Gateway">>
    end,
    Reply = <<"HTTP/1.1 ", (integer_to_binary(Code))/binary, " ", Text/binary,
              "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>,
    case Kind of
        tcp -> gen_tcp:send(Socket, Reply);
        ssl -> ssl:send(Socket, Reply)
    end.

parse_upstream(Url) ->
    try
        <<"https://", Tail/binary>> = Url,
        true = binary:match(Tail, <<"/">>) =:= nomatch,
        true = binary:match(Tail, <<"@">>) =:= nomatch,
        true = binary:match(Tail, <<"?">>) =:= nomatch,
        [HostBin, PortBin] = binary:split(Tail, <<":">>),
        true = re:run(HostBin, <<"^[A-Za-z0-9.-]+$">>, [{capture, none}]) =:= match,
        true = byte_size(HostBin) > 0,
        Port = binary_to_integer(PortBin),
        true = Port > 0 andalso Port =< 65535,
        Host = binary_to_list(HostBin),
        {ok, Host, Port, Tail}
    catch _:_ -> {error, <<"Upstream must be explicit https://host:port">>} end.

make_leaf(CaCert, CaKey, Host) ->
    Tmp = filename:join(temp_dir(), "mimic-tls-" ++
                        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    Cert = filename:join(Tmp, "leaf.pem"),
    Key = filename:join(Tmp, "leaf-key.pem"),
    Csr = filename:join(Tmp, "leaf.csr"),
    Ext = filename:join(Tmp, "leaf.ext"),
    case file:make_dir(Tmp) of
        ok ->
            ok = file:change_mode(Tmp, 8#700),
            San = case inet:parse_address(Host) of
                {ok, _} -> "IP:" ++ Host;
                _ -> "DNS:" ++ Host
            end,
            ExtText = "basicConstraints=critical,CA:FALSE\n"
                      "keyUsage=critical,digitalSignature,keyEncipherment\n"
                      "extendedKeyUsage=serverAuth\nsubjectAltName=" ++ San ++ "\n",
            ok = file:write_file(Ext, ExtText, [exclusive]),
            case run_openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes",
                              "-subj", "/CN=" ++ Host, "-keyout", Key,
                              "-out", Csr]) of
                ok ->
                    ok = file:change_mode(Key, 8#600),
                    Serial = "0x" ++ binary_to_list(binary:encode_hex(
                        crypto:strong_rand_bytes(16))),
                    case run_openssl(["x509", "-req", "-in", Csr, "-CA", CaCert,
                                      "-CAkey", CaKey, "-set_serial", Serial,
                                      "-days", "1", "-sha256", "-extfile", Ext,
                                      "-out", Cert]) of
                        ok -> {ok, Tmp, Cert, Key};
                        error -> cleanup(Tmp), {error, <<"Leaf signing failed">>}
                    end;
                error -> cleanup(Tmp), {error, <<"Leaf key generation failed">>}
            end;
        _ -> {error, <<"Unable to create private TLS directory">>}
    end.

temp_dir() ->
    case os:getenv("TMPDIR") of false -> "/tmp"; Dir -> Dir end.

cleanup(Tmp) ->
    lists:foreach(fun(Name) -> file:delete(filename:join(Tmp, Name)) end,
                  ["leaf.pem", "leaf-key.pem", "leaf.csr", "leaf.ext"]),
    file:del_dir(Tmp).

run_openssl(Args) ->
    case os:find_executable("openssl") of
        false -> error;
        Executable ->
            Port = open_port({spawn_executable, Executable},
                             [{args, Args}, binary, exit_status,
                              stderr_to_stdout, hide]),
            await_openssl(Port)
    end.

await_openssl(Port) ->
    receive
        {Port, {data, _}} -> await_openssl(Port);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, _}} -> error
    after 10000 -> port_close(Port), error end.
