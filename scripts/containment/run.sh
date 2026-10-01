#!/bin/sh
# Execute precompiled F02 only. Never compile/acquire/install implicitly.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compiled="$root/build/containment/build/dev/erlang"
if ! test -f "$compiled/mimic/ebin/mimic@containment@entry.beam"; then
    printf '%s\n' '{"schema":"mimic.containment/v1","status":"blocked","reason":"compiled_f02_missing","target_spawned":false}'
    exit 2
fi
exec erl -noshell -noinput +S 1:1 +A 1 \
    -pa "$compiled/mimic/ebin" "$compiled/gleam_stdlib/ebin" \
    "$compiled/gleam_json/ebin" "$compiled/argv/ebin" \
    -eval "erlang:halt('mimic@containment@entry':boot(), [{flush, false}])." \
    -extra "$@"
