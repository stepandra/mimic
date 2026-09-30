"""Approved complete-source candidates; acquisition and offline export are separate.

The expected manifest-byte digest is supplied by the integration owner. No Git
checkout identity, dirty-tree inference, overlay, or self-approved flag is used.
"""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import resource
import shutil
import socket
import stat
import subprocess
import tarfile
import tempfile

import reference_build as build
import reference_sandbox as sandbox

BASE = "3e00808ff0fefbb6728edb1769c17139ef0fd93a"
SCHEMA = "mimic.parity-candidate/v1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
MAX_FILE = 16 * 1024 * 1024
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
FORBIDDEN = {".git", ".jj", ".env", ".ssh", ".aws", ".azure", ".gnupg",
             "build", "_build", ".cache", "__pycache__", "node_modules",
             ".mimic", ".tools", "target", ".DS_Store", ".netrc", ".npmrc",
             ".gitconfig", ".config"}
# Seatbelt restricts files/network, not setsid/setpgid or an OS process lifetime
# namespace. Killing an original PGID does not bound detached descendants.
# No supported backend currently supplies that missing guarantee.
DESCENDANT_CONTAINMENT_BLOCKER = "candidate_descendant_containment_unavailable"


def require_descendant_containment():
    if DESCENDANT_CONTAINMENT_BLOCKER:
        raise RuntimeError(DESCENDANT_CONTAINMENT_BLOCKER)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate manifest key")
        result[key] = value
    return result


def read_regular(path, bound):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("regular input file required")
        data = stream.read(bound + 1)
    if len(data) > bound:
        raise ValueError("input exceeds size bound")
    return data


def relative_name(name):
    if not isinstance(name, str) or not name or "\\" in name or "\x00" in name:
        raise ValueError("invalid source path")
    path = PurePosixPath(name)
    if (not path.parts or path.is_absolute() or name != path.as_posix()
            or any(part in ("..", ".", *FORBIDDEN) for part in path.parts)
            or any(part.startswith(".env.") for part in path.parts)
            or ":" in name or any(ord(c) < 32 for c in name)
            or path.suffix in (".beam", ".pyc", ".o", ".so", ".dylib")):
        raise ValueError("non-source or unsafe archive path")
    return path


def read_manifest(path, expected):
    if not isinstance(expected, str) or not HEX.fullmatch(expected):
        raise ValueError("explicit lowercase expected manifest SHA256 required")
    path = Path(path)
    raw = read_regular(path, 4 * 1024 * 1024)
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("candidate manifest approval digest mismatch")
    value = json.loads(raw, object_pairs_hook=unique_object)
    if (set(value) != {"schema", "base_revision", "source_archive_sha256", "files"}
            or value["schema"] != SCHEMA or value["base_revision"] != BASE
            or not isinstance(value["source_archive_sha256"], str)
            or not HEX.fullmatch(value["source_archive_sha256"])
            or not isinstance(value["files"], dict)
            or not 1 <= len(value["files"]) <= 20000):
        raise ValueError("unsupported candidate manifest")
    for name, digest in value["files"].items():
        relative_name(name)
        if not isinstance(digest, str) or not HEX.fullmatch(digest):
            raise ValueError("invalid source file hash")
    if not {"gleam.toml", "manifest.toml", "src/mimic.gleam"} <= value["files"].keys():
        raise ValueError("complete MIMIC source inventory required")
    return raw, value


