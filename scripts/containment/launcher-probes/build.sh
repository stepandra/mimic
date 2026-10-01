#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
ZIG=${ZIG:-zig}
test "$("$ZIG" version)" = 0.16.0 || { echo 'requires Zig 0.16.0' >&2; exit 2; }
mkdir -p build/containment/launcher-probes
for arch in aarch64 x86_64; do
  "$ZIG" build-exe scripts/containment/launcher-probes/probe.zig -target "$arch-linux-musl" -O ReleaseSafe -static -lc -femit-bin="build/containment/launcher-probes/$arch-linux-musl"
done
