%% Synthetic local test primitives only: private files and raw loopback HTTP.
-module(mimic_account_ui_test_ffi).
-export([focused/0, write_private/2, request/5, mkdir/1, rmdir/1, clean/1,
         clock_new/1, clock_get/1, clock_set/2]).

focused() ->
    eunit:test([account_ui_test, account_ui_coordinator_test],
               [verbose, {scale_timeouts, 20}]) =:= ok.

clock_new(Now) ->
    Table = ets:new(synthetic_clock, [set, protected]),
    true = ets:insert(Table, {now, Now}),
    Table.

clock_get(Table) -> ets:lookup_element(Table, now, 2).

clock_set(Table, Now) ->
    true = ets:insert(Table, {now, Now}),
    nil.

write_private(Path, Contents) ->
    ok = file:write_file(Path, Contents),
    ok = file:change_mode(Path, 8#600),
    nil.

mkdir(Path) ->
    ok = file:make_dir(Path),
    nil.

rmdir(Path) ->
    ok = file:del_dir(Path),
    nil.

clean(Directory) ->
    {ok, Names} = file:list_dir(Directory),
    not lists:any(fun(Name) ->
        lists:prefix(".mutation-", Name) orelse
        lists:prefix("account-ui-bootstrap-", Name) orelse
        Name =:= ".provider-runtime-owner"
    end, Names).

request(Port, Method, Path, Headers, Body) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port,
                                 [binary, {active, false}], 5000),
    HasHost = lists:keymember(<<"Host">>, 1, Headers),
    HasLength = lists:keymember(<<"Content-Length">>, 1, Headers),
    Base = case HasHost of
        true -> Headers;
        false -> [{<<"Host">>, <<"127.0.0.1:", (integer_to_binary(Port))/binary>>} | Headers]
    end,
    All = case HasLength of
        true -> Base;
        false -> [{<<"Content-Length">>, integer_to_binary(byte_size(Body))} | Base]
    end,
    Wire = [Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
            [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- All],
            <<"Connection: close\r\n\r\n">>, Body],
    ok = gen_tcp:send(Socket, Wire),
    Raw = collect(Socket, <<>>),
    gen_tcp:close(Socket),
    parse_response(Raw).

parse_response(<<>>) ->
    %% Mist rejects malformed raw headers by closing before the handler.
    {0, [], <<>>};
parse_response(Raw) ->
    [Head, ResponseBody] = binary:split(Raw, <<"\r\n\r\n">>),
    [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    [_, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
    Parsed = [begin
                  [K, V] = binary:split(Line, <<":">>),
                  {string:lowercase(K), string:trim(V)}
              end || Line <- Lines],
    {binary_to_integer(Status), Parsed, ResponseBody}.

collect(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 15000) of
        {ok, Chunk} -> collect(Socket, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> Acc;
        {error, timeout} -> error(local_http_timeout)
    end.
