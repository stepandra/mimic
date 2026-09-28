-module(mimic_quota_ffi).
-export([http_date_ms/1, rfc3339_ms/1]).

%% HTTP date parsing is a small platform primitive. The ledger's cooldown
%% policy remains in Gleam.
http_date_ms(Value) ->
    try
        DateTime = httpd_util:convert_request_date(binary_to_list(Value)),
        case DateTime of
            {{_, _, _}, {_, _, _}} ->
                UnixEpoch = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
                {ok, (calendar:datetime_to_gregorian_seconds(DateTime) - UnixEpoch) * 1000};
            _ -> {error, nil}
        end
    catch _:_ -> {error, nil} end.

rfc3339_ms(Value) ->
    try
        {ok, calendar:rfc3339_to_system_time(binary_to_list(Value), [{unit, millisecond}])}
    catch _:_ -> {error, nil} end.
