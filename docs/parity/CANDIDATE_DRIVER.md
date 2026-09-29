# Reviewed candidate-source mode

**Current v3 status: candidate export and candidate runtime are blocked.**
Seatbelt does not provide a verified bound on descendants that leave the original
process group. Neither an explicit integration flag nor a valid candidate manifest
overrides `candidate_descendant_containment_unavailable`. See
[v3 review fixes and test selection](REVIEW_FIXES_V3.md). Dependency acquisition
remains a separate explicit operation; it does not authorize execution.

This additive mode prepares an assembled source package without mislabeling it
as clean `3e00808ff0fefbb6728edb1769c17139ef0fd93a`. The integration owner
approved this interface. The frozen v1 source archive/evidence remain unchanged.
CPA's hard startup blocker remains in both modes; nothing here authorizes CPA
execution, live traffic, new provider coverage or a changed strict37 denominator.

## Approval input

The caller supplies three inputs together:

```text
--candidate-manifest /absolute/candidate.json
--candidate-sha256 <integration-reviewed SHA-256 of exact manifest bytes>
--candidate-source /absolute/candidate-source.tar.gz
```

Manifest shape (the file inventory below is abbreviated):

```json
{
  "schema": "mimic.parity-candidate/v1",
  "base_revision": "3e00808ff0fefbb6728edb1769c17139ef0fd93a",
  "source_archive_sha256": "<lowercase sha256>",
  "files": {
    "gleam.toml": "<lowercase sha256>",
    "manifest.toml": "<lowercase sha256>",
    "src/mimic.gleam": "<lowercase sha256>"
  }
}
```

`files` must describe the complete assembled source/build input, including all
other production files, required `priv` resources, and every in-tree local
dependency such as `vendor/mist`. This is not an overlay list. The manifest
does not have an `approved` flag; extra fields and duplicate JSON keys fail.
Integration reviews the expected digest out of band. Changing even manifest
whitespace requires a new approval digest.

Archive names are canonical relative POSIX paths without `./` prefixes. Files
and necessary directories only: no links, devices, FIFOs, duplicate paths,
absolute/traversal paths, `.git`, `.jj`, operator config, build outputs or caches.
Do not use `tar ... .` if it adds `./` prefixes. No source modification, patch
application or inference from the caller's Git status takes place.

Bounds: manifest 4 MiB, compressed/source archive 64 MiB, extracted files 16 MiB
each and 256 MiB total, at most 20,000 inventoried files / 30,000 archive entries.
Hash and extraction use the same immutable bounded archive-byte snapshot;
replacing or modifying the original archive after reading cannot change what
is extracted.

## Separate acquisition and offline preparation

```sh
# Explicit public dependency-download phase; no MIMIC/CPA execution.
PYTHONDONTWRITEBYTECODE=1 python3 scripts/parity/reference_driver.py \
  --candidate-acquire \
  --candidate-manifest /absolute/candidate.json \
  --candidate-sha256 <reviewed-sha256> \
  --candidate-source /absolute/candidate-source.tar.gz

# Offline verification/export phase. Never downloads missing dependencies.
PYTHONDONTWRITEBYTECODE=1 python3 scripts/parity/reference_driver.py \
  --prepare \
  --candidate-manifest /absolute/candidate.json \
  --candidate-sha256 <reviewed-sha256> \
  --candidate-source /absolute/candidate-source.tar.gz
```

Both commands independently verify and extract the approved source into a new
private attempt under:

```text
build/parity-reference/candidates/<manifest-sha256>/
  dependencies/                  # Explicitly downloaded verified public archives
  acquire-<unique>/               # Acquisition receipt and verified source
  prepare-<unique>/               # Fresh source, isolated export and results
```

