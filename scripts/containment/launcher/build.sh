#!/bin/sh
# Compile/test only; never executes Linux launcher or targets.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
zig=${ZIG:-zig}
if test "$("$zig" version)" != 0.16.0; then
    printf '%s\n' 'blocked: Zig 0.16.0 required' >&2
    exit 2
fi
cd "$root"
cache="$root/build/containment/zig-launcher/cache"
global="$root/build/containment/zig-launcher/global"
"$zig" fmt --check scripts/containment/launcher/*.zig
"$zig" build --build-file scripts/containment/launcher/build.zig --cache-dir "$cache" --global-cache-dir "$global" test
for arch in aarch64 x86_64; do
    "$zig" build --build-file scripts/containment/launcher/build.zig --cache-dir "$cache" --global-cache-dir "$global" -Dtarget="$arch-linux-musl" -Doptimize=ReleaseSafe --prefix "$root/build/containment/zig-launcher/$arch"
done
