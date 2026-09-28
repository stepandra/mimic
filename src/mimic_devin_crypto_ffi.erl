-module(mimic_devin_crypto_ffi).
-export([random_bytes/1, sha256/1, os_name/0]).

random_bytes(Size) -> crypto:strong_rand_bytes(Size).
sha256(Bytes) -> crypto:hash(sha256, Bytes).
os_name() ->
    case os:type() of
        {unix, darwin} -> <<"darwin">>;
        {unix, linux} -> <<"linux">>;
        {win32, _} -> <<"windows">>;
        _ -> <<"unsupported">>
    end.
