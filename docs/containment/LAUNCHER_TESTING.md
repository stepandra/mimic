# Independent Zig launcher acceptance probes

These are **synthetic kernel acceptance probes, not qualification evidence**.
They import no launcher implementation. Zig 0.16.0 cross-compilation for Linux
arm64 and x86_64 and five pure Python report-parser regressions were performed.
Neither Linux binary was executed by the probe worker. Actual Linux enforcement,
architecture coverage, immutable-image provenance and namespace cleanup must be
measured separately by the parent coordinator. No provider, credentials, native
client, reference acquisition, download or external endpoint is involved.

## Build and pure host validation

```sh
sh scripts/containment/launcher-probes/build.sh
zig fmt --check scripts/containment/launcher-probes/probe.zig
python3 -m unittest discover -s scripts/containment/launcher-probes -p 'test_*.py' -v
```

`ZIG` can select another **0.16.0** compiler. Outputs are static ELF binaries in
ignored `build/containment/launcher-probes/aarch64-linux-musl` and
`build/containment/launcher-probes/x86_64-linux-musl`. musl supplies OS ABI bindings;
probe logic is Zig, not C. Build never executes either artifact. The machine lacked
an `apply_patch` executable; source changes used an approved scratch-local
`apply_patch` wrapper generating unified diffs applied by `/usr/bin/patch`.

## Private fixture contract

Only the parent may stage/run containers. Use a new, explicitly owned private
PID/network/mount namespace, no host network/mount/socket, no published ports,
read-only root, no-new-privileges, and drop all capabilities except SETUID/SETGID.
Use real cgroup bounds (positive memory.max <= 2 GiB and pids.max <= 256).
Private bounded `/work` and `/tmp` must permit UID/GID10001 writes. `/work` must
allow the root QA coordinator to inspect its synthetic marker. Set the outer
NOFILE limit >= 301 so QA can deliberately plant FD300 before launcher exec.

Stage only synthetic files/artifacts:

- `/containment/launch`: launcher under test, executable.
- `/usr/local/bin/launcher-probe`: matching architecture probe, executable.
- `/containment/forbidden` and `/boundary/forbidden`: exactly `synthetic\n`,
  readable to root and preferably mode0444. Both must exist; missing denial
  fixtures are not a pass.
- Real directories `/usr`, `/qa`, `/etc`, `/work`, `/work/home`, `/tmp` and the
  probe's ancestors, with no symlink substitutions.
- Real kernel `/proc/self/status`, `/proc/1/fd/0`, `/sys/class/net`, and cgroup
  `memory.max` / `pids.max`; real `/dev/null`. No fabricated kernel metadata.

The probe does not manufacture namespace isolation. It is intentionally not a
host selftest. Container execution/stop/remove/list-absence confirmation must
have independent host deadlines even though all probe modes have alarms.

## Explicit container gate

After building both artifacts, the operator-approved local-only gate is:

```sh
python3 scripts/containment/launcher-probes/run.py \
  --base-image sha256:EXACT_ALREADY_LOCAL_IMAGE_ID \
  --launcher build/containment/zig-launcher/aarch64/bin/launch \
  --probe build/containment/launcher-probes/aarch64-linux-musl
```

The gate validates artifact/image architectures, packages only the two static
executables and synthetic markers by copying into a never-started container from
that exact local base (`create --pull=never`) and taking a local snapshot, then creates a resource-limited read-only/no-network container.
There are no host mounts or provider inputs. The trusted root suite runs the
launcher through private pipes. Host and in-container deadlines are independent.
Raw logs, exact inputs, kernel/image identity and measured exit status are retained
under an explicit ignored `build/containment/mimic-launcher-probe-*` directory.
Only the newly owned container and fixture image are removed; the base is untouched.
Negative fixture options `--negative-fixture missing-qa` and
`--negative-fixture runtime-alias` require pre-target refusal.
The final JSON report must pass the independent strict parser as well as exit zero.
This is launcher kernel evidence, not BEAM PID1/lifetime or CPA qualification.

## Fixed binary modes

No mode accepts arbitrary paths, addresses, commands, or data.

| Mode | Identity and role | Deadline |
| --- | --- | --- |
| `suite` | Root trusted QA coordinator; forks fixture, runs launcher via private pipes, checks baseline/descendant and refusal cases, kills/reaps fixture | 30 s absolute |
| `fixture` | Root, listens on loopback39001 **and**39002, emits readiness only after both listen calls succeed, serves `synthetic-local-fixture\n` | 30 s absolute |
| `baseline` | Target invoked only through launcher; full boolean kernel report | 8 s |
| `descendant` | Target forks and execs fixed `inherited` mode; waits for successful child | 8 s parent, 6 s child |
| `inherited` | Child repeats all checks except `/proc/self/status`-derived checks | 8 s on exec |
| `marker` | Writes `/work/forbidden-exec-marker`, emits `forbidden_exec_reached:true`, exits99 | 8 s |

