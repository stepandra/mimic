# F02 Linux syscall launcher

Narrow kernel mechanism, not a policy engine or process manager. The Gleam owner
selects the target/ports, owns qualification/lease/deadline and runs as namespace
PID1. This executable installs restrictions and directly `execve`s the target;
it does not fork a supervisor, reap descendants or replace that lifetime fence.
No C, libc, external Zig packages, downloads or target execution in this build.

## Build and pure tests

Compiler is **Zig 0.16.0**, enforced by `build.zig` (available installation:
`/opt/homebrew/bin/zig`, Homebrew 0.16.0_1). From the repository root:

```sh
ZIG=/opt/homebrew/bin/zig
CACHE="$PWD/build/containment/zig-launcher/cache"
GLOBAL="$PWD/build/containment/zig-launcher/global"
"$ZIG" build --build-file scripts/containment/launcher/build.zig \
  --cache-dir "$CACHE" --global-cache-dir "$GLOBAL" test
for arch in aarch64 x86_64; do
  "$ZIG" build --build-file scripts/containment/launcher/build.zig \
    --cache-dir "$CACHE" --global-cache-dir "$GLOBAL" \
    -Dtarget="$arch-linux-musl" -Doptimize=ReleaseSafe \
    --prefix "$PWD/build/containment/zig-launcher/$arch"
done
"$ZIG" fmt --check scripts/containment/launcher/*.zig
```

`test` builds/runs **only** `policy.zig` on the build host: strict CLI parsing,
finite port sets and a pure classic-BPF evaluator for both Linux architectures.
It never invokes launcher `main`, installs a kernel rule or executes a target.
Only Linux x86_64 and aarch64 production targets compile. Output ELF files are
static, with no interpreter/libc dependency. Packaging integration is existing
`package.sh <absolute artifact path>` using the matching architecture's
`build/containment/zig-launcher/<arch>/bin/launch`. Do not execute artifacts on
the host or use `--check` as a host feature probe.

## Exact owner ABI

```
/containment/launch --check
/containment/launch --bind-ports 39003 --connect-ports 39001 \
  --cpu-seconds 40 --file-bytes 8388608 --no-files 256 \
  -- /usr/local/bin/python3 /qa/containment_faults.py baseline
```

Flags/order/limits match `mimic/containment/owner.gleam`; alternate spellings,
unknown/duplicate flags and different limit values are rejected. `-` is an empty
port set. Each set has at most 16 distinct decimal ports 1..65535, no leading
zeros. At most 256 total arguments and 128 KiB of argument bytes; target absolute
path at most 4095 bytes. Target argv is passed unchanged, not through a shell.
Errors emit a fixed category (`Kernel`, `Setup`, parser/allocation errors) to
stderr and exit 126; no target argv or inherited environment is logged.

`--check` is itself the disposable launcher process. It installs **the same**
identity, limits, workspace, Landlock and seccomp restrictions using synthetic
bind39003/connect39001 rules, then writes exactly
`mimic.containment-launch/v1\n`. It does not exec a target, spawn a child or claim
qualification. It creates `/work/home` if absent; subsequent check/launch accepts
only a real UID/GID10001 mode0700 directory, never a symlink. Failed installation
never prints the marker. This confirms installation, not observed allow/deny
behavior, PID1 lifetime, network topology, image provenance or whole F02 readiness.

## Required runtime, in order

- Trusted owner starts launcher UID0 with SETUID/SETGID only, inside the existing
  read-only, network-none, private PID/cgroup namespace container. It must supply
  private **write-only FIFO** stdout/stderr, as Erlang ports do. Regular files,
  TTYs and socket stdio are unsupported and rejected because inherited sockets
  bypass Landlock connect checks. Private channel provenance is owner-owned.
- Launcher replaces stdin with verified character device `/dev/null` (1:3),
  clears CLOEXEC on standard descriptors, closes every FD >=3 with mandatory
  `close_range`, sets no-new-privileges, clears ambient/supplementary groups,
  disables keepcaps, sets all GIDs/UIDs10001, capsets effective/permitted/inheritable
  sets to zero and verifies them plus IDs/groups/NNP. Core=0, CPU=40, file=8MiB,
  FD=256 are both soft and hard limits. No fallback for denied/absent syscalls.