def extract_source(archive_path, directory, manifest):
    # A pinned fd can still be modified in place. Hash and parse the same bounded
    # immutable byte snapshot, never re-read a mutable input after approval.
    raw = read_regular(archive_path, MAX_ARCHIVE)
    if hashlib.sha256(raw).hexdigest() != manifest["source_archive_sha256"]:
        raise ValueError("source archive digest mismatch")
    with io.BytesIO(raw) as stream:
        with tarfile.open(fileobj=stream, mode="r:*") as archive:
            seen, files, total = set(), {}, 0
            for member in archive:
                name = member.name.rstrip("/") if member.isdir() else member.name
                path = relative_name(name)
                if name in seen or not (member.isdir() or member.isreg()):
                    raise ValueError("duplicate/link/special source member")
                seen.add(name)
                if len(seen) > 30000:
                    raise ValueError("too many source archive members")
                destination = directory.joinpath(*path.parts)
                if member.isdir():
                    if not any(p.startswith(name + "/") for p in manifest["files"]):
                        raise ValueError("unlisted source directory")
                    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
                    continue
                total += member.size
                if not 0 <= member.size <= MAX_FILE or total > MAX_TOTAL:
                    raise ValueError("source archive exceeds size bound")
                if name not in manifest["files"]:
                    raise ValueError("extra source file")
                data = archive.extractfile(member).read(MAX_FILE + 1)
                if hashlib.sha256(data).hexdigest() != manifest["files"][name]:
                    raise ValueError("source file hash mismatch")
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with destination.open("xb") as out:
                    out.write(data)
                destination.chmod(0o600)
                files[name] = manifest["files"][name]
            if files != manifest["files"]:
                raise ValueError("incomplete source archive")
    verify_source(directory, manifest)


def verify_source(directory, manifest):
    if directory.is_symlink():
        raise ValueError("source root is a link")
    actual = {}
    for parent, dirs, files in os.walk(directory, followlinks=False):
        relative = Path(parent).relative_to(directory)
        if relative == Path(".") and "build" in dirs:
            if (directory / "build").is_symlink():
                raise ValueError("generated build directory is a link")
            dirs.remove("build")  # Only generated root build output is excluded.
        for name in dirs + files:
            path = Path(parent) / name
            if path.is_symlink():
                raise ValueError("source link appeared during build")
            if name in files:
                if not path.is_file():
                    raise ValueError("source special file appeared during build")
                actual[str(path.relative_to(directory))] = build.digest(path)
    if actual != manifest["files"]:
        raise ValueError("candidate source changed during export")


def toolchain():
    # Locate installed files without invoking a tool manager or inheriting its
    # network/config side effects. Version verification happens in Seatbelt.
    data = Path(os.environ.get("MISE_DATA_DIR") or
                str(Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "mise"))
    gleam = (data / "installs/gleam/1.18.1/gleam").resolve(strict=True)
    tools = {"gleam": gleam}
    for name in ("erl", "escript", "rebar3"):
        path = shutil.which(name)
        if not path:
            raise RuntimeError("installed OTP/rebar3 prerequisite missing")
        tools[name] = Path(path).resolve(strict=True)
    return tools


def offline_environment(attempt, tools):
    home = attempt / "home"
    home.mkdir(mode=0o700)
    temp = attempt / "tmp"
    temp.mkdir(mode=0o700)
    return {
        "PATH": ":".join(dict.fromkeys([str(p.parent) for p in tools.values()]
                                       + ["/usr/bin", "/bin", "/opt/homebrew/bin"])),
        "HOME": str(home), "TMPDIR": str(temp),
        "XDG_CONFIG_HOME": str(home), "XDG_CACHE_HOME": str(home / "cache"),
        "HEX_HOME": str(home / "hex"), "REBAR_CACHE_DIR": str(home / "rebar"),
        "REBAR_GLOBAL_CONFIG_DIR": str(home / "rebar-config"),
        "ERL_FLAGS": "+S 2:2", "LANG": "C", "TZ": "UTC", "TERM": "dumb",
    }


def offline_policy(attempt, tools):
    # Reuse the reviewed filesystem boundary, without ANY network exception.
    attempt = Path(attempt).resolve()
    lines = sandbox.policy(attempt, 1, 2).splitlines()
    lines = [line for line in lines if not line.startswith(("(allow network-", "(allow file-write*"))]
    lines.append('(allow file-write* (literal "/dev/null"))')
    # Everything in the attempt is read-only except these generated locations.
    # In particular source inputs and parent-owned final artifacts cannot be
    # replaced/precreated by build scripts.
    for name in ("source/build", "home", "tmp"):
        lines.append("(allow file-write* (subpath " + json.dumps(str(attempt / name)) + "))")
    lines.append("(allow file-write* (literal " + json.dumps(str(attempt / "export.log")) + "))")
    for tool in tools.values():
        lines.append("(allow file-read* (literal " + json.dumps(str(tool)) + "))")
        lines.append("(allow file-read-metadata " + " ".join(
            "(literal " + json.dumps(str(p)) + ")" for p in tool.parents) + ")")
    return "\n".join(lines) + "\n"


