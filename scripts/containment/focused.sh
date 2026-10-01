#!/bin/sh
# Focused F02 project: no root/provider compilation and no image acquisition.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
overlay="$root/build/containment"
mkdir -p "$overlay/src/mimic/containment" "$overlay/test" "$overlay/build" "$overlay/vendor"
cp gleam.toml manifest.toml "$overlay/"
cp src/mimic/containment/*.gleam "$overlay/src/mimic/containment/"
if test -f src/mimic/containment.gleam; then
    cp src/mimic/containment.gleam "$overlay/src/mimic/"
fi
for file in src/mimic_containment*_ffi.erl; do
    if test -f "$file"; then cp "$file" "$overlay/src/"; fi
done
cp test/containment*_test.gleam "$overlay/test/"
for file in test/mimic_containment*_ffi.erl; do
    if test -f "$file"; then cp "$file" "$overlay/test/"; fi
done
cp scripts/containment/test_runner.gleam "$overlay/test/mimic_test.gleam"
if ! test -e "$overlay/build/packages"; then
    ln -s ../../packages "$overlay/build/packages"
fi
if ! test -e "$overlay/vendor/mist"; then
    ln -s ../../../vendor/mist "$overlay/vendor/mist"
fi
cd "$overlay"
mise exec gleam@1.18.1 -- gleam test
