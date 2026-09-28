-module(mimic_provider_ws_ffi).
-export([recv/2, random/1]).

%% Socket ownership, TLS verification, handshake I/O and send deadlines use
%% mimic_egress_ffi. This module only adds a bounded raw read and CSPRNG bytes.
recv({tcp, Socket}, Timeout) ->
    case inet:setopts(Socket, [{packet, raw}, {recbuf, 8192}]) of
        ok -> result(gen_tcp:recv(Socket, 0, Timeout));
        {error, Reason} -> {error, reason(Reason)}
    end;
recv({tls, Socket}, Timeout) ->
    case ssl:setopts(Socket, [{packet, raw}, {recbuf, 8192}]) of
        ok -> result(ssl:recv(Socket, 0, Timeout));
        {error, Reason} -> {error, reason(Reason)}
    end.

result({ok, Bytes}) when byte_size(Bytes) =< 1048590 -> {ok, {some, Bytes}};
result({ok, _}) -> {error, <<"WS read exceeds chunk limit">>};
result({error, timeout}) -> {ok, none};
result({error, Reason}) -> {error, reason(Reason)}.

random(Length) -> crypto:strong_rand_bytes(Length).

reason(closed) -> <<"WS socket closed">>;
reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("WS socket error: ~p", [Reason])).