def offline_probe(attempt, env, boundary):
    def run(argv):
        return subprocess.run(sandbox.argv(boundary, argv), env=env, cwd=attempt,
                              capture_output=True, timeout=5)
    sentinel = attempt / "build-probe"
    sentinel.write_text("synthetic")
    yes = run(["/bin/cat", str(sentinel)])
    no = run(["/bin/cat", str(build.ROOT / "AGENTS.md")])
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(0.1)
        blocked = run(["/usr/bin/curl", "--noproxy", "*", "--max-time", "1",
                       f"http://127.0.0.1:{server.getsockname()[1]}/"])
        try:
            connection, _ = server.accept()
            connection.close()
            connected = True
        except TimeoutError:
            connected = False
    checks = {"staged_read": yes.returncode == 0 and yes.stdout == b"synthetic",
              "repo_read_denied": no.returncode != 0 and not no.stdout,
              "network_denied": blocked.returncode != 0 and not connected}
    (attempt / "build-containment.json").write_text(json.dumps(checks, indent=2))
    if not all(checks.values()):
        raise RuntimeError("offline export containment probe failed")


def export(attempt, source):
    require_descendant_containment()
    if platform.system() != "Darwin":
        raise RuntimeError("candidate offline export needs reviewed macOS containment")
    tools = toolchain()
    env = offline_environment(attempt, tools)
    boundary = sandbox.LaunchPolicy(attempt, offline_policy(attempt, tools))
    sandbox.record_policy(boundary)
    offline_probe(attempt, env, boundary)
    version = subprocess.check_output(
        sandbox.argv(boundary, [str(tools["gleam"]), "--version"]),
        cwd=source, env=env, timeout=5).decode().strip()
    if version != "gleam 1.18.1":
        raise ValueError("unexpected candidate compiler version")
    command = sandbox.argv(boundary, [str(tools["gleam"]), "export", "erlang-shipment"])
    def limits():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_CPU, (180, 180))
        resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024 * 1024, 64 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (1024, 1024))
    with (attempt / "export.log").open("wb") as log:
        child = subprocess.Popen(command, cwd=source, env=env, stdout=log, stderr=log,
                                 stdin=subprocess.DEVNULL, start_new_session=True,
                                 preexec_fn=limits)
        try:
            if child.wait(timeout=180) != 0:
                raise RuntimeError("candidate offline export failed; inspect export.log")
        finally:
            sandbox.stop(child)
    return {"argv": command, "environment": env, "launch_policy_sha256": boundary.sha256,
            "tools": {name: {"path": str(path), "sha256": build.digest(path)}
                      for name, path in tools.items()}, "erl": str(tools["erl"])}