- Bounding capabilities may still contain SETUID/SETGID: emptying the bounding
  set requires SETPCAP, deliberately not granted. Zero inheritable/permitted/
  effective/ambient sets, UID separation, NNP and blocked capset/identity syscalls
  prevent reacquisition. Seccomp also blocks prctl after setup. Dumpability is
  cleared before exec; ordinary exec may reset it, so UID separation remains key.
- `/work` must be a real directory owned10001:10001 mode0700. `/tmp` must be a real
  directory. Owner supplies bounded private tmpfs for both, `/tmp` noexec. Cwd is
  `/work`, umask077, HOME `/work/home`. A second close_range precedes seccomp.

### Landlock policy

Require ABI >=4, including TCP bind/connect. All ABI4 filesystem rights are
handled; ioctl-device right is additionally handled on ABI>=5. Each supplied
port is granted only its bind or connect right. Empty lists grant no ports.
Outer network-none topology is essential: Landlock ports are not IP restrictions.

Required read/execute directory trees: `/usr`, `/qa` (real directories).
Optional distribution directories `/bin`, `/sbin`, `/lib`, `/lib64` may be real
or resolve exactly to their corresponding `/usr` directory. Opened descriptors'
canonical `/proc/self/fd` paths are checked, not merely symlink text. No general
`/` read grant, and no `/containment` or `/boundary` grant.

Only `/work` and `/tmp` receive write/create/remove/rename/truncate grants, never
execute or device/socket creation. FIFOs, regular files, directories and symlinks
are permitted there. Landlock no-exec does not prevent interpreters reading
scripts or JIT code; this is an OS resource boundary, not arbitrary-code prevention.

Required exact readable files: `/proc/self/status`,
`/sys/fs/cgroup/memory.max`, `/sys/fs/cgroup/pids.max`, `/.dockerenv`.
Only directory-list permission for `/sys/class/net`; no broad `/sys` or `/proc`
grant. `/proc/self/status` pins the launcher's current PID inode: exec preserves
access, but forked descendants do **not** receive their own dynamic self-status
allowance. Never broaden `/proc` to accommodate that limitation.

`/dev/null` is read/write; other devices are not granted. Optional exact readable
runtime configuration files: `/etc/ld.so.cache`, `/etc/localtime`,
`/etc/nsswitch.conf`, `/etc/hosts`, `/etc/resolv.conf`, `/etc/passwd`, `/etc/group`.
They may resolve to themselves or inside `/usr` (e.g. zoneinfo), never arbitrary
protected files. Only ENOENT skips an optional path; other errors are fatal.
Images/namespace mounts and all read-only root paths remain trusted owner inputs.

### Seccomp and environment

Classic BPF validates audit architecture, kills mismatches/x32 namespace numbers,
and allows sockets only AF_INET/AF_INET6 + SOCK_STREAM with optional CLOEXEC/
NONBLOCK + protocol0/TCP6. Argument high words cannot smuggle alternate values.
Socketpair, Unix/UDP/raw/packet families, io_uring, namespace/network-control and
mount APIs, ptrace/process-vm/pidfd descriptor access, kernel module/key/BPF/perf
interfaces, capability/identity changes and all ioctls are denied EPERM.
`setsockopt` allows only SOL_SOCKET/SO_REUSEADDR for existing HTTPServer fixtures;
other options and ancillary-message APIs are denied. `clone3` returns ENOSYS so
libc may use legacy clone, whose namespace flags and CLONE_PARENT are denied.
Ordinary fork/thread creation and setsid remain available; PID1 owns descendants.
This is intentionally constrained runtime compatibility, not a universal native
client profile or a complete syscall allowlist. Unsupported functionality must
fail explicitly and require review before extending policy.

Exact exec environment (nothing inherited):
`PATH=/usr/local/bin:/usr/bin:/bin`, `HOME=/work/home`, `TMPDIR=/tmp`,
`LANG=C.UTF-8`, `TZ=UTC`, `LD_LIBRARY_PATH=/usr/local/lib`.

## Evidence boundary

This worker compiled both architectures, passed pure host tests and formatting.
It did **not** run Linux targets or kernel checks. Separate parent-owned isolated
kernel probe results must identify their source/artifact hashes and environment;
they are not inferred from compilation or this README. Full BEAM PID1 Docker
qualification and native-runtime compatibility remain separate gates. No Gleam
sources changed and no shared Gleam validation lock/build was used here.
