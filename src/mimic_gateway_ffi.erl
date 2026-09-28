%% Gateway-only primitives: private credential ingestion, scoped key identity,
%% and a graceful CLI SIGTERM. Never print or return private file contents to
%% diagnostics; the Gleam caller validates provider-specific JSON.
-module(mimic_gateway_ffi).
-behaviour(gen_event).
-export([identity/1, fresh_id/0, private_read/1,
         install_signal/0, await_signal/0, restore_signal/0]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).
-include_lib("kernel/include/file.hrl").

identity(Secret) ->
    %% Called only after ingress/keys verified the secret. This opaque value is
    %% used solely in in-memory tenant/session scope, never emitted externally.
    base64:encode(crypto:hash(sha256, Secret), #{mode => urlsafe, padding => false}).

fresh_id() ->
    base64:encode(crypto:strong_rand_bytes(16),
                  #{mode => urlsafe, padding => false}).

private_read(Path) when is_binary(Path) ->
    Name = binary_to_list(Path),
    case filename:pathtype(Name) of
        absolute ->
            case private_path(Name) of
                {ok, #file_info{} = Info} ->
                    case file:open(Name, [read, binary, raw]) of
                        {ok, File} ->
                            try
                                case file:read_file_info(File) of
                                    {ok, #file_info{type = regular, mode = Mode,
                                      inode = Inode, major_device = Device}}
                                      when Mode band 8#777 =:= 8#600,
                                           Inode =:= Info#file_info.inode,
                                           Device =:= Info#file_info.major_device ->
                                        case file:read(File, 65537) of
                                            {ok, Content} when byte_size(Content) =< 65536,
                                              byte_size(Content) =:= Info#file_info.size ->
                                                case {file:read(File, 1),
                                                      file:read_file_info(File)} of
                                                    {eof, {ok, #file_info{size = SizeAfter,
                                                     inode = InodeAfter}}}
                                                      when SizeAfter =:= byte_size(Content),
                                                           InodeAfter =:= Inode ->
                                                        {ok, Content};
                                                    _ -> {error, <<"credential file changed during read">>}
                                                end;
                                            _ -> {error, <<"credential file changed during read">>}
                                        end;
                                    _ -> {error, <<"credential file changed during read">>}
                                end
                            after file:close(File) end;
                        _ -> {error, <<"cannot read private credential file">>}
                    end;
                Error -> Error
            end;
        _ -> {error, <<"credential file must use an absolute path">>}
    end.

private_path(Name) ->
    Parts = filename:split(Name),
    validate_parts(Parts, "", length(Parts)).

validate_parts([], _Path, _Remaining) ->
    {error, <<"invalid private credential path">>};
validate_parts([Part | Rest], Base, Remaining) ->
    Path = filename:join(Base, Part),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} when Remaining > 1 ->
            validate_parts(Rest, Path, Remaining - 1);
        {ok, #file_info{type = regular, mode = Mode, size = Size} = Info}
          when Remaining =:= 1, Mode band 8#777 =:= 8#600, Size =< 65536 ->
            {ok, Info};
        _ -> {error, <<"credential file must be regular 0600 without symlink ancestors">>}
    end.

install_signal() ->
    %% Atomic swap before owning a store avoids SIGTERM stranding its guard.
    case gen_event:swap_handler(
           erl_signal_server, {erl_signal_handler, []},
           {?MODULE, self()}) of
        ok -> {ok, nil};
        _ -> {error, <<"cannot install graceful signal handler">>}
    end.

await_signal() ->
    receive gateway_sigterm -> {ok, nil} end.

restore_signal() ->
    case gen_event:swap_handler(
           erl_signal_server, {?MODULE, []},
           {erl_signal_handler, []}) of
        ok -> nil;
        _ -> nil
    end.

init({Pid, _Old}) -> {ok, Pid};
init(Pid) -> {ok, Pid}.
handle_event(sigterm, Pid) -> Pid ! gateway_sigterm, {ok, Pid};
handle_event(_, Pid) -> {ok, Pid}.
handle_call(_, Pid) -> {ok, ok, Pid}.
handle_info(_, Pid) -> {ok, Pid}.
terminate(_, _) -> ok.
code_change(_, Pid, _) -> {ok, Pid}.
