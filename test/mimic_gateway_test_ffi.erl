%% Synthetic loopback upstream and real HTTP client for assembled Mist tests.
-module(mimic_gateway_test_ffi).
-export([directory/0, upstream/2, stop/1, request/5, observations/1,
         private_file/3, symlink/2]).

directory() ->
    Path = filename:absname(filename:join(
        "build", "gateway-test-" ++ binary_to_list(
            binary:encode_hex(crypto:strong_rand_bytes(12))))),
    ok = file:make_dir(Path),
    ok = file:change_mode(Path, 8#700),
    list_to_binary(Path).

private_file(Dir, Name, Content) ->
    Path = filename:join(binary_to_list(Dir), binary_to_list(Name)),
    ok = file:write_file(Path, Content),
    ok = file:change_mode(Path, 8#600),
    list_to_binary(Path).

symlink(Target, Link) ->
    ok = file:make_symlink(Target, Link),
    nil.

upstream(Media, Body) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Pid = spawn(fun() -> loop(Listen, Media, Body, []) end),
    {Port, Pid}.

stop(Pid) -> Pid ! stop, nil.

observations(Pid) ->
    Pid ! {observations, self()},
    receive {observations, Items} -> Items after 2000 -> [] end.

loop(Listen, Media, Body, Items) ->
    receive
        stop -> gen_tcp:close(Listen);
        {observations, From} ->
            From ! {observations, lists:reverse(Items)},
            loop(Listen, Media, Body, Items)
    after 10 ->
        case gen_tcp:accept(Listen, 10) of
            {ok, Socket} ->
                Recv = recv_headers(Socket, <<>>),
                Response = <<"HTTP/1.1 200 OK\r\nContent-Type: ", Media/binary,
                    "\r\nContent-Length: ", (integer_to_binary(byte_size(Body)))/binary,
                    "\r\nConnection: close\r\n\r\n", Body/binary>>,
                gen_tcp:send(Socket, Response),
                gen_tcp:close(Socket),
                loop(Listen, Media, Body, [Recv | Items]);
            {error, timeout} -> loop(Listen, Media, Body, Items);
            _ -> ok
        end
    end.

recv_headers(_Socket, Acc) when byte_size(Acc) > 65536 -> Acc;
recv_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> Acc;
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> recv_headers(Socket, <<Acc/binary, Chunk/binary>>);
                _ -> Acc
            end
    end.

request(Port, Method, Path, Token, Body) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port,
        [binary, {active, false}], 5000),
    Auth = case Token of
        <<>> -> <<>>;
        _ -> <<"Authorization: Bearer ", Token/binary, "\r\n">>
    end,
    Request = <<Method/binary, " ", Path/binary, " HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\nConnection: close\r\n", Auth/binary,
        "Content-Type: application/json\r\nContent-Length: ",
        (integer_to_binary(byte_size(Body)))/binary, "\r\n\r\n", Body/binary>>,
    ok = gen_tcp:send(Socket, Request),
    Result = recv_all(Socket, <<>>),
    gen_tcp:close(Socket),
    Result.

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Chunk} -> recv_all(Socket, <<Acc/binary, Chunk/binary>>);
        _ -> Acc
    end.
