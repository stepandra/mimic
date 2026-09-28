%% Synthetic loopback Responses upstream; all recorded bodies are local test data.
-module(mimic_gateway_codex_http_test_ffi).
-export([upstream/1, observations/1, stop/1, request/5]).

request(Port, <<"POST">>, Path, Key, Body) ->
    {ok, _} = application:ensure_all_started(inets),
    URL = lists:flatten(io_lib:format("http://127.0.0.1:~B~s",
                                     [Port, binary_to_list(Path)])),
    Headers = case Key of
        <<>> -> [];
        _ -> [{"Authorization", "Bearer " ++ binary_to_list(Key)}]
    end,
    {ok, {{_, Status, _}, _, Reply}} =
        httpc:request(post,
                      {URL, Headers, "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    <<"HTTP/1.1 ", (integer_to_binary(Status))/binary, "\r\n\r\n", Reply/binary>>.

upstream(Bodies) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Pid = spawn(fun() -> loop(Listen, Bodies, []) end),
    {Port, Pid}.

observations(Pid) ->
    Pid ! {observations, self()},
    receive {observations, Items} -> Items after 2000 -> [] end.

stop(Pid) -> Pid ! stop, nil.

loop(Listen, Bodies, Items) ->
    receive
        stop -> gen_tcp:close(Listen);
        {observations, From} ->
            From ! {observations, lists:reverse(Items)},
            loop(Listen, Bodies, Items)
    after 10 ->
        case gen_tcp:accept(Listen, 10) of
            {ok, Socket} ->
                Request = receive_request(Socket, <<>>),
                {Body, Rest} = case Bodies of
                    [First | Following] -> {First, Following};
                    [] -> {<<>>, []}
                end,
                Response = <<"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                    "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
                    "\r\nConnection: close\r\n\r\n", Body/binary>>,
                gen_tcp:send(Socket, Response),
                gen_tcp:close(Socket),
                loop(Listen, Rest, [Request | Items]);
            {error, timeout} -> loop(Listen, Bodies, Items);
            _ -> ok
        end
    end.

receive_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {HeaderEnd, 4} ->
            HeaderSize = HeaderEnd + 4,
            <<Headers:HeaderSize/binary, Body/binary>> = Acc,
            Length = content_length(Headers),
            case byte_size(Body) >= Length of
                true -> binary:part(Acc, 0, HeaderSize + Length);
                false -> read_request(Socket, Acc)
            end;
        nomatch -> read_request(Socket, Acc)
    end.

read_request(Socket, Acc) when byte_size(Acc) < 2097152 ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, More} -> receive_request(Socket, <<Acc/binary, More/binary>>);
        _ -> Acc
    end;
read_request(_, Acc) -> Acc.

content_length(Headers) ->
    case re:run(Headers, <<"content-length: ([0-9]+)">>,
        [caseless, {capture, [1], binary}]) of
        {match, [Number]} -> binary_to_integer(Number);
        _ -> 0
    end.
