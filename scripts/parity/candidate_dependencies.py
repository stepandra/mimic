"""Pinned Hex dependencies for a verified, build-cache-free Gleam candidate.

`acquire` is the ONLY network phase. `stage` never resolves versions or reads
Gleam's global package cache. The caller must sandbox the subsequent Gleam
command without network access: Gleam 1.18.1 has no build/export --offline flag.
"""

import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile
import tempfile
import time
import tomllib
import urllib.request


NAME = re.compile(r"[a-z][a-z0-9_]*\Z")
VERSION = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)\Z")
CHECKSUM = re.compile(r"[0-9A-Fa-f]{64}\Z")
MAX_ARCHIVE = 32 * 1024 * 1024
MAX_CACHED_TOTAL = 256 * 1024 * 1024
MAX_FILE = 32 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
MAX_ENTRIES = 10_000


def _read_toml(path):
    if path.is_symlink():
        raise ValueError(f"symlinked metadata: {path}")
    with path.open("rb") as stream:
        return tomllib.load(stream)


def _name(name):
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ValueError(f"invalid package name: {name!r}")
    return name


def _version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError(f"unsupported package version: {value!r}")
    return tuple(int(n) for n in VERSION.fullmatch(value).groups())


def _satisfies(version, constraint):
    """The comparison, pessimistic, conjunction and disjunction Hex range subset."""
    if not isinstance(constraint, str):
        raise ValueError(f"unsupported dependency requirement: {constraint!r}")
    actual = _version(version)
    alternatives = []
    for branch in constraint.split(" or "):
        clauses = []
        for clause in branch.split(" and "):
            match = re.fullmatch(
                r"\s*(>=|<=|>|<|==|=|~>)\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*", clause
            )
            if not match:
                raise ValueError(f"unsupported dependency constraint: {constraint!r}")
            op, bound = match.groups()
            numbers = [int(n) for n in bound.split(".")]
            expected = tuple((numbers + [0])[:3])
            if op == "~>":
                upper = (numbers[0] + 1, 0, 0) if len(numbers) == 2 else (
                    numbers[0], numbers[1] + 1, 0
                )
                clauses.append(expected <= actual < upper)
            else:
                clauses.append({
                    ">=": actual >= expected, "<=": actual <= expected,
                    ">": actual > expected, "<": actual < expected,
                    "==": actual == expected, "=": actual == expected,
                }[op])
        alternatives.append(all(clauses))
    return any(alternatives)


def _within(root, base, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError(f"invalid local path: {relative!r}")
    path = base / relative
    if any(part.is_symlink() for part in (path, *path.parents) if part != root.parent):
        raise ValueError(f"symlinked local path: {relative}")
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root) or not resolved.is_dir():
        raise ValueError(f"local dependency outside candidate: {relative}")
    return resolved


def _dependencies(config, *, dev):
    result = {}
    for key in ("dependencies", "dev-dependencies") if dev else ("dependencies",):
        table = config.get(key, {})
        if not isinstance(table, dict):
            raise ValueError(f"invalid {key} table")
        for name, requirement in table.items():
            _name(name)
            if name in result:
                raise ValueError(f"duplicate dependency: {name}")
            if isinstance(requirement, str):
                result[name] = {"version": requirement}
            elif isinstance(requirement, dict) and set(requirement) == {"path"}:
                result[name] = requirement
            else:
                raise ValueError(f"unsupported dependency source: {name}")
    return result


