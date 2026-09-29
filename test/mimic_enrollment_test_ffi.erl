-module(mimic_enrollment_test_ffi).
-export([phase/2]).

%% A real fresh VM; only a private synthetic state directory is passed.
phase(Directory, Seed) ->
    Erl = os:find_executable("erl"),
    Paths = [filename:absname(P) || P <- code:get_path()],
    Code = "enrollment_store_test:phase("
           "list_to_binary(hd(init:get_plain_arguments())),"
           ++ atom_to_list(Seed) ++ "),halt(0).",
    Port = open_port({spawn_executable, Erl},
        [binary, exit_status, use_stdio, stderr_to_stdout,
         {args, ["+S", "1", "-noshell", "-pa"] ++ Paths ++
                 ["-eval", Code, "-extra", binary_to_list(Directory)]}]),
    wait(Port).

wait(Port) ->
    receive
        {Port, {data, _}} -> wait(Port);
        {Port, {exit_status, 0}} -> true;
        {Port, {exit_status, _}} -> false
    after 15000 ->
        port_close(Port), false
    end.
