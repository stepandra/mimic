# Unmodified CPA reference driver (blocked after actual execution)

Current corrective checkpoint: [v3 review fixes](REVIEW_FIXES_V3.md).
Default Python discovery is now unit-only; use `safe_unit_tests.py` for enforced
process/network-free execution. Real OS/build/target checks are separate explicit
integration commands. CPA and candidate execution remain blocked.

Reference: `acdace936fa7df2905500c7f5e0a97d683138dea`.
Assembled base: `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.
The existing [v1 executable contract](CONTRACT.md) and
[strict 37-row scope](v2/README.md) remain authoritative. Historical matrices,
fixtures and source/mock/differential/live denominators are not rewritten.

## Peer hook contract

Provide a test-only argv executable in your owned namespace. The last argument
is the absolute JSON plan path. Return exactly one v1 result JSON on stdout.
Do not substitute a summary of an independently configured smoke test for the
plan's fixture. Unknown dimensions/checks/fixtures must block.

For each hook send:

1. Exact supported `(capability_id, provider, auth_mode, input_protocol,
   upstream_mode, fixture_id, phase)` combinations.
2. Versioned synthetic request/response scripts, actual route paths, response
   status, ordered/cased duplicate headers, body text or known-synthetic binary
   bytes, ordered SSE/WS/Connect frames, and termination/cancellation policy.
3. The actual gateway CLI launch/import argv and required compiled artifacts;
   configurable local upstream/token/catalog endpoints; no operator environment.
4. A per-check assertion mapping based on actual HTTP/WS observations and
   runtime state, plus adversarial tests for each claimed check. Only a real
   assembled client request permits `assembled_ingress: true`.
5. Exact fields believed volatile and pinned source justification. None are
   normalized by this driver revision. Header dictionaries/sorting, stripping
   IDs/dates, collapsing terminal markers and callback-only checks are forbidden.

Keep Kimi native/generic and API key/OAuth, Codex HTTP/full replay/lite/native
WS, and xAI HTTP/Grok Build/physical WS distinct. Devin protobuf embeds the
token: base64 is not redaction. Only generated synthetic state may be observed.
No passing live status is ever inferred.

Initial executable tracer uses **unchanged** `messages-v1` / `chat-v1` fixture
bytes. It does not add rows to strict37. TLS, WS, Connect, refresh, failover,
cancel and restart remain blocked until separately implemented and measured;
a working buffered tracer cannot satisfy those checks.

## Build phases

```sh
# Explicit networked acquisition, public source and dependency downloads only.
python3 scripts/parity/reference_build.py download

# Offline Go build, no source patch/overlay and no CPA execution.
python3 scripts/parity/reference_build.py build
```

Both use ignored `build/parity-reference/`, never an unattached checkout.
The archive's independently recorded SHA-256 is
`56c970726edbd07591b77c1b6be18f733368f8a2f52a2f0931c928b30c13b540`.
Every source file is compared against the archive before and after build.
The provenance manifest records source files, module lockfiles, toolchain and
executable hashes, build argv/environment and linked dependency version/sums.
The wrapper is trusted test code, not a cryptographic remote build attestation.

Runtime is separate: macOS Seatbelt allows only selected synthetic fixture and
ingress ports, denies reads of operator/project directories outside private
staging, and denies writes outside staging. No inherited credential environment.
Negative file/network probes must pass before target launch. Other hosts and
failed probes block; there is no unsandboxed fallback.

## Offline execution and CI hooks

On the exact supported assembled base, after dependency acquisition:

```sh
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam export erlang-shipment
PYTHONDONTWRITEBYTECODE=1 python3 scripts/parity/reference_driver.py --prepare

# Offline; EXPECT EXIT 1. Current CPA startup blocker is deliberately enforced.
mise exec gleam@1.18.1 -- gleam run -m parity/runner -- release \
  build/parity-reference/drivers.json \
  --manifest test/parity/v2/manifest.json
```

Preparation is once per fresh target staging directory. It rejects existing
staging rather than replacing artifacts. It rejects another MIMIC revision or
dirty production sources instead of assigning the assembled-base identity to an
unreviewed overlay. Preparation itself exports the MIMIC shipment from the
verified base rather than trusting pre-existing `.beam` files. Target hashes
are integrity records, not adversarial build attestation.

Root CI proposal (integration owner only):

```sh
mise exec gleam@1.18.1 -- gleam format --check src test
mise exec gleam@1.18.1 -- gleam test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/parity -p 'test_*.py' -v
```

Keep the strict37 command above in a separate required, currently **failing**
release job. No `continue-on-error`, source-only substitute or synthesized CPA
result. The macOS-only containment implementation is not a Linux CI launcher.
Do not run raw CPA as a fallback. Archive results on failure, but prefer the
whitelisted evidence exporter to copying executable/runtime credential state:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/parity/export_reference_evidence.py \
  build/parity-results/<run>/report.json
```

Output: `build/parity-reference/evidence.tar.gz` and
`evidence-manifest.json`. The exporter accepts strict37 synthetic local results,
preserves raw result bytes and includes source/build identity. It does not
include target executables, auth stores, `.git`, `.jj`, dependency caches or
operator state. The build manifest inventories all 1,663 upstream source files.

## Startup blocker

The first real CPA execution disclosed a startup service not disabled by
`-local-model`: `cmd/server/main.go:826` calls
`misc.StartAntigravityVersionUpdater` unconditionally in server mode.
`internal/misc/antigravity_version.go:64` immediately refreshes a hardcoded
external manifest. The updater has no configuration/env disable switch in the
inspected pin. The sandbox denied its network request; the log records failure.
This is **not** Antigravity provider execution/coverage and changes no scope.

`CPA_STARTUP_BLOCKER` now refuses all further CPA launches. It is checked both
at result generation and at the launcher, so direct callers cannot bypass it
accidentally. Do not remove it just because network attempts fail. Resolving
the user's background-disable requirement needs an explicit owner decision,
not a behavior-changing Go patch or an undisclosed weakened safety condition.

See [measured results](REFERENCE_RESULTS.md) and
[machine-readable evidence index](reference-v1/EVIDENCE.json).
