"""macOS Seatbelt containment. Unsupported hosts fail closed, never run bare.

Only explicitly bound fixture/ingress ports are permitted, not all loopback.
The child gets no inherited environment or operator files. Policy and negative
probes are retained with the synthetic run. No outbound Internet probe is used.
"""
from dataclasses import dataclass, field
import hashlib
import json
from pathlib import Path
import platform
import resource
import socket
import stat
import subprocess

from local_driver import stop


@dataclass(frozen=True)
class LaunchPolicy:
    """Parent-held policy bytes and directory identity, never loaded from child files."""
    directory: Path
    text: str
    _identity: tuple = field(init=False, repr=False)

    def __post_init__(self):
        directory = Path(self.directory)
        if directory.is_symlink():
            raise ValueError("sandbox root cannot be a link")
        directory = directory.resolve(strict=True)
        info = directory.stat(follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("sandbox root must be a private 0700 directory")
        if not isinstance(self.text, str) or "\x00" in self.text or len(self.text.encode()) > 65536:
            raise ValueError("invalid bounded policy text")
        object.__setattr__(self, "directory", directory)
        object.__setattr__(self, "_identity", (info.st_dev, info.st_ino))

    def validate(self):
        info = self.directory.stat(follow_symlinks=False)
        if (not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700
                or (info.st_dev, info.st_ino) != self._identity
                or self.directory.resolve(strict=True) != self.directory):
            raise ValueError("sandbox root changed since policy binding")

    @property
    def sha256(self):
        return hashlib.sha256(self.text.encode()).hexdigest()


def limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (4 * 1024 * 1024, 4 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
    resource.setrlimit(resource.RLIMIT_CPU, (40, 40))


def policy(directory, ingress, upstream):
    if platform.system() != "Darwin":
        raise RuntimeError("containment unavailable: reviewed macOS Seatbelt required")
    directory = Path(directory).resolve()
    if not directory.is_dir() or any(not 1 <= p <= 65535 for p in (ingress, upstream)):
        raise ValueError("invalid sandbox boundary")
    # Deny operator/home/project reads. System runtime remains readable.
    # Only the isolated staging directory is an exception, not the build cache.
    return '\n'.join([
        '(version 1)', '(allow default)', '(deny network*)',
        '(deny file-read* (subpath "/Users") (subpath "/Volumes")'
        ' (subpath "/private/var/folders") (subpath "/private/var/root")'
        ' (subpath "/private/tmp"))',
        '(deny file-write*)',
        '(allow file-read* (subpath ' + json.dumps(str(directory)) + '))',
        # MIMIC rejects symlink ancestors of credential paths. Permit stat of
        # those directories, but not listing/reading their contents.
        '(allow file-read-metadata ' + ' '.join(
            '(literal ' + json.dumps(str(p)) + ')' for p in directory.parents) + ')',
        '(allow file-write* (literal "/dev/null"))',
        *['(allow file-write* (subpath ' + json.dumps(str(directory / name)) + '))'
          for name in ("state", "auth", "home", "tmp")],
        '(allow file-write* (literal ' + json.dumps(str(directory / "target.log")) + '))',
        f'(allow network-inbound (local ip "localhost:{ingress}"))',
        f'(allow network-outbound (remote ip "localhost:{upstream}"))',
    ]) + '\n'


def environment(directory):
    directory = Path(directory)
    return {
        "PATH": "/usr/bin:/bin", "HOME": str(directory / "home"),
        "TMPDIR": str(directory / "tmp"), "XDG_CONFIG_HOME": str(directory / "home"),
        "XDG_CACHE_HOME": str(directory / "home/cache"), "GOMAXPROCS": "2",
        "LANG": "C", "TZ": "UTC",
    }


def argv(boundary, command):
    if not isinstance(boundary, LaunchPolicy):
        raise TypeError("parent-held LaunchPolicy required; policy filenames are not accepted")
    boundary.validate()
    return ["/usr/bin/sandbox-exec", "-p", boundary.text, *command]


def record_policy(boundary):
    boundary.validate()
    with (boundary.directory / "sandbox.sb").open("x") as output:
        output.write(boundary.text)


def probe(boundary, forbidden_file):
    directory = boundary.directory
    record_policy(boundary)
    env = environment(directory)
    def run(command):
        return subprocess.run(argv(boundary, command), cwd=directory, env=env,
                              capture_output=True, timeout=5, preexec_fn=limits)
    allowed = directory / "probe-synthetic"
    allowed.write_text("synthetic")
    yes = run(["/bin/cat", str(allowed)])
    no = run(["/bin/cat", str(forbidden_file)])
    # The bundled system curl has no credential config because HOME is private.
    # The denied port is a real listening local socket, not an unreachable host.
    with socket.socket() as denied:
        denied.bind(("127.0.0.1", 0))
        denied.listen(1)
        denied.settimeout(0.1)
        port = denied.getsockname()[1]
        blocked = run(["/usr/bin/curl", "--noproxy", "*", "--max-time", "1",
                       f"http://127.0.0.1:{port}/"])
        try:
            connection, _ = denied.accept()
            connection.close()
            connected = True
        except TimeoutError:
            connected = False
    checks = {
        "private_runtime_read": yes.returncode == 0 and yes.stdout == b"synthetic",
        "repository_read_denied": no.returncode != 0 and not no.stdout,
        "unapproved_loopback_denied": blocked.returncode != 0 and not connected,
    }
    (directory / "containment.json").write_text(json.dumps(checks, indent=2))
    if not all(checks.values()):
        raise RuntimeError("containment probe failed; target not started")
    return checks


def start(boundary, command, log):
    return subprocess.Popen(argv(boundary, command), cwd=boundary.directory,
                            env=environment(boundary.directory), stdin=subprocess.DEVNULL,
                            stdout=log, stderr=log, start_new_session=True,
                            preexec_fn=limits)
