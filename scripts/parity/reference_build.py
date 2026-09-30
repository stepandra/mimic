"""Acquire/build the unmodified reference; never executes CPA.

Download is a separate, explicitly online dependency phase. Build uses cached
modules with GOPROXY=off. Runtime containment belongs to reference_driver.py.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build/parity-reference"
REVISION = "acdace936fa7df2905500c7f5e0a97d683138dea"
ARCHIVE_SHA256 = "56c970726edbd07591b77c1b6be18f733368f8a2f52a2f0931c928b30c13b540"
URL = "https://codeload.github.com/router-for-me/CLIProxyAPI/tar.gz/" + REVISION
SOURCE = BUILD / ("CLIProxyAPI-" + REVISION)
ARCHIVE = BUILD / ("cpa-" + REVISION + ".tar.gz")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_source():
    if digest(ARCHIVE) != ARCHIVE_SHA256:
        raise ValueError("reference archive hash mismatch")
    expected = {}
    with tarfile.open(ARCHIVE) as archive:
        for member in archive:
            parts = Path(member.name).parts
            if (not parts or parts[0] != SOURCE.name or ".." in parts
                    or member.issym() or member.islnk()):
                raise ValueError("unsafe source archive")
            if member.isfile():
                relative = str(Path(*parts[1:]))
                expected[relative] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
    actual = {str(p.relative_to(SOURCE)): digest(p)
              for p in SOURCE.rglob("*") if p.is_file()}
    if actual != expected or any(p.is_symlink() for p in SOURCE.rglob("*")):
        raise ValueError("source differs from pinned archive; no overlays accepted")
    return expected


def environment():
    # No inherited HOME, credentials, proxy, Go workspace, GOFLAGS or toolchain download.
    go = Path(shutil.which("go") or "/missing/go").resolve()
    for name in ("build-home", "build-tmp"):
        (BUILD / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    return go, {
        "PATH": str(go.parent) + ":/usr/bin:/bin",
        "HOME": str(BUILD / "build-home"),
        "TMPDIR": str(BUILD / "build-tmp"),
        "GOMODCACHE": str(BUILD / "gomodcache"),
        "GOCACHE": str(BUILD / "gocache"),
        "GOPATH": str(BUILD / "gopath"),
        "GOTOOLCHAIN": "local", "CGO_ENABLED": "0",
        "GOPROXY": "off", "GOSUMDB": "off", "GOWORK": "off",
        "GOENV": "off", "GOFLAGS": "",
    }


def command(argv, env, name, cwd=None):
    def bounds():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, 512 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CPU, (600, 600))
    with (BUILD / name).open("wb") as log:
        child = subprocess.Popen(argv, cwd=cwd or SOURCE, env=env, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True,
                                 preexec_fn=bounds)
        try:
            if child.wait(timeout=600) != 0:
                raise RuntimeError("reference build/download failed: " + name)
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["download", "build"])
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True, mode=0o700)
    go, env = environment()
    if args.phase == "download":
        if not ARCHIVE.exists():
            with urllib.request.urlopen(URL, timeout=60) as response, ARCHIVE.open("xb") as out:
                total = 0
                deadline = time.monotonic() + 120
                while data := response.read(65536):
                    total += len(data)
                    if total > 32 * 1024 * 1024 or time.monotonic() > deadline:
                        raise ValueError("archive exceeds bound")
                    out.write(data)
        if digest(ARCHIVE) != ARCHIVE_SHA256:
            raise ValueError("archive mismatch")
        if not SOURCE.exists():
            with tarfile.open(ARCHIVE) as archive:
                archive.extractall(BUILD, filter="data")
        verify_source()
        env.update(GOPROXY="https://proxy.golang.org", GOSUMDB="sum.golang.org")
        command([str(go), "mod", "download"], env, "download.log")
    else:
        sources = verify_source()
        command([str(go), "mod", "verify"], env, "verify.log")
        argv = [str(go), "build", "-mod=readonly", "-trimpath", "-buildvcs=false",
                "-p=4", "-o", str(BUILD / "cpa"), "./cmd/server"]
        command(argv, env, "build.log")
        verify_source()
        info = subprocess.check_output([str(go), "version", "-m", str(BUILD / "cpa")],
                                       env=env, timeout=10).decode()
        tool_dir = Path(subprocess.check_output([str(go), "env", "GOTOOLDIR"],
                                               env=env, timeout=10).decode().strip())
        manifest = {
            "schema": "mimic.cpa-build/v1", "revision": REVISION,
            "source_url": URL, "archive_sha256": ARCHIVE_SHA256,
            "source_files": sources, "source_modified": False,
            "go_mod_sha256": digest(SOURCE / "go.mod"),
            "go_sum_sha256": digest(SOURCE / "go.sum"),
            "toolchain_sha256": digest(go), "toolchain_path": str(go),
            "toolchain_tools": {name: digest(tool_dir / name) for name in ("compile", "link", "asm")},
            "executable_sha256": digest(BUILD / "cpa"), "build_argv": argv,
            "build_info": info, "build_environment": env,
        }
        (BUILD / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps({k: v for k, v in manifest.items()
                          if k not in ("source_files", "build_info", "build_environment")}, indent=2))


if __name__ == "__main__":
    main()
