#!/usr/bin/env python3
"""Verify the actual attached checkout. No overlays or alternative scaffolds."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = "3e00808ff0fefbb6728edb1769c17139ef0fd93a"
CPA = "acdace936fa7df2905500c7f5e0a97d683138dea"


def verify_manifest(root, manifest):
    seen = set()
    for line in manifest.read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        name = name.removeprefix("*")
        path = root / name
        if (name in seen or path.is_symlink()
                or not path.resolve().is_relative_to(root.resolve())):
            raise SystemExit("unsafe or duplicate manifest path")
        seen.add(name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise SystemExit("source hash mismatch: " + name)
    if not seen:
        raise SystemExit("empty source manifest")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpa-source", type=Path,
                        help="optional already-downloaded exact pinned CPA tree")
    parser.add_argument("--checkpoint", type=Path,
                        help="optional Devin source SHA256 manifest to verify")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    subprocess.run(["git", "cat-file", "-e", BASE + "^{commit}"],
                   cwd=ROOT, check=True)
    subprocess.run(["git", "merge-base", "--is-ancestor", BASE, "HEAD"],
                   cwd=ROOT, check=True)
    if args.cpa_source:
        verify_manifest(args.cpa_source.resolve(strict=True),
                        ROOT / "docs/devin/CPA_SHA256SUMS")
    if args.checkpoint:
        verify_manifest(ROOT, args.checkpoint.resolve(strict=True))
    print("Verified published base ancestry:", BASE, flush=True)
    print("CPA source pin (not differential evidence):", CPA, flush=True)
    if not args.check_only:
        for command in [
            ["gleam", "format", "--check", "src", "test"],
            ["gleam", "test"],
            ["gleam", "run", "-m", "devin_scenarios"],
        ]:
            subprocess.run(["mise", "exec", "gleam@1.18.1", "--", *command],
                           cwd=ROOT, check=True)
        # Fresh VM restoration must not reseed permanent session credentials.
        state = Path(tempfile.mkdtemp(prefix="devin-restart-", dir=ROOT / "build"))
        state.chmod(0o700)
        for phase in ["seed", "restore"]:
            subprocess.run(
                ["mise", "exec", "gleam@1.18.1", "--", "gleam", "run", "-m",
                 "devin_persistence_scenario", "--", phase, str(state)],
                cwd=ROOT, check=True,
            )


if __name__ == "__main__":
    main()