def prepare(manifest_path, expected, archive_path, acquire=False):
    import candidate_dependencies as dependencies
    raw, manifest = read_manifest(manifest_path, expected)
    root = build.BUILD / "candidates" / expected
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    attempt = Path(tempfile.mkdtemp(prefix="acquire-" if acquire else "prepare-", dir=root))
    (attempt / "candidate.json").write_bytes(raw)
    source = attempt / "source"
    source.mkdir(mode=0o700)
    phase = "source"
    try:
        extract_source(archive_path, source, manifest)
        phase = "dependency-closure"
        closure = dependencies.derive(source)
        if acquire:
            phase = "dependency-acquisition"
            dependencies.acquire(source, root / "dependencies")
            verify_source(source, manifest)
            (attempt / "acquisition.json").write_text(json.dumps({
                "schema": "mimic.candidate-acquisition/v1",
                "candidate_manifest_sha256": expected, "dependency_closure": closure,
            }, indent=2) + "\n")
            return attempt / "acquisition.json"
        phase = "offline-dependency-staging"
        dependencies.stage(source, root / "dependencies")
        verify_source(source, manifest)
        phase = "offline-export"
        try:
            provenance = export(attempt, source)
        finally:
            # Source mutations fail even if the compiler itself failed.
            verify_source(source, manifest)
        phase = "artifact-staging"
        targets = attempt / "targets"
        targets.mkdir(mode=0o700)
        shipment = source / "build/erlang-shipment"
        if shipment.is_symlink():
            raise ValueError("linked shipment root")
        for artifact in shipment.rglob("*"):
            if artifact.is_symlink():
                raise ValueError("linked shipment artifact")
            relative = artifact.relative_to(shipment)
            if not artifact.is_file():
                continue
            # Copy compiled code and exported runtime assets, never sources,
            # caches or the checkout. Resource bytes are covered by provenance.
            if not (len(relative.parts) >= 3 and (
                    relative.parts[1] == "priv"
                    or (relative.parts[1] == "ebin" and artifact.suffix in (".beam", ".app")))):
                continue
            destination = targets / "mimic" / relative
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(artifact, destination)
        if not (targets / "mimic/mimic/ebin/mimic.beam").is_file():
            raise ValueError("candidate shipment lacks actual MIMIC entrypoint")
        provenance.update({
            "schema": "mimic.candidate-build/v1", "base_revision": BASE,
            "candidate_manifest_sha256": expected,
            "source_archive_sha256": manifest["source_archive_sha256"],
            "dependency_closure": closure, "source_inventory_verified_before_after": True,
        })
        build_path = attempt / "candidate-build.json"
        with build_path.open("x") as output:
            output.write(json.dumps(provenance, indent=2) + "\n")
        target_manifest = {
            "schema": "mimic.reference-targets/v2", "base_revision": BASE,
            "candidate_manifest_sha256": expected, "cpa_revision": build.REVISION,
            "mimic_revision": "candidate-sha256:" + expected, "erl": provenance["erl"],
            "candidate_build_sha256": build.digest(build_path),
            "files": {str(p.relative_to(targets)): build.digest(p)
                      for p in sorted(targets.rglob("*")) if p.is_file()},
        }
        with (attempt / "targets.json").open("x") as output:
            output.write(json.dumps(target_manifest, indent=2) + "\n")
        return attempt / "targets.json"
    except BaseException as error:
        failure = json.dumps({
            "schema": "mimic.candidate-failure/v1", "phase": phase,
            "candidate_manifest_sha256": expected, "error_type": type(error).__name__,
            "message": str(error), "artifacts": str(attempt),
        }, indent=2) + "\n"
        # No compiler-created symlink may redirect a parent-side write.
        try:
            with (attempt / "failure.json").open("x") as output:
                output.write(failure)
        except FileExistsError:
            with tempfile.NamedTemporaryFile(mode="w", prefix="failure-", suffix=".json",
                                             dir=attempt, delete=False) as output:
                output.write(failure)
        raise RuntimeError("candidate preparation failed; retained artifacts: " + str(attempt)) from error


def validate_targets(path, manifest):
    attempt = Path(path).resolve().parent
    expected = manifest["candidate_manifest_sha256"]
    _, approved = read_manifest(attempt / "candidate.json", expected)
    provenance_path = attempt / "candidate-build.json"
    if build.digest(provenance_path) != manifest["candidate_build_sha256"]:
        raise ValueError("candidate build provenance mismatch")
    provenance = json.loads(provenance_path.read_text())
    if (provenance["schema"] != "mimic.candidate-build/v1"
            or manifest["base_revision"] != BASE
            or manifest["cpa_revision"] != build.REVISION
            or manifest["mimic_revision"] != "candidate-sha256:" + expected
            or provenance["base_revision"] != BASE
            or provenance["candidate_manifest_sha256"] != expected
            or provenance["source_archive_sha256"] != approved["source_archive_sha256"]
            or provenance["source_inventory_verified_before_after"] is not True
            or provenance["erl"] != manifest["erl"]):
        raise ValueError("candidate identity mismatch")
    targets = attempt / "targets"
    if targets.is_symlink() or any(p.is_symlink() for p in targets.rglob("*")):
        raise ValueError("linked candidate artifact")
    actual = {str(p.relative_to(targets)): build.digest(p)
              for p in sorted(targets.rglob("*")) if p.is_file()}
    if actual != manifest["files"] or "mimic/mimic/ebin/mimic.beam" not in actual:
        raise ValueError("partial/stale candidate shipment")
    return targets
