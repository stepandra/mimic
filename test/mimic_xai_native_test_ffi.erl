-module(mimic_xai_native_test_ffi).
-export([leaf/2, cleanup/1]).

%% Local synthetic TLS only. Reuse the existing CA/leaf primitive.
leaf(Cert, Key) ->
    case mimic_recorder_tls_ffi:make_leaf(binary_to_list(Cert),
                                         binary_to_list(Key), "127.0.0.1") of
        {ok, Temp, Leaf, LeafKey} ->
            {ok, {list_to_binary(Temp),
                  {list_to_binary(Leaf), list_to_binary(LeafKey)}}};
        _ -> {error, <<"synthetic TLS leaf failed">>}
    end.

cleanup(Temp) ->
    mimic_recorder_tls_ffi:cleanup(binary_to_list(Temp)),
    nil.