def derive(source: Path) -> list[dict]:
    """Validate the complete root lock and local runtime path-dependency closure.

    Root development requirements are included. Dependency packages' own
    development requirements are intentionally excluded, like Gleam's resolver.
    """
    root = Path(source).resolve(strict=True)
    config = _read_toml(root / "gleam.toml")
    manifest = _read_toml(root / "manifest.toml")
    root_name = _name(config.get("name"))
    packages = manifest.get("packages")
    if not isinstance(packages, list) or len(packages) > 256:
        raise ValueError("missing locked packages")
    by_name = {}
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("invalid locked package")
        name = _name(package.get("name"))
        _version(package.get("version"))
        if name == root_name or name in by_name:
            raise ValueError(f"duplicate or root package in lock: {name}")
        requirements = package.get("requirements")
        if not isinstance(requirements, list) or any(
            not isinstance(item, str) or not NAME.fullmatch(item) for item in requirements
        ) or len(requirements) != len(set(requirements)):
            raise ValueError(f"invalid locked requirements: {name}")
        if package.get("source") == "hex":
            if not isinstance(package.get("outer_checksum"), str) or not CHECKSUM.fullmatch(
                package["outer_checksum"]
            ):
                raise ValueError(f"missing Hex checksum: {name}")
            source_fields = {"outer_checksum"}
        elif package.get("source") == "local":
            if not isinstance(package.get("path"), str):
                raise ValueError(f"invalid local lock: {name}")
            source_fields = {"path"}
        else:
            raise ValueError(f"unsupported locked source: {name}")
        if set(package) - (
            {"name", "version", "source", "requirements", "build_tools", "otp_app"} | source_fields
        ):
            raise ValueError(f"conflicting or unknown locked metadata: {name}")
        by_name[name] = package
    if not by_name:
        raise ValueError("empty dependency lock")
    for package in packages:
        if any(name not in by_name for name in package["requirements"]):
            raise ValueError(f"unlocked transitive dependency: {package['name']}")

    direct = _dependencies(config, dev=True)
    locked_direct = manifest.get("requirements")
    if not isinstance(locked_direct, dict) or locked_direct != direct:
        raise ValueError("root requirements differ from manifest")
    local_paths = {}
    visiting = set()

    def visit(name, requirement, base):
        if name not in by_name:
            raise ValueError(f"unlocked dependency: {name}")
        package = by_name[name]
        if "path" in requirement:
            if package["source"] != "local":
                raise ValueError(f"local dependency locked as non-local: {name}")
            path = _within(root, base, requirement["path"])
            lock_path = _within(root, root, package["path"])
            if path != lock_path:
                raise ValueError(f"local path differs from lock: {name}")
            previous = local_paths.get(name)
            if previous is not None:
                if previous != path:
                    raise ValueError(f"conflicting local path: {name}")
                return
            if name in visiting:
                raise ValueError(f"local dependency cycle: {name}")
            visiting.add(name)
            local = _read_toml(path / "gleam.toml")
            if _name(local.get("name")) != name or local.get("version") != package["version"]:
                raise ValueError(f"local package identity differs from lock: {name}")
            children = _dependencies(local, dev=False)
            if set(children) != set(package["requirements"]):
                raise ValueError(f"local requirements differ from lock: {name}")
            for child, spec in children.items():
                visit(child, spec, path)
            visiting.remove(name)
            local_paths[name] = path
        else:
            if package["source"] != "hex" or not _satisfies(
                package["version"], requirement["version"]
            ):
                raise ValueError(f"locked version/source differs from requirement: {name}")

    for name, requirement in direct.items():
        visit(name, requirement, root)
    if {name for name, package in by_name.items() if package["source"] == "local"} != set(local_paths):
        raise ValueError("unverified local package in manifest")
    reachable = set()

    def reach(name):
        if name in reachable:
            return
        reachable.add(name)
        for child in by_name[name]["requirements"]:
            reach(child)

    for name in direct:
        reach(name)
    if reachable != set(by_name):
        raise ValueError("orphaned packages in manifest")
    return [dict(package) for package in packages]


def _archive_path(cache, package):
    return cache / (package["outer_checksum"].lower() + ".tar")


