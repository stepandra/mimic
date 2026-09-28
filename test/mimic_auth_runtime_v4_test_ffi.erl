-module(mimic_auth_runtime_v4_test_ffi).
-export([new_clock/2, set_clock/3, sample/1, block_mutation/2,
         unblock_mutation/2, http_start/0, http_port/1,
         http_requests/1, http_stop/1, http_refresh/1, fresh_vm_phase/2]).

%% An unnamed public table lets the credential actor sample a clock owned by
%% the test process. No request-supplied timestamp participates.
new_clock(Epoch, Monotonic) ->
    Table = ets:new(?MODULE, [set, public]),
    true = ets:insert(Table, {sample, {Epoch, Monotonic}}),
    Table.

set_clock(Table, Epoch, Monotonic) ->
    true = ets:insert(Table, {sample, {Epoch, Monotonic}}),
    nil.

sample(Table) ->
    [{sample, Value}] = ets:lookup(Table, sample),
    Value.

lock_path(Directory, Key) ->
    Encoded = base64:encode(Key, #{mode => urlsafe, padding => false}),
    Name = <<"runtime-", Encoded/binary, ".json">>,
    filename:join(Directory, <<".mutation-", Name/binary>>).

block_mutation(Directory, Key) ->
    ok = file:make_dir(lock_path(Directory, Key)),
    nil.

unblock_mutation(Directory, Key) ->
    ok = file:del_dir(lock_path(Directory, Key)),
    nil.

%% A loopback-only synthetic OAuth endpoint, with an actual JSON HTTP request.
%% The body deliberately contains no credential values.
http_start() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
                                     {reuseaddr, true}, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Counter = ets:new(?MODULE, [set, public]),
    true = ets:insert(Counter, {requests, 0}),
    Pid = spawn(fun() -> http_loop(Listen, Counter) end),
    {ok, {Listen, Pid, Counter, Port}}.

http_port({_, _, _, Port}) -> Port.
http_requests({_, _, Counter, _}) ->
    [{requests, Count}] = ets:lookup(Counter, requests),
    Count.

http_stop({Listen, Pid, Counter, _}) ->
    gen_tcp:close(Listen),
    exit(Pid, kill),
    ets:delete(Counter),
    nil.

http_loop(Listen, Counter) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            case read_request(Socket, <<>>) of
                {ok, Request} ->
                    case binary:match(Request, <<"POST /synthetic-refresh HTTP/1.1">>) =/= nomatch
                         andalso binary:match(Request, <<"application/json">>) =/= nomatch
                         andalso binary:match(Request, <<"\"grant_type\":\"refresh_token\"">>) =/= nomatch of
                        true -> ets:update_counter(Counter, requests, 1);
                        false -> ok
                    end,
                    Body = <<"{\"error\":\"rate_limited\",\"retry_after_ms\":9000}">>,
                    Response = <<"HTTP/1.1 429 Too Many Requests\r\n",
                                 "Content-Type: application/json\r\n",
                                 "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
                                 "\r\nConnection: close\r\n\r\n", Body/binary>>,
                    gen_tcp:send(Socket, Response);
                _ -> ok
            end,
            gen_tcp:close(Socket),
            http_loop(Listen, Counter);
        _ -> ok
    end.

read_request(_Socket, Data) when byte_size(Data) > 8192 -> {error, limit};
read_request(Socket, Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Headers, Body] ->
            case re:run(Headers, <<"Content-Length: ([0-9]+)">>, [{capture, [1], binary}]) of
                {match, [RawLength]} ->
                    case byte_size(Body) >= binary_to_integer(RawLength) of
                        true -> {ok, Data};
                        false -> read_request_more(Socket, Data)
                    end;
                _ -> {error, framing}
            end;
        _ -> read_request_more(Socket, Data)
    end.

read_request_more(Socket, Data) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, More} -> read_request(Socket, <<Data/binary, More/binary>>);
        Error -> Error
    end.

http_refresh(Port) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port,
                                   [binary, {active, false}], 3000),
    Body = <<"{\"grant_type\":\"refresh_token\",\"fixture\":\"synthetic\"}">>,
    Request = <<"POST /synthetic-refresh HTTP/1.1\r\n",
                "Host: 127.0.0.1:", (integer_to_binary(Port))/binary,
                "\r\nContent-Type: application/json\r\n",
                "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
                "\r\nConnection: close\r\n\r\n", Body/binary>>,
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = read_response(Socket, <<>>),
    gen_tcp:close(Socket),
    binary:match(Response, <<"HTTP/1.1 429">>) =/= nomatch
        andalso binary:match(Response, <<"\"retry_after_ms\":9000">>) =/= nomatch.

read_response(_Socket, Data) when byte_size(Data) > 8192 -> {error, limit};
read_response(Socket, Data) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, More} -> read_response(Socket, <<Data/binary, More/binary>>);
        {error, closed} -> {ok, Data};
        Error -> Error
    end.

fresh_vm_phase(Directory, Restart) ->
    Erl = os:find_executable("erl"),
    Paths = [filename:absname(P) || P <- code:get_path()],
    Code = "provider_runtime_v4_test:fresh_vm_phase(list_to_binary(hd(init:get_plain_arguments())),"
           ++ atom_to_list(Restart) ++ "),halt(0).",
    Port = open_port({spawn_executable, Erl}, [binary, exit_status, use_stdio, stderr_to_stdout,
        {args, ["+S", "1", "-noshell", "-pa"] ++ Paths ++
                ["-eval", Code, "-extra", binary_to_list(Directory)]}]),
    wait_exit(Port).

wait_exit(Port) ->
    receive
        {Port, {data, _}} -> wait_exit(Port);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, _}} -> false
    after 10000 -> port_close(Port), false
    end.
