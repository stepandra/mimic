#!/usr/bin/env python3
"""Acquire pinned tools separately; run actual native clients only in containment."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / ".tools/native-clients"
LOCK = json.loads((HERE / "clients.lock.json").read_text())
SCHEMA = "mimic.native-clients/v1"
WORKFLOWS = ["sse", "tool", "continuation", "cancel"]


class Blocked(Exception):
    pass


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def docker_env():
    # No user ~/.docker auth/config, proxy, cloud credentials or inherited context.
    config = WORK / "docker-config"
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(config), "DOCKER_CONFIG": str(config)}


def docker(args, timeout=30):
    try:
        return subprocess.run(["docker", *args], env=docker_env(), stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Blocked("docker_unavailable_or_timeout") from error


def require_docker():
    if docker(["info", "--format", "{{.OSType}}"]).stdout.strip() != b"linux":
        raise Blocked("linux_docker_daemon_unavailable")


def download(pin, path):
    if not path.exists():
        # Fixed registry URL only; no package install scripts or dependency resolution.
        with tempfile.NamedTemporaryFile(dir=path.parent) as dest:
            deadline = time.monotonic() + 300
            with urllib.request.urlopen(pin["url"], timeout=30) as response:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > 512 * 1024 * 1024 or time.monotonic() > deadline:
                        raise Blocked("artifact_size_or_time_limit")
                    dest.write(chunk)
            dest.flush()
            verify_integrity(pin, Path(dest.name))
            shutil.copyfile(dest.name, path)
    verify_integrity(pin, path)


def verify_integrity(pin, path):
    algorithm, expected = pin["integrity"].split("-", 1)
    with path.open("rb") as source:
        actual = base64.b64encode(hashlib.file_digest(source, algorithm).digest()).decode()
    if actual != expected:
        raise Blocked("artifact_integrity_mismatch")


def extract_binary(archive, member, destination):
    with tarfile.open(archive, "r:gz") as package:
        entry = package.getmember(member)
        extract_regular_member(package, entry, destination)


def extract_regular_member(package, entry, destination):
    if not entry.isfile() or entry.size > 512 * 1024 * 1024:
        raise Blocked("artifact_member_not_regular")
    # Do not extract archive paths, links, modes, or install scripts.
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as target:
        temporary = Path(target.name)
        try:
            with package.extractfile(entry) as source:
                shutil.copyfileobj(source, target)
            target.flush()
            temporary.chmod(0o555)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)


def acquisition_fingerprint():
    files = ["Dockerfile", "clients.lock.json", "harness.py", "fixtures.py"]
    return {name: digest(HERE / name) for name in files}


def extract_codex_tree(archive, destination):
    """Preserve official resource layout; only regular, bounded archive members."""
    prefix = "package/vendor/x86_64-unknown-linux-musl/"
    with tarfile.open(archive, "r:gz") as package:
        total = 0
        for member in package.getmembers():
            if not member.name.startswith(prefix) or member.isdir():
                continue
            relative = Path(member.name.removeprefix(prefix))
            if relative.is_absolute() or ".." in relative.parts or not member.isfile():
                raise Blocked("unsafe_codex_archive_member")
            total += member.size
            if total > 512 * 1024 * 1024:
                raise Blocked("codex_extraction_limit")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.parent.chmod(0o755)
            extract_regular_member(package, member, target)


def acquire(artifacts_only=False):
    WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
    context = WORK / "context"
    context.mkdir(exist_ok=True, mode=0o700)
    artifacts = {}
    for name, pin in LOCK["clients"].items():
        path = WORK / f"{name}-{pin['version']}.tgz"
        download(pin, path)
        extract_binary(path, pin["member"], context / name)
        artifacts[name] = {"archive_sha256": digest(path),
                           "executable_sha256": digest(context / name)}
    (WORK / "artifacts.json").write_text(json.dumps(artifacts, indent=2) + "\n")
    if artifacts_only:
        return artifacts
    require_docker()
    # Fresh, minimal build context: no repository, user HOME, stale cache files,
    # credentials or caller-selected Dockerfile are sent to the daemon.
    with tempfile.TemporaryDirectory(prefix="image-context-", dir=WORK) as temporary:
        image_context = Path(temporary)
        for name in acquisition_fingerprint():
            shutil.copyfile(HERE / name, image_context / name)
        shutil.copyfile(context / "claude", image_context / "claude")
        extract_codex_tree(WORK / f"codex-{LOCK['clients']['codex']['version']}.tgz",
                           image_context / "codex-tree")
        image_file = WORK / "image-id"
        result = docker(["build", "--platform", "linux/amd64", "--iidfile", str(image_file),
                         str(image_context)], timeout=600)
        if result.returncode:
            raise Blocked("runtime_image_build_failed")
    receipt = {"image_id": image_file.read_text().strip(),
               "inputs": acquisition_fingerprint(), "artifacts": artifacts}
    (WORK / "acquisition.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def shipment_copy(source, destination):
    """Only compiled shipment artifacts cross the boundary; no repo/HOME mounts."""
    if any(destination.iterdir()):
        raise Blocked("shipment_staging_not_empty")
    source = source.resolve()
    if not (source / "entrypoint.sh").is_file():
        raise Blocked("shipment_missing")
    hashes = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise Blocked("shipment_symlink")
        if not path.is_file():
            continue
        relative = path.relative_to(source)
        # Compiled BEAMs carry debug/source metadata; never use a private app shipment.
        if not (str(relative) == "entrypoint.sh" or
                len(relative.parts) == 3 and relative.parts[1] == "ebin"
                and path.suffix in (".beam", ".app")):
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        target.chmod(0o444)
        directory = target.parent
        while directory != destination:
            directory.chmod(0o755)
            directory = directory.parent
        hashes[str(relative)] = digest(target)
    if "mimic/ebin/mimic.beam" not in hashes:
        raise Blocked("not_a_mimic_shipment")
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()


def container_args(name, image, shipment, client, workflow):
    return ["run", "--name", name, "--pull", "never", "--platform", "linux/amd64",
            "--network", "none", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "256",
            "--memory", "2g", "--cpus", "2", "--user", "10001:10001",
            "--ulimit", "core=0:0",
            "--tmpfs", "/work:rw,nosuid,nodev,size=128m,uid=10001,gid=10001,mode=700",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m,uid=10001,gid=10001,mode=700",
            "--mount", f"type=bind,src={shipment},dst=/shipment,readonly",
            image, "--client", client, "--workflow", workflow]


def offline(shipment, clients, workflows):
    report = {"schema": SCHEMA, "evidence_class": "native-client/local-upstream",
              "synthetic": True, "live": "not_run", "cpa_differential": "not_run",
              "source_base_revision": "3e00808ff0fefbb6728edb1769c17139ef0fd93a",
              "client_pins": {client: LOCK["clients"][client] for client in clients},
              "fixture_sha256": digest(HERE / "fixtures.py"), "results": [],
              "unimplemented": ["native_login", "device", "pkce", "refresh_restart",
                                "long_sse", "websocket"],
              "inventory_only": LOCK["inventory_only"]}
    try:
        require_docker()
        try:
            receipt = json.loads((WORK / "acquisition.json").read_text())
        except (OSError, ValueError) as error:
            raise Blocked("run_acquire_first") from error
        if receipt["inputs"] != acquisition_fingerprint():
            raise Blocked("acquisition_stale")
        image = receipt["image_id"]
        if not image.startswith("sha256:") or len(image) != 71:
            raise Blocked("immutable_image_id_required")
        if docker(["image", "inspect", image]).returncode:
            raise Blocked("acquired_image_missing")
        report["acquisition"] = receipt
        with tempfile.TemporaryDirectory(prefix="shipment-", dir=WORK) as temporary:
            report["shipment_sha256"] = shipment_copy(shipment, Path(temporary))
            # Readable by the unprivileged container UID, not writable.
            Path(temporary).chmod(0o755)
            for client in clients:
                for workflow in workflows:
                    name = "mimic-native-" + uuid.uuid4().hex
                    try:
                        result = docker(container_args(name, image, temporary, client, workflow),
                                        timeout=120)
                        try:
                            evidence = json.loads(result.stdout)
                            if evidence["status"] not in ["passed", "failed", "blocked"]:
                                raise ValueError()
                        except (ValueError, KeyError):
                            evidence = {"status": "failed", "reason": "invalid_container_report"}
                        if result.returncode and evidence["status"] == "passed":
                            evidence = {"status": "failed", "reason": "container_exit_mismatch"}
                        report["results"].append({
                            **evidence, "client": client, "workflow": workflow,
                            "pin": LOCK["clients"][client], "container_exit": result.returncode})
                    finally:
                        if docker(["rm", "--force", name]).returncode:
                            raise Blocked("container_cleanup_failed")
    except Blocked as error:
        report["blocked_reason"] = str(error)
        done = {(row["client"], row["workflow"]) for row in report["results"]}
        for client in clients:
            for workflow in workflows:
                if (client, workflow) not in done:
                    report["results"].append({"client": client, "workflow": workflow,
                                              "status": "blocked", "reason": str(error)})
    statuses = {row["status"] for row in report["results"]}
    report["status"] = ("blocked" if "blocked_reason" in report else
                        "failed" if "failed" in statuses else
                        "blocked" if "blocked" in statuses else "passed")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    acquisition = sub.add_parser("acquire")
    acquisition.add_argument("--artifacts-only", action="store_true")
    execution = sub.add_parser("offline")
    execution.add_argument("--shipment", type=Path, required=True)
    execution.add_argument("--client", choices=["claude", "codex", "all"], default="all")
    execution.add_argument("--workflow", choices=[*WORKFLOWS, "all"], default="sse")
    args = parser.parse_args()
    if args.command == "acquire":
        try:
            print(json.dumps(acquire(args.artifacts_only), indent=2))
            return 0
        except Blocked as error:
            print(json.dumps({"status": "blocked", "reason": str(error)}))
            return 2
    report = offline(args.shipment, list(LOCK["clients"]) if args.client == "all" else [args.client],
                     WORKFLOWS if args.workflow == "all" else [args.workflow])
    print(json.dumps(report, indent=2, sort_keys=True))
    return {"passed": 0, "failed": 1, "blocked": 2}[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