def _verified_archive(path, package):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_ARCHIVE:
        raise ValueError(f"missing or unsafe cached archive: {package['name']}")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("regular dependency archive required")
        data = stream.read(MAX_ARCHIVE + 1)
    if len(data) > MAX_ARCHIVE:
        raise ValueError("dependency archive exceeds bound")
    if hashlib.sha256(data).hexdigest() != package["outer_checksum"].lower():
        raise ValueError(f"cached archive checksum mismatch: {package['name']}")
    return data


def _check_cache(cache, packages):
    if not cache.exists():
        return
    if not cache.is_dir() or cache.is_symlink():
        raise ValueError("candidate cache is not a directory")
    expected = {_archive_path(cache, package).name for package in packages if package["source"] == "hex"}
    if any(entry.name not in expected or not entry.is_file() or entry.is_symlink()
           for entry in cache.iterdir()):
        raise ValueError("candidate cache contains non-locked artifacts")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise ValueError("unexpected Hex archive redirect")


def acquire(source: Path, cache: Path) -> None:
    """Explicitly download only pinned public repo.hex.pm tarballs into `cache`."""
    packages = [p for p in derive(source) if p["source"] == "hex"]
    cache = Path(cache)
    if cache.is_symlink() or cache.resolve().is_relative_to(Path(source).resolve()):
        raise ValueError("cache must be outside the candidate source")
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    _check_cache(cache, packages)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    overall_deadline = time.monotonic() + 600
    for package in packages:
        if time.monotonic() > overall_deadline:
            raise ValueError("dependency acquisition deadline")
        target = _archive_path(cache, package)
        if target.exists() or target.is_symlink():
            _verified_archive(target, package)
            continue
        url = f"https://repo.hex.pm/tarballs/{package['name']}-{package['version']}.tar"
        request = urllib.request.Request(url, headers={"User-Agent": "mimic-candidate-dependencies"})
        fd, temporary = tempfile.mkstemp(dir=cache, prefix=".download-")
        try:
            count, deadline = 0, min(overall_deadline, time.monotonic() + 120)
            with os.fdopen(fd, "wb") as out, opener.open(request, timeout=30) as response:
                while chunk := response.read(65536):
                    count += len(chunk)
                    if count > MAX_ARCHIVE or time.monotonic() > deadline:
                        raise ValueError(f"Hex archive exceeds bound: {package['name']}")
                    out.write(chunk)
            _verified_archive(Path(temporary), package)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def _extract(tar, destination, *, allowed=None):
    seen, files, directories, total = set(), set(), set(), 0
    for count, member in enumerate(tar, 1):
        if count > MAX_ENTRIES:
            raise ValueError("too many Hex archive entries")
        raw = member.name
        parts = raw.rstrip("/").split("/")
        if (not raw or raw.startswith("/") or "\\" in raw or
                any(part in ("", ".", "..") for part in parts)):
            raise ValueError(f"unsafe Hex archive path: {raw!r}")
        path = PurePosixPath(raw)
        if allowed is not None and path.as_posix() not in allowed:
            raise ValueError(f"unexpected Hex outer entry: {raw}")
        is_file = member.type in (tarfile.REGTYPE, tarfile.AREGTYPE)
        is_directory = member.type == tarfile.DIRTYPE
        if path in seen or not (is_file or is_directory):
            raise ValueError(f"duplicate or special Hex archive entry: {raw}")
        if allowed is not None and not is_file:
            raise ValueError(f"non-file Hex outer entry: {raw}")
        if any(parent in files for parent in path.parents):
            raise ValueError(f"Hex archive file used as directory: {raw}")
        if is_file and (path in directories or member.size < 0):
            raise ValueError(f"Hex archive directory replaced by file: {raw}")
        seen.add(path)
        directories.update(path.parents)
        if is_file:
            files.add(path)
            total += member.size
            if member.size > MAX_FILE or total > MAX_EXPANDED:
                raise ValueError("Hex archive expands beyond bound")
            if destination is not None:
                output = destination.joinpath(*parts)
                output.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as inp, output.open("xb") as out:
                    shutil.copyfileobj(inp, out)
        elif destination is not None:
            directories.add(path)
            destination.joinpath(*parts).mkdir(parents=True, exist_ok=True)
    return seen


