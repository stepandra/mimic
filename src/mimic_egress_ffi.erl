-module(mimic_egress_ffi).
-export([connect/4, write/3, line/2, bytes/3, probe/1, close/1, now_ms/0]).

%% Socket operations only. HTTP status, headers and message framing are
%% interpreted by mimic/egress.gleam. A socket is owned by its Gleam actor.
connect(Host, Port, false, Timeout) ->
    Options = [binary, {active, false}, {packet, raw},
               {send_timeout, Timeout}, {send_timeout_close, true}],
    wrap_connect(gen_tcp:connect(binary_to_list(Host), Port, Options, Timeout), tcp);
connect(Host, Port, true, Timeout) ->
    _ = ssl:start(),
    Options = [binary, {active, false}, {packet, raw},
               {verify, verify_peer},
               {cacerts, public_key:cacerts_get()},
               {server_name_indication, binary_to_list(Host)},
               {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
               {alpn_advertised_protocols, [<<"http/1.1">>]},
               {send_timeout, Timeout}, {send_timeout_close, true}],
    case ssl:connect(binary_to_list(Host), Port, Options, Timeout) of
        {ok, Socket} ->
            case ssl:negotiated_protocol(Socket) of
                {ok, <<"http/1.1">>} -> {ok, {tls, Socket}};
                {error, protocol_not_negotiated} -> {ok, {tls, Socket}};
                _ ->
                    ssl:close(Socket),
                    {error, <<"TLS peer did not negotiate HTTP/1.1">>}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

wrap_connect({ok, Socket}, Type) -> {ok, {Type, Socket}};
wrap_connect({error, Reason}, _) -> {error, format_error(Reason)}.

write({tcp, Socket}, Data, _Timeout) -> wrap_ok(gen_tcp:send(Socket, Data));
write({tls, Socket}, Data, _Timeout) -> wrap_ok(ssl:send(Socket, Data)).

line(Connection, Timeout) ->
    case set_packet(Connection, line) of
        ok ->
            case recv(Connection, 0, Timeout) of
                {ok, Bytes} -> utf8(Bytes);
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

bytes(_Connection, 0, _Timeout) -> {ok, <<>>};
bytes(Connection, Length, Timeout) when Length > 0 ->
    case set_packet(Connection, raw) of
        ok ->
            case recv(Connection, Length, Timeout) of
                {ok, Bytes} -> {ok, Bytes};
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, Reason} -> {error, format_error(Reason)}
    end.

%% Only an already-observed EOF is reconnected before the next send. A close
%% racing this probe and the write can still fail that request; never replay it.
probe(Connection) ->
    case set_packet(Connection, raw) of
        ok ->
            case recv(Connection, 0, 0) of
                {error, timeout} -> {ok, true};
                {error, closed} -> {ok, false};
                {ok, _Unexpected} ->
                    {error, <<"unexpected bytes after framed response">>};
                {error, Reason} -> {error, format_error(Reason)}
            end;
        {error, closed} -> {ok, false};
        {error, Reason} -> {error, format_error(Reason)}
    end.

set_packet({tcp, Socket}, Packet) ->
    inet:setopts(Socket, [{packet, Packet}, {packet_size, 8192}]);
set_packet({tls, Socket}, Packet) ->
    ssl:setopts(Socket, [{packet, Packet}, {packet_size, 8192}]).

recv({tcp, Socket}, Length, Timeout) -> gen_tcp:recv(Socket, Length, Timeout);
recv({tls, Socket}, Length, Timeout) -> ssl:recv(Socket, Length, Timeout).

close({tcp, Socket}) -> gen_tcp:close(Socket);
close({tls, Socket}) -> ssl:close(Socket).

now_ms() -> erlang:monotonic_time(millisecond).

wrap_ok(ok) -> {ok, nil};
wrap_ok({error, Reason}) -> {error, format_error(Reason)}.

utf8(Bytes) ->
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Value when is_binary(Value) -> {ok, Value};
        _ -> {error, <<"non-UTF-8 response header">>}
    end.

format_error(Reason) ->
    unicode:characters_to_binary(io_lib:format("socket error: ~p", [Reason])).
