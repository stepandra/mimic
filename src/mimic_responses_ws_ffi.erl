-module(mimic_responses_ws_ffi).
-export([sha1/1, xor_mask/2]).

sha1(Bytes) -> crypto:hash(sha, Bytes).

%% Only byte arithmetic; role, length, opcode, and mask-key validation are
%% performed by the Gleam codec. Never generate/reuse mask keys here.
xor_mask(Bytes, <<A, B, C, D>>) ->
    xor_mask(Bytes, A, B, C, D, []).

xor_mask(<<X, Y, Z, W, Rest/binary>>, A, B, C, D, Acc) ->
    xor_mask(Rest, A, B, C, D,
             [<<(X bxor A), (Y bxor B), (Z bxor C), (W bxor D)>> | Acc]);
xor_mask(<<X, Y, Z>>, A, B, C, _D, Acc) ->
    iolist_to_binary(lists:reverse([<<(X bxor A), (Y bxor B), (Z bxor C)>> | Acc]));
xor_mask(<<X, Y>>, A, B, _C, _D, Acc) ->
    iolist_to_binary(lists:reverse([<<(X bxor A), (Y bxor B)>> | Acc]));
xor_mask(<<X>>, A, _B, _C, _D, Acc) ->
    iolist_to_binary(lists:reverse([<<(X bxor A)>> | Acc]));
xor_mask(<<>>, _A, _B, _C, _D, Acc) ->
    iolist_to_binary(lists:reverse(Acc)).
