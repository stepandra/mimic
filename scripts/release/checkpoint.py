#!/usr/bin/env python3
"""Validate/freeze source checkpoints; never execute tests or install source."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

BASE = "3e00808ff0fefbb6728edb1769c17139ef0fd93a"
CPA = "acdace936fa7df2905500c7f5e0a97d683138dea"
ROOT = Path(__file__).resolve().parents[2]
OVERLAYS = ROOT / "build/integration/cpa-gap/overlays"
MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
FIELDS = {
    "schema", "checkpoint", "owner", "owner_approved", "base", "cpa",
    "dependencies", "files", "tests", "axes", "limits",
}
AXES = {"source", "mock", "differential", "native_lab", "live"}
FORBIDDEN = {".git", ".jj", "build", "private", "state", "node_modules",
             "__pycache__", ".mimic", ".env", "target"}
SOURCE_ROOTS = {"src", "test", "docs", "scripts", "examples", "vendor",
                "priv", ".github"}
ROOT_FILES = {"README.md", "gleam.toml", "manifest.toml", "Makefile",
              ".gitignore"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sha(value):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value)


def source_path(value):
    require(isinstance(value, str) and value, "invalid source path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and str(path) == value, "noncanonical path")
    require(all(part not in FORBIDDEN | {"..", "."} for part in path.parts),
            "forbidden path component")
    require(re.fullmatch(r"[A-Za-z0-9_./-]+", value), "unsafe path characters")
    require(all(not p.startswith(".") or p in {".github", ".gitignore"}
                for p in path.parts), "hidden input forbidden")
    require(value in ROOT_FILES or
            (len(path.parts) > 1 and path.parts[0] in SOURCE_ROOTS),
            "not a source path")
    return path


def no_links(path):
    # Source directories are trusted local handoffs, not concurrently mutable
    # adversarial trees. Still reject all symlink components, including parents.
    for part in [path, *path.parents]:
        require(not part.is_symlink(), "symlink input forbidden")


def read_regular(path):
    no_links(path)
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                "input must be a non-hardlinked regular file")
        require(info.st_size <= MAX_FILE, "file exceeds size limit")
        data = stream.read(MAX_FILE + 1)
        require(len(data) <= MAX_FILE, "file exceeds size limit")
        return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def manifest(raw, allowed_files, allowed_dirs=()):
    data = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(data, dict) and set(data) == FIELDS, "manifest fields")
    require(type(data["schema"]) is int and data["schema"] == 1, "schema")
    require(data["base"] == BASE and data["cpa"] == CPA, "base/reference pin")
    require(data["owner_approved"] is True, "owner approval required")
    for key in ("checkpoint", "owner"):
        require(isinstance(data[key], str) and
                re.fullmatch(r"[A-Za-z0-9_-]{1,160}", data[key]), "identity")
    deps = data["dependencies"]
    require(isinstance(deps, list) and all(sha(d) for d in deps),
            "dependency hashes")
    require(len(deps) == len(set(deps)), "duplicate dependency")
    axes = data["axes"]
    require(isinstance(axes, dict) and set(axes) == AXES, "evidence axes")
    require(all(v in ("reviewed", "passed", "failed", "blocked", "not_run")
                for v in axes.values()), "evidence status")
    require(isinstance(data["limits"], list) and
            all(isinstance(v, str) and v for v in data["limits"]), "limits")
    tests = data["tests"]
    require(isinstance(tests, list) and tests, "test attestations required")
    for test in tests:
        require(isinstance(test, dict) and set(test) ==
                {"command", "exit_code", "scope", "log_sha256"}, "test fields")
        require(all(isinstance(test[k], str) and test[k]
                    for k in ("command", "scope")), "test description")
        require(type(test["exit_code"]) is int and
                sha(test["log_sha256"]), "test result/hash")
    files_granted = {source_path(p) for p in allowed_files}
    dirs_granted = {source_path(p) for p in allowed_dirs}
    require(files_granted or dirs_granted, "explicit ownership grants required")
    entries = data["files"]
    require(isinstance(entries, list) and 0 < len(entries) <= 1000,
            "source inventory required")
    files = {}
    for entry in entries:
        require(isinstance(entry, dict) and set(entry) == {"path", "sha256"},
                "file fields")
        path = source_path(entry["path"])
        require(path in files_granted or
                any(grant in path.parents for grant in dirs_granted),
                "file outside ownership grant")
        require(str(path) not in files and sha(entry["sha256"]),
                "duplicate file or invalid hash")
        files[str(path)] = entry["sha256"]
    return data, files


def inventory(root):
    no_links(root)
    require(root.is_dir(), "source directory required")
    found = set()

    def fail(error):
        raise error

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        for name in dirs:
            path = Path(directory) / name
            no_links(path)
            require(path.is_dir(), "invalid source directory")
            source_path(path.relative_to(root).as_posix() + "/placeholder")
        for name in files:
            path = Path(directory) / name
            no_links(path)
            found.add(path.relative_to(root).as_posix())
    return found


def verify(bundle, allowed_files, allowed_dirs=()):
    bundle = Path(os.path.abspath(bundle))
    no_links(bundle)
    require({p.name for p in bundle.iterdir()} == {"manifest.json", "source"},
            "bundle must contain only manifest.json and source")
    raw = read_regular(bundle / "manifest.json")
    data, files = manifest(raw, allowed_files, allowed_dirs)
    require(inventory(bundle / "source") == set(files), "inventory mismatch")
    payload = {}
    size = 0
    for path, expected in files.items():
        content = read_regular(bundle / "source" / path)
        require(digest(content) == expected, "source hash mismatch")
        size += len(content)
        require(size <= MAX_TOTAL, "checkpoint exceeds size limit")
        payload[path] = content
    # These exact verified bytes, not a second copy/read of mutable input, stage.
    return raw, data, payload


def stage(verified):
    raw, _, payload = verified
    no_links(OVERLAYS)
    OVERLAYS.mkdir(parents=True, exist_ok=True)
    destination = OVERLAYS / digest(raw)
    destination.mkdir()  # Never overwrite an earlier or partially staged input.
    for path, content in payload.items():
        target = destination / "source" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(content)
        target.chmod(0o444)
    # Manifest last: an interrupted stage is never a complete checkpoint.
    target = destination / "manifest.json"
    with target.open("xb") as output:
        output.write(raw)
    target.chmod(0o444)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify", "stage"))
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--allow-file", action="append", default=[])
    parser.add_argument("--allow-dir", action="append", default=[])
    args = parser.parse_args()
    try:
        checked = verify(args.bundle, args.allow_file, args.allow_dir)
        output = {"manifest_sha256": digest(checked[0]),
                  "files": len(checked[2]),
                  "owner": checked[1]["owner"],
                  "independently_tested": False,
                  "dependencies": checked[1]["dependencies"]}
        if args.command == "stage":
            output["staged"] = str(stage(checked).relative_to(ROOT))
        print(json.dumps(output, sort_keys=True))
    except (ValueError, OSError, TypeError, KeyError):
        # Do not reflect arbitrary manifest content or private filesystem paths.
        parser.exit(1, "checkpoint rejected; inspect source, manifest and grants\n")


if __name__ == "__main__":
    main()
