#!/usr/bin/env python3
"""Stage verified source only and run Claude's local runtime-v4 consumer gate."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


RUNTIME_MANIFEST = "b6730e91c13503ce469c7b4e8721791b08135eb2ac28e298ffe874eeba3d3784"
# Explicitly supersedes the pre-ambiguity-fix Claude handoff. Runtime v4 is
# unchanged; only the provider source/test manifest moves to revision 2.
CLAUDE_MANIFEST = "5c050a4f2e4e5aa1921dbaa752262ab4838b66a1f01a74cfc1b2521d6d6b6e8a"
ROOT = Path(__file__).resolve().parents[4]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_manifest(root, name, expected):
    manifest = root / name
    if digest(manifest) != expected:
        raise SystemExit(f"Manifest digest mismatch: {name}")
    paths = []
    for line in manifest.read_text().splitlines():
        checksum, relative = line.split(maxsplit=1)
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit("Unsafe manifest path")
        source = root / path
        if source.is_symlink() or not source.is_file():
            raise SystemExit(f"Expected regular source file: {relative}")
        if not source.resolve().is_relative_to(root.resolve()):
            raise SystemExit("Manifest path escapes source root")
        if digest(source) != checksum:
            raise SystemExit(f"Source digest mismatch: {relative}")
        paths.append(path)
    return paths


def run(overlay, *args):
    subprocess.run(
        ["mise", "exec", "gleam@1.18.1", "--", "gleam", *args],
        cwd=overlay,
        check=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime_snapshot", type=Path)
    args = parser.parse_args()
    runtime = args.runtime_snapshot.resolve()
    runtime_paths = verify_manifest(runtime, "SHA256SUMS", RUNTIME_MANIFEST)
    if len(runtime_paths) != 12 or any(p.parts[0] != "src" for p in runtime_paths):
        raise SystemExit("Expected exactly twelve approved runtime source files")
    claude_paths = verify_manifest(ROOT, "docs/CLAUDE_PROVIDER_V2_SHA256SUMS", CLAUDE_MANIFEST)
    # Copy only Git/JJ-tracked application sources plus the explicitly manifested
    # Claude delta. Never copy a sibling build/, .jj/, .git/, or credential store.
    tracked = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=ROOT
    ).decode().split("\0")
    local_paths = {Path(p) for p in tracked if p}
    local_paths.update(claude_paths)
    local_paths = {
        p for p in local_paths
        if p.parts[0] in {"src", "test", "priv", "examples", "docs"}
        or str(p) in {"gleam.toml", "manifest.toml", "mimic"}
    }
    (ROOT / "build").mkdir(exist_ok=True)
    overlay = Path(tempfile.mkdtemp(prefix="claude-runtime-v4-", dir=ROOT / "build"))
    os.chmod(overlay, 0o700)
    for relative in sorted(local_paths):
        source = ROOT / relative
        if not source.is_file() or source.is_symlink():
            raise SystemExit(f"Expected regular local source: {relative}")
        target = overlay / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for relative in runtime_paths:
        target = overlay / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(runtime / relative, target)
    source = Path(__file__).with_name("claude_runtime_v4_test.gleam.in")
    shutil.copy2(source, overlay / "test/claude_runtime_v4_test.gleam")
    print(f"OVERLAY={overlay}", flush=True)
    print(f"RUNTIME_MANIFEST_SHA256={RUNTIME_MANIFEST}", flush=True)
    print(f"CLAUDE_MANIFEST_SHA256={CLAUDE_MANIFEST}", flush=True)
    run(overlay, "format", "--check", "src", "test")
    run(overlay, "test")
    run(overlay, "run", "-m", "claude_runtime_v4_test")
    state = overlay / "build/claude-fresh-vm-private"
    state.mkdir(mode=0o700)
    run(overlay, "run", "-m", "claude_runtime_v4_test", "--", "seed", str(state))
    run(overlay, "run", "-m", "claude_runtime_v4_test", "--", "restore", str(state))
    print("PASS: Claude/runtime-v4 consumer gate; assembled_ingress=false", flush=True)


if __name__ == "__main__":
    main()
