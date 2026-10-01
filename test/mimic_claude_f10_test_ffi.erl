%% Synthetic two-account loopback upstream. Captures only test-owned requests.
-module(mimic_claude_f10_test_ffi).
-export([start/1, start_script/1, port/1, requests/1, closed/1, sent/1, stop/1,
         fresh_vm/4, with_cli/3, directory/0, private_file/3]).

directory() ->
    Root = filename:absname("build/f10/state"),
    ok = filelib:ensure_dir(filename:join(Root, ".init")),
    ok = file:change_mode(filename:dirname(Root), 8#700),
    ok = file:change_mode(Root, 8#700),
    Path = filename:join(Root, binary_to_list(
        binary:encode_hex(crypto:strong_rand_bytes(12)))),
    ok = file:make_dir(Path),
    ok = file:change_mode(Path, 8#700),
    list_to_binary(Path).

private_file(Dir, Name, Content) ->
    Path = filename:join(binary_to_list(Dir), binary_to_list(Name)),
    ok = file:write_file(Path, Content),
    ok = file:change_mode(Path, 8#600),
    list_to_binary(Path).

start(Responses) ->
    start_script([[{0, Response}] || Response <- Responses]).

%% Delay/send vectors only; all protocol decisions stay in Gleam tests.
start_script(Responses) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Table = ets:new(?MODULE, [public, ordered_set]),
    Closed = atomics:new(1, []),
    Pid = spawn(fun() -> accept(Listener, Responses, Table, Closed) end),
    {Listener, Pid, Port, Table, Closed}.

accept(Listener, [Response | Remaining] = Responses, Table, Closed) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            Worker = spawn(fun() ->
                receive ready ->
                    try serve(Socket, Response, Table, Closed)
                    after gen_tcp:close(Socket) end
                end
            end),
            ets:insert(Table, {{worker, Worker}, Worker}),
            ok = gen_tcp:controlling_process(Socket, Worker),
            Worker ! ready,
            Next = case Remaining of [] -> Responses; _ -> Remaining end,
            accept(Listener, Next, Table, Closed);
        _ -> ok
    end.

serve(Socket, Response, Table, Closed) ->
    case read_request(Socket, []) of
        {ok, Request} ->
            ets:insert(Table, {{request, erlang:unique_integer([monotonic])}, Request}),
            %% In the stalled-body scenario only headers are sent. The client
            %% must close without waiting for the withheld body or this timeout.
            Sent = send_script(Socket, Response, Table),
            Result = case Sent of ok -> gen_tcp:recv(Socket, 0, 5000); _ -> Sent end,
            case Result of
                {error, closed} -> atomics:add_get(Closed, 1, 1);
                {error, econnreset} -> atomics:add_get(Closed, 1, 1);
                _ -> ok
            end;
        _ -> ok
    end.

send_script(_, [], _) -> ok;
%% OS-only half-close sentinel; the Gleam fixture decides when to truncate.
send_script(Socket, [{-1, <<>>} | Rest], Table) ->
    case gen_tcp:shutdown(Socket, write) of
        ok -> send_script(Socket, Rest, Table);
        Error -> Error
    end;
send_script(Socket, [{Delay, Bytes} | Rest], Table) ->
    timer:sleep(Delay),
    case gen_tcp:send(Socket, Bytes) of
        ok ->
            ets:insert(Table, {{sent, erlang:unique_integer([monotonic])}, true}),
            send_script(Socket, Rest, Table);
        Error -> Error
    end.

read_request(Socket, Acc) ->
    ok = inet:setopts(Socket, [{packet, line}]),
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, <<"\r\n">>} ->
            Headers = iolist_to_binary(lists:reverse([<<"\r\n">> | Acc])),
            Length = case re:run(Headers, <<"[Cc]ontent-[Ll]ength: *([0-9]+)">>,
                                [{capture, [1], binary}]) of
                {match, [Value]} -> binary_to_integer(Value);
                _ -> 0
            end,
            ok = inet:setopts(Socket, [{packet, raw}]),
            case Length of
                0 -> {ok, Headers};
                _ -> case gen_tcp:recv(Socket, Length, 5000) of
                    {ok, Body} -> {ok, <<Headers/binary, Body/binary>>};
                    Error -> Error
                end
            end;
        {ok, Line} -> read_request(Socket, [Line | Acc]);
        Error -> Error
    end.

port({_, _, Port, _, _}) -> Port.
requests({_, _, _, Table, _}) ->
    [Raw || {{request, _}, Raw} <- ets:tab2list(Table)].
closed({_, _, _, _, Closed}) -> atomics:get(Closed, 1).
sent({_, _, _, Table, _}) ->
    length([ok || {{sent, _}, _} <- ets:tab2list(Table)]).
stop({Listener, Pid, _, Table, _}) ->
    gen_tcp:close(Listener),
    exit(Pid, kill),
    [exit(Worker, kill) || {{worker, Worker}, _} <- ets:tab2list(Table)],
    ets:delete(Table),
    nil.

%% OS process primitive only. Protocol, assertions, account selection and
%% credentials stay in the Gleam scenario. Argument vectors, no shell or
%% interpolation into eval code; complete child output is returned, not trimmed.
fresh_vm(ConfigPath, Operation, Streaming, ExpectedStatus) ->
    Erl = os:find_executable("erl"),
    Paths = [filename:absname(P) || P <- code:get_path()],
    Code = "{ok,_}=application:ensure_all_started(mimic),"
           "claude_f10_scenario:fresh_vm(),halt(0).",
    Port = open_port({spawn_executable, Erl},
        [binary, exit_status, use_stdio, stderr_to_stdout,
         {args, ["+S", "2:2", "+A", "2", "-noshell", "-pa"] ++ Paths ++
            ["-eval", Code, "-extra", binary_to_list(ConfigPath),
             binary_to_list(Operation), atom_to_list(Streaming),
             integer_to_list(ExpectedStatus)]}]),
    wait_vm(Port, [], erlang:monotonic_time(millisecond) + 10000).

wait_vm(Port, Output, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bytes}} -> wait_vm(Port, [Bytes | Output], Deadline);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Output))}
    after Remaining ->
        port_close(Port),
        {-1, iolist_to_binary(lists:reverse(Output))}
    end.

%% Own a candidate process group during a Gleam action. The Python helper is
%% only OS lifecycle/output copying; no HTTP/credential/retry policy in FFI.
with_cli(Executable, Args, Action) ->
    Python = os:find_executable("python3"),
    Helper = filename:absname("test/fixtures/claude/f10/cli_process.py"),
    Port = open_port({spawn_executable, Python},
        [binary, exit_status, use_stdio, stderr_to_stdout,
         {args, [Helper, binary_to_list(Executable)] ++
            [binary_to_list(Arg) || Arg <- Args]}]),
    Passed = try Action(), true catch _:_ -> false end,
    try port_command(Port, <<"stop\n">>) catch _:_ -> false end,
    {Exit, Output} = wait_vm(Port, [], erlang:monotonic_time(millisecond) + 15000),
    {Passed, Exit, Output}.
