-module(mimic_observability_ffi).
-export([opaque_label/1, increment/2, gauge/3, snapshot/0, integer_to_string/1]).

integer_to_string(Value) -> integer_to_binary(Value).

opaque_label(Label) ->
    Digest = crypto:hash(sha256, Label),
    binary:encode_hex(Digest, lowercase).

table() ->
    case ets:whereis(mimic_observability_metrics) of
        undefined ->
            spawn(fun() ->
                try
                    ets:new(mimic_observability_metrics, [named_table, public, set,
                        {write_concurrency, true}, {read_concurrency, true}]),
                    receive stop -> ok end
                catch error:badarg -> ok end
            end),
            wait_for_table(100);
        T -> T
    end.

wait_for_table(0) -> error(metric_table_unavailable);
wait_for_table(N) ->
    case ets:whereis(mimic_observability_metrics) of
        undefined -> timer:sleep(1), wait_for_table(N - 1);
        T -> T
    end.

increment(Name, Label) ->
    T = table(),
    ets:update_counter(T, {Name, Label}, {2, 1}, {{Name, Label}, 0}),
    nil.

gauge(Name, Label, Value) ->
    ets:insert(table(), {{Name, Label}, Value}),
    nil.

snapshot() ->
    [{Name, Label, Value} || {{Name, Label}, Value} <- ets:tab2list(table())].
