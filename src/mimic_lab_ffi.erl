%% Raw HTTP/1.1 socket primitive for the local synthetic oracle. Parsing
%% semantics and response policy remain in mimic/lab.gleam.
-module(mimic_lab_ffi).
-export([start/2, stop/1, last/1, requests/1, count/1, byte_length/1, wait_forever/0,
         probe/2, split_head/1]).

-define(TABLE, mimic_lab_local_servers).
-define(MAX_HEADER, 65536).
-define(MAX_BODY, 1048576).

start(Port, Handler) ->
    ensure_registry(),
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true},
                               {ip, {127,0,0,1}}, {packet, raw}]) of
        {ok, Listener} ->
            {ok, ActualPort} = inet:port(Listener),
            Pid = spawn(fun() -> accept_loop(Listener, ActualPort, Handler) end),
            ets:insert(?TABLE, {{server, ActualPort}, Listener, Pid}),
            {ok, ActualPort};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

stop(Port) ->
    ensure_registry(),
    case ets:lookup(?TABLE, {server, Port}) of
        [{{server, Port}, Listener, _Pid}] ->
            ets:delete(?TABLE, {server, Port}),
            ets:delete(?TABLE, {last, Port}),
            ets:delete(?TABLE, {requests, Port}),
            ets:delete(?TABLE, {count, Port}),
            gen_tcp:close(Listener),
            {ok, nil};
        [] -> {error, <<"lab is not running">>}
    end.

last(Port) ->
    ensure_registry(),
    case ets:lookup(?TABLE, {last, Port}) of
        [{{last, Port}, Observation}] -> {ok, Observation};
        [] -> {error, <<"no request observed">>}
    end.

requests(Port) ->
    ensure_registry(),
    case ets:lookup(?TABLE, {server, Port}) of
        [] -> {error, <<"lab is not running">>};
        _ ->
            case ets:lookup(?TABLE, {requests, Port}) of
                [{{requests, Port}, Frames}] -> {ok, Frames};
                [] -> {ok, []}
            end
    end.

count(Port) ->
    ensure_registry(),
    case ets:lookup(?TABLE, {server, Port}) of
        [] -> {error, <<"lab is not running">>};
        _ ->
            case ets:lookup(?TABLE, {count, Port}) of
                [{{count, Port}, N}] -> {ok, N};
                [] -> {ok, 0}
            end
    end.

byte_length(Value) -> byte_size(Value).
wait_forever() -> receive stop -> nil end.

%% Test/client probe: real loopback TCP, preserving the supplied bytes.
probe(Port, Request) ->
    case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Result = case gen_tcp:send(Socket, Request) of
                         ok -> probe_recv(Socket, <<>>);
                         {error, Reason} -> {error, atom_to_binary(Reason)}
                     end,
            gen_tcp:close(Socket),
            Result;
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

probe_recv(Socket, Acc) ->
    case response_complete(Acc) of
        true -> {ok, Acc};
        false ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> probe_recv(Socket, <<Acc/binary, Data/binary>>);
                {error, closed} -> {ok, Acc};
                {error, Reason} -> {error, atom_to_binary(Reason)}
            end
    end.

response_complete(Data) ->
    case binary:match(Data, <<"\r\n\r\n">>) of
        nomatch -> false;
        {Pos, 4} ->
            <<Head:Pos/binary, _:4/binary, Body/binary>> = Data,
            Lines = binary:split(string:lowercase(Head), <<"\r\n">>, [global]),
            Lengths = [V || <<"content-length: ", V/binary>> <- Lines],
            case Lengths of
                [Length] ->
                    try byte_size(Body) >= binary_to_integer(Length)
                    catch _:_ -> false
                    end;
                [] ->
                    case lists:member(<<"transfer-encoding: chunked">>, Lines) of
                        true -> binary:match(Body, <<"\r\n0\r\n\r\n">>) =/= nomatch
                                orelse Body =:= <<"0\r\n\r\n">>;
                        false -> false
                    end;
                _ -> false
            end
    end.

ensure_registry() ->
    case ets:whereis(?TABLE) of
        undefined ->
            %% Registry owner is independent of test/request processes.
            global:trans({?MODULE, registry}, fun() ->
                case ets:whereis(?TABLE) of
                    undefined ->
                        Parent = self(),
                        spawn(fun() ->
                            ets:new(?TABLE, [named_table, public, set,
                                             {read_concurrency, true}]),
                            Parent ! {registry_ready, self()},
                            receive stop -> ok end
                        end),
                        receive {registry_ready, _} -> ok end;
                    _ -> ok
                end
            end);
        _ -> ok
    end.

