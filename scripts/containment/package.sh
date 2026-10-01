#!/bin/sh
# Staging only; no Docker command, network, installation or target execution.
# Pass the explicitly approved static Linux launcher artifact. Build separately
# with scripts/containment/launcher/build.sh; this script never executes it.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if test "$#" -ne 1 || ! test -f "$1" || test -L "$1"; then
    printf '%s\n' 'blocked: explicit approved regular Linux launcher artifact required' >&2
    exit 2
fi
case "$1" in
    /*) ;;
    *) printf '%s\n' 'blocked: launcher artifact path must be absolute' >&2; exit 2 ;;
esac
launcher=$1
cd "$root"
python3 scripts/containment/check_launcher.py "$launcher"
sh scripts/containment/focused.sh
context="$root/build/containment/image-context"
if test -e "$context"; then
    printf '%s\n' 'blocked: image context already exists; inspect it, do not overwrite provenance' >&2
    exit 2
fi
mkdir -p "$context/boundary"
for app in mimic gleam_stdlib gleam_json argv; do
    mkdir -p "$context/boundary/$app/ebin"
    cp "build/containment/build/dev/erlang/$app/ebin/"*.beam "$context/boundary/$app/ebin/"
    cp "build/containment/build/dev/erlang/$app/ebin/"*.app "$context/boundary/$app/ebin/"
done
erlc -Werror -o "$context/boundary/mimic/ebin" scripts/containment/mimic_containment_boot.erl
cp "$launcher" "$context/launch"
cp scripts/containment/faults.py "$context/containment_faults.py"
cp scripts/containment/Dockerfile "$context/Dockerfile"
printf '%s\n' 'synthetic-forbidden-fixture' > "$context/forbidden"
chmod 0555 "$context/launch"
cd "$context"
find boundary -type f -exec shasum -a 256 {} + > inputs.sha256
shasum -a 256 launch containment_faults.py Dockerfile forbidden >> inputs.sha256
printf '%s\n' "staged $context; image build/use still requires explicit approval"
