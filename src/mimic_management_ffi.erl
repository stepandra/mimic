-module(mimic_management_ffi).
-export([management_key/0, equal/2, process_forever/0, asset/1]).

management_key() ->
    case os:getenv("MIMIC_MANAGEMENT_KEY") of
        false -> {error, <<"MIMIC_MANAGEMENT_KEY is required">>};
        Value when length(Value) >= 32 -> {ok, unicode:characters_to_binary(Value)};
        _ -> {error, <<"MIMIC_MANAGEMENT_KEY must be at least 32 bytes">>}
    end.

equal(A, B) when is_binary(A), is_binary(B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B));
equal(_, _) -> false.

process_forever() -> receive stop -> nil end.

asset(<<"index.html">>) -> read_asset("index.html");
asset(<<"panel.js">>) -> read_asset("panel.js");
asset(<<"panel.css">>) -> read_asset("panel.css");
asset(_) -> {error, <<"invalid asset">>}.

read_asset(Name) ->
    case code:priv_dir(mimic) of
        {error, _} -> source_asset(Name);
        Root ->
            case file:read_file(filename:join([Root, "management", Name])) of
                {ok, Data} -> {ok, Data};
                {error, _} -> source_asset(Name)
            end
    end.

%% Source checkout fallback for `gleam test` / development. Release packaging
%% must include priv/management in the application priv directory.
source_asset(Name) ->
    case file:read_file(filename:join(["priv", "management", Name])) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, <<"panel assets unavailable">>}
    end.
