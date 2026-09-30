# Native-client workflow QA — v1 tracer bullet

**Current qualification: blocked, not passed.** Official Claude Code and Codex
Linux binaries were downloaded, integrity-checked and extracted, but never
executed on the host. The host has no working Linux Docker daemon. No live
provider, account discovery, OAuth login or private repository workflow ran.
This is an initial contained tracer bullet, **not completion of the broad
native-client compatibility matrix**.

The driver is test orchestration (Python standard library, like existing
integration scripts), not a new provider implementation. Production orchestration
and provider behavior remain in MIMIC's Gleam modules.

## Commands for the integration owner

Prerequisites: Python >=3.11; a local Linux Docker daemon on its default socket;
amd64 execution support; `mise exec gleam@1.18.1` and Erlang/OTP 29 for the source
build. Non-amd64 hosts require operator-configured emulation; the driver never
installs privileged binfmt handlers. Docker's user configuration, remote contexts
and credential store are deliberately not read. No global client installation.

Acquisition is explicit, has network access, and is never triggered by execution:

```sh
# Download only the two declared platform archives; no install scripts/binaries run.
python3 scripts/native-clients/qa.py acquire --artifacts-only

# Separately acquire pinned runtime images and build the local immutable image.
python3 scripts/native-clients/qa.py acquire
```

The official npm registry archives include real native executables, not HTTP
imitations. Claude Code uses its platform-native package; Codex uses the official
Rust executable and bundled resource layout, bypassing only the npm JS launcher.
License terms still apply. No client artifacts are committed.

Source-built workflow:

```sh
mise exec gleam@1.18.1 -- gleam export erlang-shipment
python3 scripts/native-clients/qa.py offline \
  --shipment build/erlang-shipment --client all --workflow sse
```

Shipment workflow (same driver, no Gleam or source checkout inside the container):

```sh
python3 scripts/native-clients/qa.py offline \
  --shipment /absolute/path/to/public-mimic-erlang-shipment \
  --client all --workflow all
```

Only run a **public MIMIC** shipment, not a private application's shipment.
BEAM debug metadata can contain source paths. The driver copies only
`entrypoint.sh` and `*/ebin/*.{beam,app}` into a disposable staging directory,
rejects symlinks, and mounts that copy read-only. It never mounts the checkout.
No arbitrary client command, endpoint, shell fragment or host environment can be
passed through this driver.

Unit/contract checks and live preflight:

```sh
python3 -m unittest discover -s test/native_clients -v
python3 scripts/native-clients/live.py
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam format --check
```

Exit contracts: offline `0` means every selected workflow passed; `1` means
failed assertions or invalid child evidence; `2` means blocked prerequisites or
cleanup. `--help`, package acquisition and unit tests are never native workflow
passes. Output is one JSON summary; capture it under an ignored state directory
if needed. Do not commit native stdout, session stores or gateway logs.

## Containment and lifetime

Each client/workflow gets a fresh unprivileged container, synthetic project,
HOME, client state and MIMIC state. MIMIC, the native client and a deterministic
HTTP upstream all run in the same **network-none namespace**. Only loopback
exists; telemetry, updates, DNS discovery and provider egress cannot leave it.
Documented telemetry/update switches are additional controls, not the boundary.

The root filesystem is read-only, all capabilities are dropped, no-new-privileges
is set, Docker's default seccomp profile remains active, and no host sockets,
credentials, profiles, devices or repository directories are mounted. The
container entrypoint independently checks UID, interfaces, capabilities,
no-new-privileges and read-only root before spawning a client.

Limits: 2 CPUs, 2 GiB memory, 256 PIDs, 128 MiB `/work`, 64 MiB `/tmp`, no core
dumps; child CPU 60 seconds, file output 8 MiB, 256 file descriptors; normal
client wall deadline 45 seconds, container deadline 120 seconds. Processes are
spawned with argument vectors, allowlisted environment and a new process group.
Normal exception/timeout paths attempt process-group cleanup and forcibly remove
the named container. A removal failure is blocking, not success. This is **not**
proof of cleanup after driver SIGTERM/SIGKILL or parent death: an independent
daemon/container lifetime watchdog and parent-death/timeout fault tests remain
unimplemented/unperformed prerequisites before native-execution qualification.

Codex's inner sandbox is disabled **only inside this mandatory outer fence**.
This is needed to avoid treating a nested-kernel-sandbox setup issue as gateway
compatibility evidence. Never copy that argv to a host shell.

The draft deterministic tool actions are only Claude `Read` and Codex `exec_command`
with the fixed command `cat /work/project/canary.txt`. No prompt/user string
becomes a shell command. These workflows are now blocked before Docker or client
spawn because the evidence does not yet establish exact call/result identity.
Synthetic secrets are recognizable constants; reports
contain authentication booleans, never credential values or raw message bodies.

## Workflow status and exact meaning

