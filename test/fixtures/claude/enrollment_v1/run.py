#!/usr/bin/env python3
"""Verify frozen shared dependencies and test Claude enrollment in a private overlay."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[4]
BASE = "3e00808ff0fefbb6728edb1769c17139ef0fd93a"
SNAPSHOTS = [
    (
        "f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc",
        "60bad0938ecf160fc199f9c707821a6552dd72aa8b5cda9e13900ad0af7ba384",
    ),
    (
        "a663d946002aa8eeed255f8df4cde6c49faacf1b304b5ed370eef48cf2f04f5f",
        "5eb52b8c1ef26466a851ef3ff1e2e72a819e4d93d056914b6e682435d6620a40",
    ),
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(directory, expected):
    directory = directory.resolve()
    if (directory / "BASE").read_text().strip() != BASE:
        raise SystemExit("Unexpected shared snapshot base")
    archive = directory / "source.tar.gz"
    manifest = (directory / "SHA256SUMS").read_bytes()
    if digest(archive.read_bytes()) != expected[0] or digest(manifest) != expected[1]:
        raise SystemExit("Shared snapshot hash mismatch")
    wanted = {}
    for line in manifest.decode().splitlines():
        checksum, name = line.split(maxsplit=1)
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or path.parts[0] not in {"src", "test", "docs"}:
            raise SystemExit("Unsafe shared snapshot member")
        if name in wanted:
            raise SystemExit("Duplicate shared snapshot member")
        wanted[name] = checksum
    files = {}
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            if not member.isfile() or member.name not in wanted or member.name in files:
                raise SystemExit("Unexpected shared archive member")
            data = tar.extractfile(member).read()
            if digest(data) != wanted[member.name]:
                raise SystemExit("Shared archive member hash mismatch")
            files[member.name] = data
    if files.keys() != wanted.keys():
        raise SystemExit("Incomplete shared snapshot")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot4", type=Path)
    parser.add_argument("snapshot5", type=Path)
    parser.add_argument("--baseline-login", action="store_true")
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    dependencies = [
        snapshot(args.snapshot4, SNAPSHOTS[0]),
        snapshot(args.snapshot5, SNAPSHOTS[1]),
    ]
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    paths = {Path(name) for name in tracked if name}
    paths.update({Path("src/mimic/providers/claude/login.gleam"),
                  Path("test/claude_login_enrollment_test.gleam")})
    paths = {
        path for path in paths
        if path.parts[0] in {"src", "test", "priv", "examples", "docs", "vendor", "scripts"}
        or str(path) in {"gleam.toml", "manifest.toml", "mimic"}
    }
    (ROOT / "build").mkdir(exist_ok=True)
    overlay = Path(tempfile.mkdtemp(prefix="claude-enrollment-v1-", dir=ROOT / "build"))
    os.chmod(overlay, 0o700)
    for relative in sorted(paths):
        source = ROOT / relative
        if source.is_symlink() or not source.is_file():
            raise SystemExit(f"Expected regular local source: {relative}")
        target = overlay / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for files in dependencies:
        for name, data in files.items():
            target = overlay / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    if args.baseline_login:
        original = subprocess.check_output(
            ["git", "show", BASE + ":src/mimic/providers/claude/login.gleam"], cwd=ROOT
        )
        (overlay / "src/mimic/providers/claude/login.gleam").write_bytes(original)
    print(f"OVERLAY={overlay}", flush=True)
    print(f"BASELINE_LOGIN={args.baseline_login}", flush=True)
    command = ["mise", "exec", "gleam@1.18.1", "--", "gleam"]
    env = dict(os.environ, ERL_FLAGS="+S 2:2 +A 2")
    subprocess.run(command + ["format", "--check", "src", "test"], cwd=overlay, env=env, check=True)
    subprocess.run(command + ["run", "-m", "claude_login_enrollment_test"],
                   cwd=overlay, env=env, check=True)
    if args.full:
        subprocess.run(command + ["test"], cwd=overlay, env=env, check=True)
    print("PASS: synthetic Claude enrollment consumer; no live login", flush=True)


if __name__ == "__main__":
    main()
