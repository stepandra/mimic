#!/usr/bin/env python3
"""Create an ignored, source-only overlay and test actual runtime dependencies."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = "c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4"
RUNTIME_MANIFEST_SHA256 = "33f373d1f498b7f1f81a4043aa3f530451c01d56fe1c7d1b3fdc66535026e3a1"
RUNTIME_FILES = {
    "src/mimic/providers/contracts.gleam",
    "src/mimic/providers/registry.gleam",
    "src/mimic/providers/runtime.gleam",
    "src/mimic/providers/transport.gleam",
    "src/mimic/auth/runtime.gleam",
    "src/mimic/auth/runtime_store.gleam",
    "src/mimic/auth/storage.gleam",
    "src/mimic/egress.gleam",
    "src/mimic/fleet.gleam",
    "src/mimic/quota.gleam",
    "src/mimic_egress_ffi.erl",
    "src/mimic_provider_runtime_ffi.erl",
}


def verify_runtime(snapshot):
    if hashlib.sha256((snapshot / "SHA256SUMS").read_bytes()).hexdigest() != RUNTIME_MANIFEST_SHA256:
        raise SystemExit("not the approved immutable runtime-v3 manifest")
    manifest = {}
    for line in (snapshot / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split()
        name = name.removeprefix("*").removeprefix("./")
        if name not in RUNTIME_FILES or name in manifest:
            raise SystemExit("unexpected or duplicate runtime manifest path")
        path = snapshot / name
        if path.is_symlink() or not path.resolve().is_relative_to(snapshot):
            raise SystemExit("runtime source must remain inside the snapshot")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit("runtime source hash mismatch: " + name)
        manifest[name] = digest
    if set(manifest) != RUNTIME_FILES:
        raise SystemExit("runtime snapshot must contain exactly 12 listed sources")
    if "SessionToken(" not in (snapshot / "src/mimic/providers/contracts.gleam").read_text():
        raise SystemExit("v2 is immutable but insufficient: Devin requires additive v3")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--runtime", type=Path,
                      help="owner-published immutable v3 source snapshot")
    mode.add_argument("--pure", action="store_true",
                      help="baseline plus pure Devin protocol only; no runtime claim")
    args = parser.parse_args()
    snapshot = args.runtime.resolve(strict=True) if args.runtime else None
    manifest = verify_runtime(snapshot) if snapshot else {}

    (ROOT / "build").mkdir(exist_ok=True)
    overlay = Path(tempfile.mkdtemp(prefix="devin-integration-", dir=ROOT / "build"))
    base_files = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", BASE], cwd=ROOT, text=True
    ).splitlines()
    # Read this attached worktree's baseline only. No checkout or owner caches.
    for name in base_files:
        if (name.startswith(("src/", "test/", "priv/", "examples/"))
                or name in {"gleam.toml", "manifest.toml"}):
            target = overlay / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(subprocess.check_output(
                ["git", "show", BASE + ":" + name], cwd=ROOT))
    own_files = [
        *ROOT.glob("src/mimic/providers/devin/**/*.gleam"),
        *ROOT.glob("src/mimic_devin_*.erl"),
        *ROOT.glob("test/devin_*.gleam"),
    ]
    for source in own_files:
        if args.pure and source.name in {
            "bridge.gleam", "devin_runtime_test.gleam", "devin_scenarios.gleam"
        }:
            continue
        target = overlay / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for name in sorted(manifest):
        target = overlay / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(snapshot / name, target)
    if snapshot:
        shutil.copyfile(snapshot / "SHA256SUMS", overlay / "RUNTIME_SHA256SUMS")
    print("Verified runtime sources:", len(manifest), "Overlay:", overlay, flush=True)
    commands = [
        ["mise", "exec", "gleam@1.18.1", "--", "gleam", "format", "--check"],
        ["mise", "exec", "gleam@1.18.1", "--", "gleam", "test"],
    ]
    if snapshot:
        commands.append(
            ["mise", "exec", "gleam@1.18.1", "--", "gleam", "run", "-m", "devin_scenarios"]
        )
    for command in commands:
        subprocess.run(command, cwd=overlay, check=True)


if __name__ == "__main__":
    main()
