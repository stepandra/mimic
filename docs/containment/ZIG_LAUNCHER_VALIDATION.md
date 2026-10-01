# Zig launcher implementation and measured Linux gates

## Result

The narrow F02 Linux launcher is implemented in Zig 0.16.0, with no C source,
libc dependency or new process manager. Existing Gleam orchestration calls the
same `/containment/launch` argument-vector ABI. The launcher configures identity,
capabilities, limits, descriptors, Landlock and seccomp, then directly `execve`s
its target. Any missing/failed mandatory restriction prevents target execution.

**Final source was rebuilt in the coordinator and passed the independent ARM64
Linux kernel probe.** This does not qualify the complete BEAM PID1 lifetime
suite, any native client, CPA differential, real accounts or live-provider use.

## Verification

- `sh scripts/containment/launcher/build.sh`: Zig formatting, two pure test
  groups (CLI/parser and both-architecture BPF behavior), static ARM64 and x86_64
  builds passed. Targets are never executed on the macOS host.
- `sh scripts/containment/launcher-probes/build.sh`: both static independent
  probes compiled; probe formatting passed.
- Python containment/packaging suite: **14 passed** (10 existing + 4 ELF checks).
- Independent report-validator suite: **5 passed**.
- `ERL_FLAGS='+S 2:2 +A 2' sh scripts/containment/focused.sh`: **20 Gleam tests
  passed**. This is the focused F02 project, not the entire application.
- Real isolated kernel suite: **passed** on Linux ARM64
  `7.0.14-orbstack-00380-ga7e0a2dc9535`, Docker 29.4.0.
- Missing `/qa` and a forbidden `/bin -> /boundary` alias: **pre-target refusal
  passed** in separate actual containers using the final artifact.

The kernel suite checked successful installation marker; allowed TCP connect
and bind; denied connect against a genuinely listening peer; denied bind;
UDP4/6, Unix/raw/packet/socketpair and io_uring denial; namespace syscall denial;
read/write path boundaries; inherited rules after fork/exec; UID/GID/groups,
capabilities, NNP/seccomp, hard limits, exact environment, stdin EOF and planted
FD closure; malformed CLI and unprivileged launch rejection without marker
execution. Descendants intentionally do not reread their own proc-status inode:
the narrow proc rule is bound to the original launcher's PID through exec.

## Exact final parent artifacts

| Artifact | SHA-256 |
| --- | --- |
| `build/containment/zig-launcher/aarch64/bin/launch` | `f335729922d115fd5426d58fcb176c61a06f88011da1e66864451a9db402fc70` |
| `build/containment/zig-launcher/x86_64/bin/launch` | `111c0940d4267e8882871650e485910419f618bdabd11725bd92e1684c27fd88` |
| `scripts/containment/launcher/main.zig` | `eff7d5e2140cf5fe3ab3b8f03f0c2c1644d550a20d50295776bc2c2ae4d50a0c` |
| `scripts/containment/launcher/policy.zig` | `5eef305f0a73fb357246df96acbe9b09c15c69a75ef7d75eb4f2418f44b22652` |
| `scripts/containment/launcher/build.zig` | `468658f1d53f77ca1d30cb8db3eb8967faf373e084801384425cfda3d118070d` |

Worker artifacts had different hashes because build/debug paths differ. Only the
parent-built hashes above describe the final kernel executions. Source was
byte-verified on import and rebuilt locally, not replaced with a worker binary.

The immutable existing base image was
`sha256:7d46a07936af93fcce097459055f93ab07331509aa55f4a2a90d95a3ace1850e`
(`rancher/mirrored-pause:3.6`, ARM64). Only launcher/probe executables and
synthetic directories/markers were staged. No host mounts, exposed ports,
provider input, ambient credentials or downloaded packages were used. The
runtime was read-only, network-none, private IPC/cgroup/PID namespaces, NNP,
capabilities limited to the UID/GID transition, and bounded memory/PIDs/CPU.

Receipts under ignored `build/containment/`:

| Gate | Directory | Result |
| --- | --- | --- |
| Final complete kernel suite | `mimic-launcher-probe-945691d6c093` | exit 0, strict report accepted |
| Final forbidden runtime alias | `mimic-launcher-probe-9bc1f98178e6` | exit 1, pre-target refusal accepted |
| Final missing required directory | `mimic-launcher-probe-6e4b8f7ee404` | exit 1, pre-target refusal accepted |

Each directory retains `inputs.json`, suite stdout/stderr, exact daemon exit
state and `result.json`. Successful complete stdout SHA-256:
`da86f68320dd2db69af416bd33a6cdb0144eef4e0b53131852e8f5b5068899e8`.
Both negative stdout hashes:
`ff66758fe674eb61f7a4b8136dd8c638a617b38a45a40b2619d957d039403348`.
Each owned container's stopped state and removal/absence were checked; only the
new synthetic fixture images were removed, never the base image.

## Failed attempts and corrections retained

- Initial ELF-test patch missed its final indented runner line; import failed
  before tests. Corrected; all four artifact tests subsequently passed.
- The first fixture image recipe used `FROM sha256:...`. BuildKit interpreted
  it as a registry tag and attempted metadata/auth lookup despite `--pull=false`;
  lookup failed before target execution. No project source or secrets were in
  that context. The gate now uses `docker create --pull=never` on the exact local
  image ID, copies only explicit synthetic artifacts to a never-started staging
  container, and snapshots locally. It does not use BuildKit or registry lookup.
  Retained: `mimic-launcher-probe-ef3e84da0895`.
- First executed probe reported TCP checks false because the *probe* tried to
  set receive/send timeout options that the launcher deliberately denies. The
  target already has an independent eight-second alarm, so those unnecessary
  option calls were removed; TCP permission checks were unchanged. The first
  failure is `mimic-launcher-probe-bf0169fef772`; corrected earlier artifact
  passed separately before final-source rebuild.
- A proposed `/.dockerenv` symlink negative did not establish that symlink in
  the running Docker container and the suite passed instead of refusing. It is
  **inconclusive**, not a passed negative or demonstrated bypass. Retained:
  `mimic-launcher-probe-af16b7502555`. That unsupported fixture option was removed.
  Final source separately uses NOFOLLOW and requires a regular marker file.
- Static review caught/fixed missing Landlock syscall flags, clone3 fallback
  errno, missing CLONE_PARENT masking, overly broad setsockopt denial, unsafe
  runtime alias targets, and followed `/.dockerenv`. These source changes
  preceded the final parent build/kernel run.

## Remaining boundaries

x86_64 is cross-compiled and its BPF logic pure-tested, not kernel-executed here.
Unsupported-kernel refusal is source-enforced but not measured on an older kernel.
The full existing F02 process-tree fault suite (PID1, lease expiry, parent kill,
setsid descendants and daemon cleanup failure) remains unperformed with a complete
approved Erlang/native-client image. No `qualified_f02` field was set true.

This is a constrained syscall profile, not a claim all native clients run without
additional reviewed permissions. Only SO_REUSEADDR is admitted via setsockopt;
ioctls and ancillary-message APIs remain denied. Landlock execution denial is not
an interpreter/JIT prohibition. Trust in the immutable image, private pipe
provenance, outer namespace and kernel remains explicit.
