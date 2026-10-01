-module(mimic_live_test_ffi).
-include_lib("kernel/include/file.hrl").
-export([listen_loopback/0, accept/2, close_listener/1]).
-export([write_private/2, remove_fixture/1]).
-export([peer_read/2]).

%% Only socket OS primitives; synthetic scenario/HTTP orchestration is Gleam.
listen_loopback() ->
    case gen_tcp:listen(0, [binary, {active, false}, {packet, raw},
                           {ip, {127,0,0,1}}, {reuseaddr, false},
                           {send_timeout, 500}, {send_timeout_close, true}]) of
        {ok, Listener} ->
            {ok, {_, Port}} = inet:sockname(Listener),
            {ok, {Listener, Port}};
        {error, _} -> {error, <<"synthetic_listen_failed">>}
    end.
accept(Listener, Timeout) ->
    case gen_tcp:accept(Listener, Timeout) of
        {ok, Socket} -> {ok, {tcp, Socket}};
        {error, _} -> {error, <<"synthetic_accept_failed">>}
    end.
close_listener(Listener) ->
    _ = gen_tcp:close(Listener),
    nil.

%% OS result tags, not a timeout-as-closure heuristic. Gleam decides which
%% observations satisfy the fixture and performs scenario/cleanup orchestration.
peer_read({tcp, Socket}, Timeout) ->
    case inet:setopts(Socket, [{packet, raw}]) of
        ok ->
            case gen_tcp:recv(Socket, 1, Timeout) of
                {error, closed} -> peer_closed;
                {error, econnreset} -> peer_reset;
                {error, timeout} -> peer_timeout;
                {ok, Bytes} -> {peer_data, Bytes};
                _ -> peer_error
            end;
        _ -> peer_error
    end.

%% Test-only, explicitly passed scratch files. Never overwrite an existing
%% path; cleanup accepts only the inode/device token created by this function.
write_private(Path, Bytes) when byte_size(Bytes) =< 16384 ->
    Name = binary_to_list(Path),
    case file:open(Name, [write, binary, raw, exclusive]) of
        {ok, Fd} ->
            Result = case file:change_mode(Name, 8#600) of
                ok ->
                    case file:write(Fd, Bytes) of
                        ok ->
                            case file:read_file_info(Fd) of
                                {ok, #file_info{type = regular, inode = Inode,
                                               major_device = Dev}} ->
                                    {ok, {fixture_file, Path, Inode, Dev}};
                                _ -> {error, <<"synthetic_fixture_stat_failed">>}
                            end;
                        _ -> {error, <<"synthetic_fixture_write_failed">>}
                    end;
                _ -> {error, <<"synthetic_fixture_mode_failed">>}
            end,
            _ = file:close(Fd),
            Result;
        _ -> {error, <<"synthetic_fixture_create_failed">>}
    end;
write_private(_, _) -> {error, <<"synthetic_fixture_size_failed">>}.

remove_fixture({fixture_file, Path, Inode, Dev}) ->
    Name = binary_to_list(Path),
    case file:read_link_info(Name) of
        {ok, #file_info{type = regular, inode = Inode, major_device = Dev}} ->
            case file:delete(Name) of
                ok -> {ok, nil};
                _ -> {error, <<"synthetic_fixture_remove_failed">>}
            end;
        _ -> {error, <<"synthetic_fixture_cleanup_identity_mismatch">>}
    end.