| Workflow | Implemented assertion | Current result |
|---|---|---|
| `sse` | Native exit 0, native output marker, actual gateway-to-upstream stream/auth observations; SSE frames split across byte chunks | blocked: Docker unavailable |
| `tool` | Draft canary check lacks exact call ID and success/error binding | nonqualifiable; blocked before Docker/client |
| `continuation` | Draft aggregate history check lacks per-phase request/session binding | nonqualifiable; blocked before Docker/client |
| `cancel` | Draft event/disconnect check lacks interrupted-request and retry-order binding | nonqualifiable; blocked before Docker/client |
| Long-duration SSE / WS | No adapter yet; short fragmented SSE is **not** long-stream or WS qualification | not_run |
| Native login/device/PKCE | No local-issuer contract established for these exact client versions | not_run |
| Native OAuth refresh/restart | API-key client fixture does not exercise native OAuth. Gateway synthetic grant provisioning is not native login | not_run |
| Kimi / Grok / Devin execution | Inventory/source pins only; missing executable closure/adapter/source contract | blocked |
| Real-provider/live | No scoped authorization; enforcement not implemented | not_run |
| CPA differential | Owned by CPA lab; this driver does not claim parity | not_run |

CLI flags and fixtures are source/documentation-backed starting points, not
measured acceptance by the pinned executables. The first contained run may
expose unsupported flags, model/tool schema drift, missing runtime dependencies
or gateway failures. Those remain failures. Do not loosen assertions or label
the whole matrix unsupported to obtain a green result.

Normal `sse` checks short fragmented SSE acceptance and final output, not
incremental UI timing, rendered partial text, latency or long streaming.
Tool/continuation/cancel remain in the eight-row inventory, not skipped or removed
from the denominator. Both the outer runner and the inner harness block them;
the parent rejects even fully populated `passed` reports for them. They require
reviewed semantic request/call/phase bindings before admission can be enabled.
An empty-text Codex `item.started` is only a native event, never proof of rendered
partial text or first-token latency; global upstream disconnect is not proof of
which client request was cancelled.

## Evidence interface

Report envelope: `schema = "mimic.native-clients/v1"`.

- `evidence_class = "native-client/local-upstream"`, `synthetic = true`.
- `source_base_revision` identifies the original QA development base, **not**
  the current integrated candidate revision or the measured shipment revision.
  Integration must attach its own candidate manifest/digest when collecting
  evidence; the separately measured `shipment_sha256` identifies copied bytes.
- `fixture_sha256` is SHA-256 of exact `fixtures.py` bytes.
- After successful acquisition: image content ID, SHA-256 of harness/lock/image
  inputs, archive and executable hashes. Execution rejects stale acquisition.
- After shipment staging: SHA-256 of sorted path-to-file-SHA-256 JSON.
- Per workflow: client pin, status, actual exit codes, marker assertion,
  summary protocol observations and a stable failure reason. Raw native output
  is deliberately discarded, not base64 encoded.
- `live = "not_run"` and `cpa_differential = "not_run"` must not be promoted by
  a local pass. CPA lab may attach the report as distinct evidence, not relabel
  it as a CPA differential.

Child reports use `schema = "mimic.native-client-workflow/v1"`. The parent validates
the complete report **before accepting or copying claimed identity**:

- Exact requested client, workflow and fresh per-invocation `request_id`.
- Exact pinned client package/version/registry integrity/archive digest and
  executable digest. The child hashes the executable it invokes, rather than
  echoing an expected digest passed on the command line.
- Independently calculated source hashes for the harness, fixture, validator,
  lockfile, driver and Dockerfile; measured copied-shipment digest. Acquisition
  receipts must match the pinned artifact digests and current source bytes.
- Required fields and strict scalar/list types, bounded report size/counts,
  no unknown fields, duplicate JSON keys, nonfinite numbers or mismatched exits.
- For short SSE only: one actual client exit `0`, one successful parsed native
  output check, the output marker, and nonempty valid model/path/stream/auth
  observations. Empty exits/observations or `{"status":"passed"}` cannot pass.
- Blocked reports cannot claim any client execution. Failed/blocked reports
  retain that status; malformed/unbound reports become `invalid_container_report`.

This is evidence admission from a trusted contained harness, not cryptographic
remote attestation against a malicious Docker daemon. Canonical positive reports
in unit tests are explicitly synthetic contract fixtures, never runtime evidence.
Changing the validator/source/lock invalidates any earlier acquisition receipt;
the image must be reacquired separately before a future authorized local run.

The integration owner should wire commands/CI separately. A generic pass of the
harness tests proves safety/fixture mechanics only; it does not qualify a
native client. Do not make blocked native prerequisites an implicit CI pass.

## Verified here

- Exact published base `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, fetched from
  `https://github.com/stepandra/mimic.git` with `jj`; initial worktree clean/stale.
  New change made on that base without committing/pushing or touching siblings.
- `gleam test` with `mise exec gleam@1.18.1`: **522 passed**, no failures.
  An initial 120-second attempt timed out; the later 360-second bound completed.
- `gleam export erlang-shipment`: succeeded.
- Native harness unit tests: **31 passed** after fail-closed admission fixes,
  recorded in `RESULTS.v1.json`.
- `gleam format --check`: fails on preexisting
  `vendor/mist/src/mist/internal/http2/frame.gleam`; no unrelated formatting edits.
- Official Claude/Codex artifact downloads and integrity checks succeeded.
- Historical pre-admission-fix offline attempt: all eight **blocked**,
  `linux_docker_daemon_unavailable`. No Docker/client rerun for the admission fix.
- Historical direct host harness invocation: **blocked**, `container_required`.
- Live preflight: **not_run**, zero requests and no credentials read.
- Runtime Docker image build, all eight native workflow executions, source and
  shipment native qualification, long streams, WS, native auth flows, CPA
  differential and live gates remain unverified/unperformed.