`inherited` deliberately does not claim child self-status readability: a narrow
Landlock rule for the launcher's proc inode survives exec, but does not grant a
new child's distinct proc inode. Its report has a separate exact schema. Identity,
rlimits, environment, filesystem, inherited FDs, all network/socket/syscall
restrictions and cgroup metadata are tested again after fork/exec. This is not an
adversarial lifetime test and does not qualify namespace-wide descendant killing.

The exact target invocation used by `suite` is:

```text
/containment/launch --bind-ports 39003 --connect-ports 39001 --cpu-seconds 40 --file-bytes 8388608 --no-files 256 -- /usr/local/bin/launcher-probe baseline
```

The same argv with `descendant` follows. `--check` must first exit0 and return
exactly `mimic.containment-launch/v1\n` (no stderr or extra whitespace). All launch
calls receive actual FIFO stdout/stderr, and inherited FD42 and FD300 planted by
QA. No shell, Python or Erlang is required in the container.

The suite accepts only normal nonzero launcher rejection, absent marker, and no
marker report for: out-of-range bind port; malformed connect list; zero CPU;
negative FD limit; unknown option; otherwise-valid launch attempted by UID/GID10001.
Exit99, signals/timeouts, marker presence, or unknown-option argv echo fail.
Launcher stderr is never emitted verbatim. Missing prerequisites or unsupported
kernel policy must fail; no production restriction is loosened for a test.

## Oracle details and limitations

- UID/EUID/GID/EGID10001, no supplementary groups; effective, permitted,
  inheritable and ambient capabilities zero; no-new-privileges and seccomp filter.
  Bounding set must be exactly zero or `0xc0` (SETUID/SETGID), the only approved
  owner transition capabilities. Bounding bits are not active privileges; clearing
  them requires SETPCAP, deliberately not added for testing. This does not alone
  establish inability to regain privilege through every possible syscall.
- Exact six-variable environment from F02; cwd `/work`; umask077; EOF stdin;
  no inherited descriptors from3 through4095, including planted FD300 above the
  lowered256 limit. This bounded scan is not proof about all possible FD numbers.
- Exact hard and soft core0/CPU40/file8388608/FD256 and real bounded cgroup values.
- Create/write/read/remove in `/work` and `/tmp`; denial of writes at `/`, `/etc`,
  and runtime `/usr/local/bin`; deny reads of forbidden fixtures and owner stdin.
  These samples do not exhaust all filesystem operations, aliases, or paths.
- TCP39001 must receive the exact synthetic marker; TCP39002 must return
  EPERM/EACCES **while the sibling fixture really listens**. ECONNREFUSED, timeout,
  missing path and unavailable protocol are never denial evidence. Bind/listen
 39003 succeeds; bind39004 gets permission denial.
- UDP4/6, Unix, raw, packet and socketpair calls must return EPERM/EACCES.
  io_uring_setup must return EPERM/EACCES, not ENOSYS. A wrongly allowed ring is
  closed immediately. Namespace-control probes use invalid arguments so an absent
  filter cannot mutate the namespace: unshare(NEWNET|invalid-bit) and setns(-1,
  NEWNET) must still return permission denial, not EINVAL/EBADF. These syscall
  samples are not an exhaustive alternate-ABI/seccomp bypass audit.

## Host report acceptance

Save bounded stdout and exact container exit status from the parent-owned run.
Do not turn a timeout, signal or launch error into zero. Then, for example:

```sh
python3 scripts/containment/launcher-probes/verify.py 0 < /path/to/synthetic-suite-report.jsonl
```

The argument is the **measured** exit status, not a suggested replacement.
The pure validator requires six reports in order: fixture readiness, exact-check
success, complete baseline schema, complete inherited schema, descendant success,
and refusal/suite success. Every value must be JSON `true`; duplicate keys,
missing/extra keys, non-booleans, extra text and oversized output fail. Failure
reports contain only safe boolean keys, never host paths, secret values or raw
launcher stderr. The validator does not execute anything.

Still unperformed by this worker: actual Linux suite on either architecture;
negative-control tests against intentionally broken policies; independent image
and kernel provenance; deadline/cleanup observation; unsupported-kernel and
missing-required-path refusal matrix; full namespace lifetime qualification;
BEAM integration and assembled project gates. Parser tests and static builds
are not substitutes for those gates.
