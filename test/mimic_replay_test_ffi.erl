-module(mimic_replay_test_ffi).
-export([start/0, start_chunked/0, start_bad_chunked/0,
         start_bad_extension/0, start_bad_trailer/0, start_response/1,
         start_interim/0, start_fragmented/0, received/0]).

%% A loopback-only, one-shot synthetic HTTP/1.1 oracle.
start() ->
    start_with([<<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Echo: synthetic\r\n\r\nok">>]).

start_chunked() ->
    start_with([
      <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n">>,
      <<"5;note=fixture\r\ndata:\r\n">>,
      <<"2\r\n",32,195,"\r\n">>,
      <<"3\r\n",169,10,10,"\r\n">>,
      <<"0\r\nX-Trailer: yes\r\n\r\n">>
    ]).

start_bad_chunked() ->
    start_with([<<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n">>]).

start_bad_extension() ->
    start_with([<<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;bad value\r\na\r\n0\r\n\r\n">>]).

start_bad_trailer() ->
    start_with([<<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\nContent-Length: 1\r\n\r\n">>]).

start_response(Response) -> start_with([Response]).

start_interim() ->
    start_with([
      <<"HTTP/1.1 100 Continue\r\n\r\n">>,
      <<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok">>
    ]).

start_fragmented() ->
    start_with([<<"HTTP/1.1 200 OK\r\nContent-Length: 800\r\n\r\n">>
                | lists:duplicate(800, <<"x">>)]).

start_with(Parts) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Parent = self(),
    spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener, 5000),
        ok = inet:setopts(Socket, [{nodelay, true}]),
        {ok, Bytes} = gen_tcp:recv(Socket, 0, 5000),
        Parent ! {captured, Bytes},
        lists:foreach(fun(Part) ->
            ok = gen_tcp:send(Socket, Part),
            timer:sleep(2)
        end, Parts),
        gen_tcp:close(Socket),
        gen_tcp:close(Listener)
    end),
    Port.

received() ->
    receive {captured, Bytes} -> Bytes
    after 5000 -> <<"no request received">>
    end.