def _unpack(archive_bytes, package, destination, locked):
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as outer:
        names = _extract(outer, None, allowed={"VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"})
        if names != {PurePosixPath(n) for n in ("VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz")}:
            raise ValueError(f"incomplete Hex outer archive: {package['name']}")
        member = outer.getmember("contents.tar.gz")
        contents = outer.extractfile(member)
        if contents is None or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or member.size > MAX_ARCHIVE:
            raise ValueError("missing Hex contents")
        data = contents.read(MAX_ARCHIVE + 1)
        if len(data) > MAX_ARCHIVE:
            raise ValueError("Hex contents exceeds bound")
    destination.mkdir(mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as inner:
        _extract(inner, destination)
    gleam = destination / "gleam.toml"
    if gleam.exists():
        config = _read_toml(gleam)
        if config.get("name") != package["name"] or config.get("version") != package["version"]:
            raise ValueError(f"Hex package identity differs from lock: {package['name']}")
        children = _dependencies(config, dev=False)
        if set(children) != set(package["requirements"]) or any(
            "version" not in requirement or name not in locked or
            not _satisfies(locked[name]["version"], requirement["version"])
            for name, requirement in children.items()
        ):
            raise ValueError(f"Hex package requirements differ from lock: {package['name']}")


def stage(source: Path, cache: Path) -> None:
    """Verify every archive, then atomically create build/packages and packages.toml.

    Requires a fresh candidate with no `build` directory; never copies a host
    package cache and never downloads missing archives.
    """
    packages = derive(source)
    source, cache = Path(source).resolve(strict=True), Path(cache)
    if cache.is_symlink() or cache.resolve().is_relative_to(source):
        raise ValueError("cache must be outside the candidate source")
    _check_cache(cache, packages)
    if (source / "build").exists() or (source / "build").is_symlink():
        raise ValueError("candidate build directory must be absent")
    archives, total = {}, 0
    for package in packages:
        if package["source"] == "hex":
            data = _verified_archive(_archive_path(cache, package), package)
            total += len(data)
            if total > MAX_CACHED_TOTAL:
                raise ValueError("dependency archives exceed total bound")
            archives[package["name"]] = data
    temporary = Path(tempfile.mkdtemp(prefix=".candidate-build-", dir=source))
    try:
        directory = temporary / "packages"
        directory.mkdir()
        locked = {package["name"]: package for package in packages}
        for package in packages:
            if package["source"] == "hex":
                _unpack(archives[package["name"]], package, directory / package["name"], locked)
        # ProjectPaths::build_packages_toml is build/packages/packages.toml.
        # LocalPackages::from_manifest indexes even the local packages.
        (directory / "packages.toml").write_text(
            "[packages]\n" + "".join(
                f'{p["name"]} = "{p["version"]}"\n' for p in sorted(packages, key=lambda p: p["name"])
            ), encoding="utf-8"
        )
        # Gleam 1.18.1 considers a missing direct path-dependency fingerprint
        # "changed" and runs version resolution (which may query Hex). It skips
        # comparison when the fingerprint mtime is >= the config mtime. Match
        # that exact mtime, never a future one: any later metadata edit forces
        # resolution and must fail inside the caller's no-network sandbox.
        # A sentinel differs from a real xxh3 hash on the slow path, deliberately
        # failing closed rather than treating a modified config as unchanged.
        for name, requirement in _dependencies(
            _read_toml(source / "gleam.toml"), dev=True
        ).items():
            if "path" not in requirement:
                continue
            config = _within(source, source, requirement["path"]) / "gleam.toml"
            fingerprint = directory / f"{name}.config_fingerprint"
            fingerprint.write_text("invalid", encoding="ascii")
            modified = config.stat().st_mtime_ns
            os.utime(fingerprint, ns=(modified, modified))
        os.replace(temporary, source / "build")
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
