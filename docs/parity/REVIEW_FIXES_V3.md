# V3 security corrections and evidence separation

V2 source-only acceptance was withheld. This successor fixes the launch-policy
and artifact write boundary, separates unit discovery from real integration
execution, and blocks candidate execution where descendant cleanup is unproved.
It does not promote the historical observations, claim parity, or waive a gate.

## Findings and responses

### Policy and executable writes across repeated launches

Independent review identified that v2 allowed writes to its whole runtime
directory. Both `sandbox.sb` and the copied shipment were inside that directory.
The first provisioning process could affect a later provisioning/server launch.

The policy-file issue was reproduced using a **synthetic `/usr/bin/tee` child**:
the pre-fix regression failed because the policy replacement returned exit 0.
No malicious candidate, CPA executable or actual provider was run.

The corrected rule is:

- The parent constructs a frozen `LaunchPolicy`, retaining its text and runtime
  directory device/inode/permissions.
- Every launch receives those same inline `-p` bytes. A filename or a later read
  of `sandbox.sb` cannot supply launch policy.
- Before each launch, the runtime root must still be the same canonical private
  `0700` directory. Replaced roots, symlinks and changed permissions fail.
- Runtime write exceptions are only `state`, `auth`, `home`, `tmp` and the child
  log. Copied executables, shipment files, configuration/credential seed inputs,
  policy audit copy and parent execution/containment records are outside every
  child-writable exception.
- Build write exceptions remain only generated `source/build`, private home/temp
  and the export log. Final artifacts and provenance are parent-only.

A synthetic three-launch regression exercises provisioning → provisioning →
server-read using `tee`/`cat`, never a candidate executable. Both provisioners
fail to overwrite policy, parent evidence and a copied-code marker, including
through a symlink in writable state. The third launch reads the original marker.
A parent-side change to the policy audit copy cannot affect the next launch.
Allowed state writes and approved fixture connectivity are independently checked.

A separate pure unit control follows the real MIMIC launcher's three call sites
with mocked process/socket boundaries and verifies the exact same parent policy
object is used throughout. It is not runtime/provider evidence.

### Default discovery must not compile or launch targets

Default `test_*.py` discovery no longer includes:

- real Gleam export;
- Go environment subprocesses;
- Seatbelt/subprocess cleanup integrations;
- the seven inherited real local-target tests.

The former `test_local_driver.py` is a harmless compatibility placeholder. It
must overwrite the old file during import; do not keep an older copy beside the
successor. The actual tests are in `integration_local_driver.py`. No deletion
inference is needed when applying this source snapshot.

The explicit safe suite uses an allowlist of unit modules and guards process
creation and network APIs. A future accidental subprocess, listener, DNS lookup
or connection through standard audited Python APIs fails rather than silently
becoming an integration. Audit rejection covers process replacement and
connectionless datagrams as well. This is accident protection for trusted tests,
not an OS sandbox for adversarial native extensions.

```sh
# Safe root unit hook: no build, subprocess, target or network execution.
PYTHONDONTWRITEBYTECODE=1 python3 scripts/parity/safe_unit_tests.py

# Ordinary discovery also contains only those pure controls.
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/parity -p 'test_*.py' -v
```

Separate integration selectors, only when authorized:

```sh
# Synthetic binutils/socket controls; does not run MIMIC or CPA.
python3 scripts/parity/integration_reference.py --run --group seatbelt

# Environment and SAME-PGID controls; not a detached-descendant proof.
python3 scripts/parity/integration_reference.py --run --group go-env
python3 scripts/parity/integration_reference.py --run --group same-pgid

# Real historical local-target tests, using already-compiled artifacts.
python3 scripts/parity/integration_local_driver.py

# Reports not_run without --run; currently reports blocked even with --run.
python3 scripts/parity/integration_candidate.py
```

Do not import integration `TestCase` classes into a `test_*.py` module: unittest
discovers imported classes too. The candidate integration selector has no
override for a safety blocker.

### Original PGID cleanup is not descendant containment

The detached-process finding is **static control-flow reasoning**, not a
reproduced escape in this checkpoint. `killpg` targets only the original group;
a child may leave it via `setsid`/`setpgid`. Prior leader-exit/TERM-ignore tests
exercise descendants that stay in that group. They never established a guarantee
for detached descendants.

No reviewed backend in this harness currently provides that OS-level guarantee.
Consequently:

- `candidate.export` blocks before toolchain resolution/version/compiler launch.
- Candidate runtime blocks at both driver-result and direct-launch boundaries.
- The exact blocker is `candidate_descendant_containment_unavailable`.
- The independent `CPA_STARTUP_BLOCKER` remains unchanged.
- No current flag, manifest field or environment setting waives either blocker.

Same-PGID cleanup remains best-effort legacy behavior, explicitly labelled as
such. Supporting candidate execution requires a reviewed process-lifetime
containment backend, not another PID-tree polling loop or a success relabel.

## Validation accounting

V3 validation is limited to safe units and selected synthetic OS controls.
No candidate build/runtime, CPA, live provider, detached-process experiment,
Go environment integration, inherited target integration or full strict37 run
is newly executed. The previous **523 Gleam / 51 mixed Python / 0-of-37** results
remain historical v2 evidence; they are not v3 results.

The source-only handoff manifest records the exact new counts and commands.
Any new OS-control success is filed as `synthetic-os-integration`, not candidate,
CPA differential, native-client or live coverage. `not_run`/`blocked` integration
selectors return nonzero rather than looking like successful executions.

| V3 check | Result |
|---|---|
| Explicit guarded safe suite | **47 passed** |
| Default `test_*.py` discovery | **47 passed**, the same unit cases, not an additional 47 |
| Explicit synthetic Seatbelt controls | **2 passed**, no target executables |
| Format and diff checks | Passed |
| Candidate export/runtime and CPA | Blocked; not executed |
| Detached-process experiment | Not run; static finding only |
| Full Gleam/strict37/other integration suites | Not rerun in this corrective checkpoint |

Frozen v2 source and evidence archive digests remain:

- Source: `bdc440144f89fe319b931a54fa2b40172792357694c72e4cce8071108aa6aa43`
- Evidence: `20356df0ef65fc6fa4450aeca226b2d42ee376b90630ef000adda44f6d7bef4b`