No caller/home/build cache is copied. Dependency closure is derived from
`gleam.toml`, the exact root lockfile and recursively included path dependencies.
Unknown sources, missing locked packages, escaping paths and contradictory local
package metadata fail. Hex archives must match the lockfile's outer checksum.
Root dev dependencies are locked too; local dependencies' own dev dependencies
are not part of Gleam's root dependency graph.

`--prepare` validates all cached public archives before staging package sources.
Missing/corrupt dependencies fail before invoking the compiler. Gleam 1.18.1 has
no export `--offline` flag: the actual export and compiler-version probe therefore
run inside Seatbelt with **all networking denied**, not merely a proxy setting.
There is no fallback to `gleam deps download`, `mise install`, an inherited cache,
or an unsandboxed build.

Current implementation requires macOS and an already installed
`MISE_DATA_DIR/installs/gleam/1.18.1/gleam` (default
`~/.local/share/mise/installs/gleam/1.18.1/gleam`), Erlang and rebar3.
Toolchain resolution reads paths only; it does not execute `mise where/exec`.
The installed tool paths/hashes and actual export argv are recorded.

The build receives a fresh HOME/TMPDIR/XDG/Hex/rebar state directory and a
whitelisted environment. It can read staged source and required system/toolchain
files, but cannot read the original checkout or operator home. Writes are limited
to `source/build`, private home/temp and the export log. Source inputs, approved
manifest and final target/provenance output paths are read-only to build children.
Network/read-denial probes must pass before compiler execution. CPU, file size,
file descriptor and wall-clock bounds apply. The existing cleanup helper targets
only the original PGID; it does not establish detached-descendant cleanup.
Candidate execution therefore stops before compiler/tool subprocesses.

Launch policy bytes are held immutably by the parent and passed inline to each
`sandbox-exec` invocation. The saved `sandbox.sb` is evidence only, never launch
input. Directory identity and permissions are rechecked before every launch.

## Identity and outputs

Preparation verifies the entire source inventory before and after export
(including failed exports). It rejects source mutation, linked shipment roots,
linked output files and pre-existing final staging. Only freshly exported
`.beam`/`.app` code and exported `priv` runtime resources enter the target stage.
The reference CPA process receives none of this source.

Successful preparation emits:

- `candidate.json`: exact approved input bytes.
- `candidate-build.json`: source approval/archive digests, base lineage,
  dependency closure, toolchain hashes, export command and verification outcome.
- `targets.json`: `mimic.reference-targets/v2`, including candidate/build identity
  and every staged runtime artifact hash.
- `drivers.json`: existing executable-driver configuration; the command prints
  its absolute path.
- `export.log`, `sandbox.sb`, `build-containment.json`: build evidence.

The MIMIC revision in driver config, plan, result and provenance is:

```text
candidate-sha256:<approved-manifest-byte-sha256>
```

`base_revision` is recorded separately as lineage, never substituted for the
candidate identity. The exact target-manifest bytes consumed by validation are
hashed into execution evidence. Runtime rejects candidate/base mismatches,
another candidate's identity, stale source approval or changed shipment bytes.
Unsupported fixtures still return unsupported, not successful evidence.

Each failed accepted attempt retains `failure.json`, its phase, source snapshot
and any available export/containment logs. No failed attempt is overwritten by a
retry. An invalid approval digest fails before creating an accepted attempt.

The existing no-candidate mode remains the clean-base path. As before, generated
artifact/provenance files and their writer are trusted test infrastructure, not
cryptographically signed remote attestation. An actor who can rewrite both
trusted provenance and executables is outside this contract. Candidate builds
never modify or reuse the global v1 base target stage.

## Running the existing gate

```sh
mise exec gleam@1.18.1 -- gleam run -m parity/runner -- release \
  /absolute/path/printed/by/prepare/drivers.json \
  --manifest test/parity/v2/manifest.json
```

Expect a nonzero strict release result: CPA is still explicitly blocked.
Candidate runtime is independently blocked pending descendant containment.
Historical candidate compilation or a synthetic gateway response is not CPA parity.