accept_loop(Listener, Port, Handler) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            spawn(fun() -> serve(Socket, Port, Handler) end),
            accept_loop(Listener, Port, Handler);
        {error, closed} -> ok;
        {error, _} -> accept_loop(Listener, Port, Handler)
    end.

serve(Socket, Port, Handler) ->
    try
        case read_request(Socket) of
            {ok, Raw} ->
                {Response, Observation, Events, Frame} = Handler(Raw),
                ets:insert(?TABLE, {{last, Port}, Observation}),
                Frames = case ets:lookup(?TABLE, {requests, Port}) of
                             [{{requests, Port}, Old}] -> Old;
                             [] -> []
                         end,
                ets:insert(?TABLE, {{requests, Port},
                                    lists:sublist(Frames ++ [Frame],
                                                  max(1, length(Frames) - 30), 32)}),
                case gen_tcp:send(Socket, Response) of
                    ok -> ets:update_counter(?TABLE, {count, Port}, Events,
                                             {{count, Port}, 0});
                    _ -> ok
                end;
            {error, Code} ->
                gen_tcp:send(Socket, error_response(Code))
        end
    catch _:_ -> gen_tcp:send(Socket, error_response(400))
    after gen_tcp:close(Socket)
    end.

read_request(Socket) ->
    case read_head(Socket, <<>>) of
        {ok, Head, Rest} ->
            Lines = binary:split(Head, <<"\r\n">>, [global]),
            case request_length(Lines) of
                {ok, Length} when Length =< ?MAX_BODY ->
                    case read_exact(Socket, Rest, Length) of
                        {ok, Body} ->
                            Raw = <<Head/binary, "\r\n\r\n", Body/binary>>,
                            case unicode:characters_to_binary(Raw, utf8, utf8) of
                                Raw -> {ok, Raw};
                                _ -> {error, 400}
                            end;
                        Error -> Error
                    end;
                {ok, _} -> {error, 413};
                Error -> Error
            end;
        Error -> Error
    end.

read_head(Socket, Acc) ->
    case split_head(Acc) of
        more ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, More} -> read_head(Socket, <<Acc/binary, More/binary>>);
                _ -> {error, 400}
            end;
        Result -> Result
    end.

split_head(Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} when Pos =< ?MAX_HEADER ->
            <<Head:Pos/binary, _Delimiter:4/binary, Rest/binary>> = Acc,
            {ok, Head, Rest};
        {_, 4} -> {error, 413};
        nomatch when byte_size(Acc) > ?MAX_HEADER + 3 -> {error, 413};
        nomatch -> more
    end.

request_length([_RequestLine | Headers]) ->
    Fold = fun(Line, {ok, Current}) ->
                case binary:split(Line, <<":">>) of
                    [Name, Value] ->
                        case string:lowercase(Name) of
                            <<"transfer-encoding">> -> {error, 501};
                            <<"content-length">> ->
                                case parse_nonnegative_length(Value) of
                                    {ok, N} when Current =:= undefined ->
                                        {ok, N};
                                    _ -> {error, 400}
                                end;
                            _ -> {ok, Current}
                        end;
                    _ -> {error, 400}
                end;
              (_, Error) -> Error
           end,
    case lists:foldl(Fold, {ok, undefined}, Headers) of
        {ok, undefined} -> {ok, 0};
        Other -> Other
    end;
request_length(_) -> {error, 400}.

parse_nonnegative_length(Value) ->
    try binary_to_integer(string:trim(Value)) of
        N when N >= 0 -> {ok, N};
        _ -> error
    catch _:_ -> error
    end.

read_exact(_Socket, Rest, Length) when byte_size(Rest) >= Length ->
    <<Body:Length/binary, _/binary>> = Rest,
    {ok, Body};
read_exact(Socket, Rest, Length) ->
    case gen_tcp:recv(Socket, Length - byte_size(Rest), 5000) of
        {ok, More} -> {ok, <<Rest/binary, More/binary>>};
        _ -> {error, 400}
    end.

error_response(Code) ->
    Status = case Code of
                 413 -> <<"413 Payload Too Large">>;
                 501 -> <<"501 Not Implemented">>;
                 _ -> <<"400 Bad Request">>
             end,
    <<"HTTP/1.1 ", Status/binary,
      "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>.
