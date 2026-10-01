"""Synthetic, harmless F02 probes. The Gleam owner invokes this inside its sandbox.

Never run the descendant cases on the host. No private data, provider/account
access, installation, external hosts or sockets mounted from the host.
"""
import errno
import json
import os
from pathlib import Path
import resource
import socket
import subprocess
import sys
import time


def denied(action):
    try:
        action()
        return False
    except OSError as error:
        return error.errno in (errno.EACCES, errno.EPERM, errno.EROFS)


def connect(port):
    with socket.create_connection(("127.0.0.1", port), timeout=1) as sock:
        return sock.recv(100) == b"synthetic-local-fixture\n"


def bind(port):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", port))
    return True


def socket_type(family, kind):
    with socket.socket(family, kind):
        pass


def baseline():
    status = Path("/proc/self/status").read_text()
    work = Path("/work/f02-synthetic")
    work.write_text("synthetic")
    core = resource.getrlimit(resource.RLIMIT_CORE)
    cpu = resource.getrlimit(resource.RLIMIT_CPU)
    size = resource.getrlimit(resource.RLIMIT_FSIZE)
    files = resource.getrlimit(resource.RLIMIT_NOFILE)
    checks = {
        "filesystem_isolated": denied(lambda: Path("/containment/forbidden").read_bytes()),
        "owner_channel_denied": denied(lambda: Path("/proc/1/fd/0").read_bytes()),
        "root_write_denied": denied(lambda: Path("/etc/f02-synthetic").write_text("synthetic")),
        "workspace_allowed": work.read_text() == "synthetic",
        "environment_clean": dict(os.environ) == {
            "PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/work/home",
            "TMPDIR": "/tmp", "LANG": "C.UTF-8", "TZ": "UTC",
            "LD_LIBRARY_PATH": "/usr/local/lib",
        },
        "target_unprivileged": os.getuid() == os.geteuid() == 10001,
        "no_new_privileges": "NoNewPrivs:\t1" in status,
        "capabilities_dropped": "CapEff:\t0000000000000000" in status,
        "approved_tcp_allowed": connect(39001),
        "denied_tcp_rejected": denied(lambda: connect(39002)),
        "approved_bind_allowed": bind(39003),
        "denied_bind_rejected": denied(lambda: bind(39004)),
        "unix_socket_rejected": denied(lambda: socket_type(socket.AF_UNIX, socket.SOCK_STREAM)),
        "udp_socket_rejected": denied(lambda: socket_type(socket.AF_INET, socket.SOCK_DGRAM)),
        "resources_bounded": (
            core == (0, 0) and cpu == (40, 40)
            and size == (8388608, 8388608) and files == (256, 256)
            and 0 < int(Path("/sys/fs/cgroup/memory.max").read_text()) <= 2048 * 1024**2
            and 0 < int(Path("/sys/fs/cgroup/pids.max").read_text()) <= 256
        ),
    }
    print(json.dumps(checks, sort_keys=True), flush=True)
    return 0 if all(checks.values()) else 1


def descendant(case):
    # Ignore leader ownership, session and process group. The PID namespace is
    # the final lifetime boundary; it must also kill a double-forked daemon.
    code = (
        "import os,signal,time;"
        "signal.signal(signal.SIGTERM,signal.SIG_IGN);"
        + ("os.setsid();p=os.fork();"
           "os._exit(0) if p else None;" if case == "setsid" else "")
        + "time.sleep(120)"
    )
    subprocess.Popen(
        ["/usr/local/bin/python3", "-c", code, "f02-adversarial-descendant"],
        # Retain the target's private stdout/stderr: an inherited pipe must not
        # postpone namespace shutdown after leader exit. Never inherit the
        # root owner's lease input, which the launcher replaced with /dev/null.
        stdin=subprocess.DEVNULL,
        start_new_session=False,
    )
    time.sleep(3 if case in ("early_exit", "setsid") else 120)
    return 0


def main():
    if (not Path("/.dockerenv").is_file() or os.getuid() != 10001
            or set(os.listdir("/sys/class/net")) != {"lo"}):
        raise RuntimeError("synthetic_probes_require_owned_container")
    case = sys.argv[1] if len(sys.argv) == 2 else ""
    if case == "baseline":
        return baseline()
    if case in ("parent_sigkill", "lease_expired", "timeout", "early_exit", "setsid"):
        return descendant(case)
    raise RuntimeError("unknown_fixed_synthetic_fault_case")


if __name__ == "__main__":
    sys.exit(main())
