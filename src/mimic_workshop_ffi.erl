-module(mimic_workshop_ffi).
-include_lib("kernel/include/file.hrl").
-export([create/4, load/2, update/3, artifact/2, has_artifact/2,
         read_artifact/2, authorize_review/4, authorize_abandon/3, authorize_rollback/2,
         swap/4, lab_swap/3, pointer/2, rollback/3,
         with_effect/3, effect_idle/2]).

%% These locks are deliberately fail-closed. A killed VM may leave .lock;
%% an operator must establish that no writer is alive before removing it.
locked(Dir, Fun) ->
    case ensure_private(Dir) of
        ok ->
            Lock = filename:join(Dir, ".lock"),
            case file:make_dir(Lock) of
                ok ->
                    try Fun() after file:del_dir(Lock) end;
                {error, eexist} -> {error, <<"state directory locked; inspect owner before recovery">>};
                {error, Reason} -> err(Reason)
            end;
        {error, Reason} -> err(Reason)
    end.

ensure_private(Dir) ->
    case filelib:ensure_dir(filename:join(Dir, "x")) of
        ok ->
            case file:read_link_info(Dir) of
                {ok, #file_info{type = directory}} -> file:change_mode(Dir, 8#700);
                _ -> {error, untrusted_state_directory}
            end;
        Error -> Error
    end.

err(Reason) -> {error, unicode:characters_to_binary(io_lib:format("storage error: ~p", [Reason]))}.
key(Value) ->
    binary:encode_hex(crypto:hash(sha256, Value), lowercase).
run_path(Dir, Id) -> filename:join([Dir, "runs", key(Id)]).
active_path(Dir, Provider) -> filename:join([Dir, "active", key(Provider)]).
registry_path(Dir, Provider) -> filename:join([Dir, "registry", key(Provider)]).
effect_path(Dir, Id) -> filename:join([Dir, "effects", key(Id)]).

%% Hold an exclusive per-run effect guard across reservation, callback, and
%% checkpoint publication. A killed VM leaves the guard in place; recovery
%% requires verifying no callback survives before removing it.
with_effect(Dir, Id, Fun) ->
    Path = effect_path(Dir, Id),
    case ensure_private(Dir) of
        ok ->
            case ensure_parent(Path) of
                ok ->
                    case file:make_dir(Path) of
                        ok ->
                            case file:change_mode(Path, 8#700) of
                                ok -> try Fun() after file:del_dir(Path) end;
                                {error, Reason} -> file:del_dir(Path), err(Reason)
                            end;
                        {error, eexist} ->
                            {error, <<"stage effect active or stale; inspect before recovery">>};
                        {error, Reason} -> err(Reason)
                    end;
                {error, Reason} -> err(Reason)
            end;
        {error, Reason} -> err(Reason)
    end.

effect_idle(Dir, Id) ->
    case file:read_link_info(effect_path(Dir, Id)) of
        {error, enoent} -> true;
        _ -> false
    end.

read_term(Path) ->
    case {trusted_parent(Path), file:read_link_info(Path)} of
        {ok, {ok, #file_info{type = regular}}} ->
            case file:read_file(Path) of
                {ok, Bytes} ->
                    try
                        Term = binary_to_term(Bytes, [safe]),
                        case valid_term(Term) of
                            true -> {ok, Term};
                            false -> {error, <<"invalid checkpoint schema">>}
                        end
                    catch _:_ -> {error, <<"invalid checkpoint">>} end;
                {error, Reason} -> err(Reason)
            end;
        {ok, {error, Reason}} -> err(Reason);
        _ -> {error, <<"untrusted state file">>}
    end.

%% Pattern literals register the finite persisted vocabulary in this module
%% before [safe] decoding. In particular `evidence` is otherwise only emitted
%% by a stage adapter and is not loaded by workshop in a fresh VM. Do not
%% replace [safe] with unrestricted atom creation.
valid_term(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_term({registry, Current, Previous}) ->
    valid_digest(Current) andalso
        (Previous =:= none orelse valid_digest(Previous));
valid_term({run, Id, Provider, Kind, Class, Completed, Reviewer, Status,
            OracleRuns, Tokens, Goal}) ->
    nonempty(Id) andalso nonempty(Provider) andalso valid_kind(Kind) andalso
        valid_class_option(Class) andalso is_list(Completed) andalso
        lists:all(fun valid_evidence/1, Completed) andalso
        valid_text_option(Reviewer) andalso valid_status(Status) andalso
        is_integer(OracleRuns) andalso OracleRuns >= 0 andalso
        is_integer(Tokens) andalso Tokens >= 0 andalso valid_text_option(Goal);
valid_term(_) -> false.

nonempty(Value) -> is_binary(Value) andalso byte_size(Value) > 0.
valid_kind(p_b) -> true;
valid_kind(p_o) -> true;
valid_kind(c_o) -> true;
valid_kind(_) -> false.
valid_class_option(none) -> true;
valid_class_option({some, Class}) -> valid_class(Class);
valid_class_option(_) -> false.
valid_class(trivial) -> true;
valid_class(minor) -> true;
valid_class(major) -> true;
valid_class(breaking) -> true;
valid_class(_) -> false.
valid_text_option(none) -> true;
valid_text_option({some, Text}) -> nonempty(Text);
valid_text_option(_) -> false.
valid_status(running) -> true;
valid_status(complete) -> true;
valid_status({in_flight, Stage}) -> valid_stage(Stage);
valid_status({paused, Reason}) -> nonempty(Reason);
valid_status({failed, Reason}) -> nonempty(Reason);
valid_status(_) -> false.
valid_evidence({evidence, Stage, Artifact, Passed, Class, Source}) ->
    valid_stage(Stage) andalso valid_digest(Artifact) andalso
        (Passed =:= true orelse Passed =:= false) andalso
        valid_class_option(Class) andalso nonempty(Source);
valid_evidence(_) -> false.
valid_stage(acquire) -> true;
valid_stage(capture) -> true;
valid_stage(diff) -> true;
valid_stage(classify) -> true;
valid_stage(hypothesis) -> true;
valid_stage(lint) -> true;
valid_stage(oracle) -> true;
valid_stage(canary) -> true;
valid_stage(intake) -> true;
valid_stage(auth_capture) -> true;
valid_stage(census) -> true;
valid_stage(author) -> true;
valid_stage(enroll_templates) -> true;
valid_stage(login) -> true;
valid_stage(verify) -> true;
valid_stage(burn_in) -> true;
valid_stage(enroll) -> true;
valid_stage(probation) -> true;
valid_stage(_) -> false.

trusted_parent(Path) ->
    Parent = filename:dirname(Path),
    Root = filename:dirname(Parent),
    case {file:read_link_info(Root), file:read_link_info(Parent)} of
        {{ok, #file_info{type = directory}}, {ok, #file_info{type = directory}}} -> ok;
        _ -> {error, untrusted_state_directory}
    end.
write_term(Path, Value) ->
    atomic(Path, term_to_binary(Value)).
atomic(Path, Bytes) ->
    case ensure_parent(Path) of
        ok ->
            Temp = filename:join(filename:dirname(Path),
                binary_to_list(filename:basename(Path)) ++ "." ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12), lowercase))),
            case file:open(Temp, [write, binary, exclusive, raw]) of
                {ok, Io} ->
                    Mode = file:change_mode(Temp, 8#600),
                    Write = file:write(Io, Bytes),
                    Sync = file:sync(Io),
                    Close = file:close(Io),
                    case {Mode, Write, Sync, Close} of
                        {ok, ok, ok, ok} ->
                            case file:rename(Temp, Path) of
                                ok -> {ok, nil};
                                {error, Why} -> file:delete(Temp), err(Why)
                            end;
                        Failure -> file:delete(Temp), err(Failure)
                    end;
                {error, Reason} -> err(Reason)
            end;
        {error, Reason} -> err(Reason)
    end.

ensure_parent(Path) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Parent = filename:dirname(Path),
            case file:read_link_info(Parent) of
                {ok, #file_info{type = directory}} ->
                    file:change_mode(Parent, 8#700);
                _ -> {error, untrusted_state_directory}
            end;
        Error -> Error
    end.

create(Dir, Id, Provider, Run) ->
    locked(Dir, fun() ->
        Path = run_path(Dir, Id),
        Active = active_path(Dir, Provider),
        case {read_term(Path), active_owner(Dir, Provider)} of
            {{ok, Run}, {ok, Id}} ->
                %% An exact, still-initial checkpoint is an idempotent start.
                {ok, Run};
            {{ok, _}, _} -> {error, <<"run id already exists">>};
            {{error, _}, {ok, _}} ->
                {error, <<"provider already has an active run">>};
            {{error, _}, none} ->
                case {file:read_link_info(Path), file:read_link_info(Active)} of
                    {{error, enoent}, {error, enoent}} -> create_new(Path, Active, Id, Run);
                    _ -> {error, <<"checkpoint or active owner unreadable">>}
                end;
            {_, corrupt} -> {error, <<"active owner unreadable">>}
        end
    end).

active_owner(Dir, Provider) ->
    Path = active_path(Dir, Provider),
    case read_term(Path) of
        {ok, Owner} when is_binary(Owner) ->
            case load(Dir, Owner) of
                {ok, {run, Owner, Provider, _, _, _, _, complete, _, _, _}} ->
                    case file:delete(Path) of
                        ok -> orphan_owner(Dir, Provider);
                        _ -> corrupt
                    end;
                {ok, {run, Owner, Provider, _, _, _, _, {failed, _}, _, _, _}} ->
                    case file:delete(Path) of
                        ok -> orphan_owner(Dir, Provider);
                        _ -> corrupt
                    end;
                {ok, {run, Owner, Provider, _, _, _, _, _, _, _, _}} -> {ok, Owner};
                _ -> corrupt
            end;
        _ ->
            case file:read_link_info(Path) of
                {error, enoent} -> orphan_owner(Dir, Provider);
                _ -> corrupt
            end
    end.

orphan_owner(Dir, Provider) ->
    Runs = filename:join(Dir, "runs"),
    case file:read_link_info(Runs) of
        {error, enoent} -> none;
        {ok, #file_info{type = directory}} ->
            case file:list_dir(Runs) of
                {ok, Names} ->
                    case orphan_runs(Runs, Provider, Names, none) of
                        {ok, Owner} ->
                            case write_term(active_path(Dir, Provider), Owner) of
                                {ok, nil} -> {ok, Owner};
                                _ -> corrupt
                            end;
                        Result -> Result
                    end;
                _ -> corrupt
            end;
        _ -> corrupt
    end.

orphan_runs(_, _, [], Result) -> Result;
orphan_runs(Runs, Provider, [Name | Rest], Found) ->
    case valid_digest(unicode:characters_to_binary(Name)) of
        false -> orphan_runs(Runs, Provider, Rest, Found);
        true ->
            case read_term(filename:join(Runs, Name)) of
                {ok, {run, Owner, Provider, _, _, _, _, Status, _, _, _}}
                    when is_binary(Owner) ->
                    case key(Owner) =:= unicode:characters_to_binary(Name) of
                        false -> corrupt;
                        true ->
                            case {Status, Found} of
                                {complete, _} -> orphan_runs(Runs, Provider, Rest, Found);
                                {{failed, _}, _} -> orphan_runs(Runs, Provider, Rest, Found);
                                {_, none} -> orphan_runs(Runs, Provider, Rest, {ok, Owner});
                                _ -> corrupt
                            end
                    end;
                {ok, {run, _, _, _, _, _, _, _, _, _, _}} ->
                    orphan_runs(Runs, Provider, Rest, Found);
                _ -> corrupt
            end
    end.

create_new(Path, Active, Id, Run) ->
    case write_term(Path, Run) of
        {ok, nil} ->
            case write_term(Active, Id) of
                {ok, nil} -> {ok, Run};
                %% Keep the checkpoint for exact-match recovery;
                %% deleting it may erase a successfully published run.
                Error -> Error
            end;
        Error -> Error
    end.

load(Dir, Id) ->
    case read_term(run_path(Dir, Id)) of
        {ok, {run, Id, _, _, _, _, _, _, _, _, _} = Run} -> {ok, Run};
        {ok, _} -> {error, <<"checkpoint id or format mismatch">>};
        Error -> Error
    end.

update(Dir, Id, Change) ->
    locked(Dir, fun() ->
        case load(Dir, Id) of
            {ok, {run, Id, Provider, _, _, _, _, _, _, _, _} = Run} ->
                case read_term(active_path(Dir, Provider)) of
                    {ok, Id} -> update_owned(Dir, Id, Provider, Run, Change);
                    _ -> {error, <<"run is not the active provider owner">>}
                end;
            Error -> Error
        end
    end).

update_owned(Dir, Id, Provider, Run, Change) ->
    case Change(Run) of
        {ok, {run, Id, Provider, _, _, _, _, Status, _, _, _} = New} ->
            Alert = case Status of
                {paused, <<"BREAKING:", _/binary>>} ->
                    write_term(filename:join([Dir, "alerts", key(Id)]),
                        {breaking, Id, Provider});
                _ -> {ok, nil}
            end,
            case Alert of
                {error, _} = Error -> Error;
                {ok, nil} -> persist_update(Dir, Id, Provider, Status, New)
            end;
        {ok, _} -> {error, <<"invalid run transition">>};
        Error -> Error
    end.

persist_update(Dir, Id, Provider, Status, New) ->
    case write_term(run_path(Dir, Id), New) of
        {ok, nil} ->
            case Status of
                complete -> release_owner(Dir, Provider, Id, New);
                {failed, _} -> release_owner(Dir, Provider, Id, New);
                _ -> {ok, New}
            end;
        Error -> Error
    end.

release_owner(Dir, Provider, Id, New) ->
    Path = active_path(Dir, Provider),
    case read_term(Path) of
        {ok, Id} ->
            case file:delete(Path) of
                ok -> {ok, New};
                {error, Reason} -> err(Reason)
            end;
        _ -> {error, <<"active owner changed; inspect checkpoint">>}
    end.

artifact(Dir, Content) ->
    Digest = key(Content),
    Path = filename:join([Dir, "artifacts", Digest]),
    locked(Dir, fun() ->
        case file:read_link_info(Path) of
            {ok, #file_info{type = regular}} ->
                case read_artifact(Dir, Digest) of
                    {ok, Content} -> {ok, Digest};
                    _ -> {error, <<"artifact hash collision or corrupt artifact">>}
                end;
            {error, enoent} ->
                %% Publish only a fully written and synced temporary object.
                %% A failed write cannot poison the final digest path.
                case atomic(Path, Content) of
                    {ok, nil} -> {ok, Digest};
                    Error -> Error
                end;
            _ -> {error, <<"untrusted artifact slot">>}
        end
    end).

has_artifact(Dir, Id) ->
    case read_artifact(Dir, Id) of
        {ok, _} -> true;
        _ -> false
    end.

read_artifact(Dir, Id) ->
    case valid_digest(Id) of
        false -> {error, <<"invalid artifact digest">>};
        true ->
            Path = filename:join([Dir, "artifacts", Id]),
            case {trusted_parent(Path), file:read_link_info(Path)} of
                {ok, {ok, #file_info{type = regular}}} ->
                    case file:read_file(Path) of
                        {ok, Bytes} ->
                            case key(Bytes) =:= Id of
                                true -> {ok, Bytes};
                                false -> {error, <<"artifact digest mismatch">>}
                            end;
                        _ -> {error, <<"artifact not found">>}
                    end;
                _ -> {error, <<"artifact not found">>}
            end
    end.

valid_digest(Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                        (C >= $a andalso C =< $f) end,
              binary_to_list(Id));
valid_digest(_) -> false.

authorize_review(Id, Reviewer, Candidate, Signature) ->
    authorize("MIMIC_REVIEW_KEY", <<Id/binary, 0, Reviewer/binary, 0, Candidate/binary>>, Signature).
authorize_abandon(Id, Reason, Signature) ->
    authorize("MIMIC_REVIEW_KEY", <<Id/binary, 0, "abandon", 0, Reason/binary>>, Signature).
authorize_rollback(Provider, Signature) ->
    authorize("MIMIC_PROMOTION_KEY", <<Provider/binary, 0, "rollback">>, Signature).
authorize(Variable, Message, Signature) ->
    case os:getenv(Variable) of
        false -> {error, <<"operator authorization key not configured">>};
        Key ->
            Expected = binary:encode_hex(crypto:mac(hmac, sha256, Key, Message), lowercase),
            case Signature =:= Expected of
                true -> {ok, nil};
                false -> {error, <<"invalid operator authorization">>}
            end
    end.

%% The supplied signature is verified against the operator-owned signing key.
%% The key is never stored in the state directory.
swap(Dir, Provider, Candidate, Signature) ->
    case os:getenv("MIMIC_PROMOTION_KEY") of
        false -> {error, <<"MIMIC_PROMOTION_KEY not configured">>};
        Key ->
            Expected = binary:encode_hex(
                crypto:mac(hmac, sha256, Key, <<Provider/binary, 0, Candidate/binary>>),
                lowercase),
            case Signature =:= Expected andalso has_artifact(Dir, Candidate) of
                false -> {error, <<"invalid promotion signature or candidate">>};
                true -> locked(Dir, fun() ->
                    Path = registry_path(Dir, Provider),
                    case read_term(Path) of
                        {ok, {registry, Candidate, _}} -> {ok, Candidate};
                        PreviousRecord ->
                            Previous = case PreviousRecord of
                                {ok, {registry, Current, _}} -> Current;
                                _ -> none
                            end,
                            case write_term(Path, {registry, Candidate, Previous}) of
                                {ok, nil} -> {ok, Candidate};
                                Error -> Error
                            end
                    end
                end)
            end
    end.

lab_swap(Dir, <<"synthetic-lab">> = Provider, Candidate) ->
    case has_artifact(Dir, Candidate) of
        false -> {error, <<"candidate artifact missing">>};
        true -> locked(Dir, fun() ->
            Path = registry_path(Dir, Provider),
            case read_term(Path) of
                {ok, {registry, Candidate, _}} -> {ok, Candidate};
                PreviousRecord ->
                    Previous = case PreviousRecord of
                        {ok, {registry, Current, _}} -> Current;
                        _ -> none
                    end,
                    case write_term(Path, {registry, Candidate, Previous}) of
                        {ok, nil} -> {ok, Candidate};
                        Error -> Error
                    end
            end
        end)
    end;
lab_swap(_, _, _) -> {error, <<"lab registry is synthetic-lab only">>}.

pointer(Dir, Provider) ->
    case read_term(registry_path(Dir, Provider)) of
        {ok, {registry, Current, _}} when is_binary(Current) -> {ok, Current};
        _ -> {error, <<"no promoted persona">>}
    end.

rollback(Dir, Provider, Signature) ->
    case authorize_rollback(Provider, Signature) of
        {ok, nil} ->
            locked(Dir, fun() ->
                Path = registry_path(Dir, Provider),
                case read_term(Path) of
                    {ok, {registry, _Current, Previous}} when is_binary(Previous) ->
                        case has_artifact(Dir, Previous) of
                            false -> {error, <<"rollback artifact missing or corrupt">>};
                            true ->
                                case write_term(Path, {registry, Previous, none}) of
                                    {ok, nil} -> {ok, Previous};
                                    Error -> Error
                                end
                        end;
                    _ -> {error, <<"no rollback pointer">>}
                end
            end);
        Error -> Error
    end.
