-module(mimic_recorder_tls_test_ffi).
-export([new_ca_dir/0, roundtrip/4, rejected_request/3]).

new_ca_dir() ->
    list_to_binary(filename:join("build", "mimic-ca-test-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))))).

roundtrip(CaCert, CaKey, TrustUpstream, Persist) ->
    Me = self(),
    case mimic_recorder_tls_ffi:make_leaf(binary_to_list(CaCert),
                                          binary_to_list(CaKey), "127.0.0.1") of
        {ok, Temp, LeafCert, LeafKey} ->
            try
                {ok, Upstream} = ssl:listen(0,
                    [binary, {active, false}, {reuseaddr, true},
                     {ip, {127,0,0,1}}, {certfile, LeafCert},
                     {keyfile, LeafKey},
                     {alpn_preferred_protocols, [<<"http/1.1">>]}]),
                try
                    {ok, {_, UpstreamPort}} = ssl:sockname(Upstream),
                    UpstreamPid = spawn(fun() -> upstream(Upstream, Me) end),
                    ProxyPort = free_port(),
                    Url = list_to_binary("https://127.0.0.1:" ++
                                         integer_to_list(UpstreamPort)),
                    Trust = case TrustUpstream of true -> CaCert; false -> <<>> end,
                    Capture = fun(Raw, Endpoint, Alpn) ->
                        Me ! {captured, Raw, Endpoint, Alpn},
                        Persist(Raw, Endpoint, Alpn)
                    end,
                    ProxyPid = spawn(fun() ->
                        Me ! {proxy_done,
                              mimic_recorder_tls_ffi:serve(ProxyPort, CaCert, CaKey,
                                                           Url, Trust, Capture)}
                    end),
                    try
                        wait_proxy(ProxyPort, 40),
                        Denied = denied_connect(ProxyPort),
                        Response = client_request(ProxyPort, UpstreamPort, CaCert),
                        Captured = receive
                            {captured, Raw, Endpoint, Alpn} ->
                                {Raw, Endpoint, Alpn}
                        after 5000 -> error(no_capture) end,
                        {ok, {Response, Captured, Denied}}
                    after
                        exit(ProxyPid, kill),
                        exit(UpstreamPid, kill)
                    end
                after ssl:close(Upstream) end
            catch Class:Reason ->
                {error, list_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
            after mimic_recorder_tls_ffi:cleanup(Temp) end;
        Error -> Error
    end.

rejected_request(CaCert, CaKey, Kind) ->
    ProxyPort = free_port(),
    RemotePort = free_port(),
    Authority = list_to_binary("127.0.0.1:" ++ integer_to_list(RemotePort)),
    Url = <<"https://", Authority/binary>>,
    ProxyPid = spawn(fun() ->
        mimic_recorder_tls_ffi:serve(ProxyPort, CaCert, CaKey, Url, <<>>,
            fun(_, _, _) -> {ok, <<"unexpected">>} end)
    end),
    try
        wait_proxy(ProxyPort, 40),
        {ok, Tcp} = gen_tcp:connect({127,0,0,1}, ProxyPort,
                                    [binary, {active, false}], 5000),
        ok = gen_tcp:send(Tcp, <<"CONNECT ", Authority/binary, " HTTP/1.1\r\n\r\n">>),
        {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Tcp, 0, 5000),
        {ok, Tls} = ssl:connect(Tcp,
            [binary, {active, false}, {verify, verify_peer},
             {cacertfile, binary_to_list(CaCert)},
             {server_name_indication, "127.0.0.1"},
             {alpn_advertised_protocols, [<<"http/1.1">>]}], 5000),
        Request = case Kind of
            <<"h2">> -> <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>;
            <<"encoding">> ->
                <<"POST /v1/qa HTTP/1.1\r\nHost: ", Authority/binary,
                  "\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}">>
        end,
        ok = ssl:send(Tls, Request),
        Reply = read_all(Tls, <<>>),
        ssl:close(Tls),
        {ok, Reply}
    catch Class:Reason ->
        {error, list_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    after exit(ProxyPid, kill) end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    gen_tcp:close(Socket),
    Port.

wait_proxy(_Port, 0) -> error(proxy_not_ready);
wait_proxy(Port, N) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 100) of
        {ok, S} -> gen_tcp:close(S);
        _ -> timer:sleep(100), wait_proxy(Port, N - 1)
    end.

denied_connect(Port) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Socket, <<"CONNECT other.example:443 HTTP/1.1\r\n"
                                "Host: other.example:443\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    Response.

client_request(ProxyPort, UpstreamPort, CaCert) ->
    {ok, Tcp} = gen_tcp:connect({127,0,0,1}, ProxyPort,
                                [binary, {active, false}], 5000),
    Authority = list_to_binary("127.0.0.1:" ++ integer_to_list(UpstreamPort)),
    ok = gen_tcp:send(Tcp, <<"CONNECT ", Authority/binary, " HTTP/1.1\r\n"
                             "Host: ", Authority/binary, "\r\n\r\n">>),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Tcp, 0, 5000),
    {ok, Tls} = ssl:connect(Tcp,
        [binary, {active, false}, {verify, verify_peer},
         {cacertfile, binary_to_list(CaCert)},
         {server_name_indication, "127.0.0.1"},
         {customize_hostname_check,
          [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
         {alpn_advertised_protocols, [<<"http/1.1">>]}], 5000),
    Body = <<"{\"stream\":true}">>,
    ok = ssl:send(Tls, <<"POST /v1/qa HTTP/1.1\r\nHost: ", Authority/binary,
                         "\r\nX-CaSe: first\r\nx-case: second\r\n"
                         "Authorization: Bearer synthetic-not-a-secret\r\n"
                         "Content-Type: application/json\r\nContent-Length: ",
                         (integer_to_binary(byte_size(Body)))/binary,
                         "\r\n\r\n", Body/binary>>),
    Response = read_all(Tls, <<>>),
    ssl:close(Tls),
    Response.

read_all(Socket, Acc) ->
    case ssl:recv(Socket, 0, 5000) of
        {ok, Chunk} -> read_all(Socket, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> Acc;
        Error -> error(Error)
    end.

upstream(Listener, Parent) ->
    {ok, Transport} = ssl:transport_accept(Listener, 5000),
    case ssl:handshake(Transport, 5000) of
        {ok, Socket} ->
            {ok, Data} = ssl:recv(Socket, 0, 5000),
            Parent ! {upstream_received, Data},
            ok = ssl:send(Socket, <<"HTTP/1.1 200 OK\r\n"
                                    "Content-Type: text/event-stream\r\n"
                                    "Transfer-Encoding: chunked\r\n\r\n"
                                    "B\r\ndata: one\n\n\r\n">>),
            timer:sleep(20),
            ok = ssl:send(Socket, <<"B\r\ndata: two\n\n\r\n0\r\n\r\n">>),
            ssl:close(Socket);
        _ -> ok
    end.
