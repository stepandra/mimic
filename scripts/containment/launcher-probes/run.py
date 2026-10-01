#!/usr/bin/env python3
"""Explicit isolated kernel test. Never pulls an image or mounts host data."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("launcher_report", Path(__file__).with_name("verify.py"))
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-image", required=True, help="already-local immutable sha256 image")
    parser.add_argument("--launcher", required=True, type=Path)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--negative-fixture", choices=("missing-qa", "runtime-alias"))
    args = parser.parse_args()
    digest = args.base_image.removeprefix("sha256:")
    if not args.base_image.startswith("sha256:") or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        parser.error("an immutable local image id is required")
    for path in (args.launcher, args.probe):
        if path.is_symlink() or not path.is_file():
            parser.error("regular artifact files required")
    name = "mimic-launcher-probe-" + uuid.uuid4().hex[:12]
    output = ROOT / "build/containment" / name
    output.mkdir(parents=True)
    image = container = staging = None
    result = {"scope": "synthetic_launcher_kernel_probe", "qualified_f02": False}

    def command(label, argv, timeout=30, allow_nonzero=False):
        completed = subprocess.run([args.docker, *argv], capture_output=True, timeout=timeout)
        (output / (label + ".stdout")).write_bytes(completed.stdout)
        (output / (label + ".stderr")).write_bytes(completed.stderr)
        if completed.returncode and not allow_nonzero:
            raise RuntimeError(label + " failed; see retained bounded run artifacts")
        return completed.stdout

    try:
        info = json.loads(command("base", ["image", "inspect", args.base_image]))[0]
        if info["Id"] != args.base_image or info["Os"] != "linux" or info["Config"].get("Volumes"):
            raise ValueError("Linux image without declared volumes required")
        artifact_check = ROOT / "scripts/containment/check_launcher.py"
        for path in (args.launcher, args.probe):
            checked = subprocess.run(["python3", str(artifact_check), str(path.resolve())], capture_output=True, timeout=5, check=True)
            expected = {"arm64": "aarch64", "amd64": "x86_64"}.get(info["Architecture"])
            if checked.stdout.decode().strip() != expected:
                raise ValueError("artifact/image architecture mismatch")
        context = output / "context"
        fs = context / "fs"
        for directory in ("usr/local/bin", "qa", "containment", "boundary", "etc", "work/home", "tmp"):
            (fs / directory).mkdir(parents=True, exist_ok=True)
        for target, source in (("containment/launch", args.launcher), ("usr/local/bin/launcher-probe", args.probe)):
            shutil.copyfile(source.resolve(), fs / target)
            (fs / target).chmod(0o555)
        for directory in ("containment", "boundary"):
            (fs / directory / "forbidden").write_text("synthetic\n")
        if args.negative_fixture == "missing-qa":
            (fs / "qa").rmdir()
        elif args.negative_fixture == "runtime-alias":
            # A trusted-image preflight negative, not a target-written path.
            (fs / "bin").symlink_to("/boundary", target_is_directory=True)
        (context / "Dockerfile").write_text(
            "FROM " + args.base_image + "\nCOPY fs/ /\nUSER 0:0\nWORKDIR /tmp\n"
            'ENTRYPOINT ["/usr/local/bin/launcher-probe", "suite"]\n')
        inputs = {str(path.relative_to(context)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in context.rglob("*") if path.is_file()}
        (output / "inputs.json").write_text(json.dumps(inputs, sort_keys=True, indent=2))
        # Stage into a NEVER-started private container, then snapshot locally.
        # BuildKit can resolve FROM sha256:... as a registry tag even with
        # --pull=false; create --pull=never with an image ID cannot do that.
        staging = command("stage-create", ["create", "--name", name + "-stage",
            "--pull", "never", "--network", "none", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--entrypoint", "/never-executed",
            args.base_image]).decode().strip()
        command("stage-copy", ["cp", str(fs) + "/.", staging + ":/"])
        image = command("stage-snapshot", ["commit",
            "--change", 'ENTRYPOINT ["/usr/local/bin/launcher-probe", "suite"]',
            "--change", "USER 0:0", "--change", "WORKDIR /tmp", staging], 60).decode().strip()
        command("stage-remove", ["rm", staging])
        staging = None
        container = command("create", [
            "create", "--name", name, "--pull", "never", "--network", "none", "--read-only",
            "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID",
            "--security-opt", "no-new-privileges", "--user", "0:0", "--pids-limit", "64",
            "--memory", "256m", "--memory-swap", "256m", "--cpus", "2",
            "--ulimit", "core=0:0", "--ulimit", "nofile=1024:1024", "--ipc", "private",
            "--cgroupns", "private", "--restart", "no", "--no-healthcheck", "--stop-timeout", "1",
            "--tmpfs", "/work:rw,nosuid,nodev,size=16m,uid=10001,gid=10001,mode=700",
            "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777", image,
        ]).decode().strip()
        # docker start may return zero despite a nonzero target exit: inspect both.
        transcript = command("suite", ["start", "-a", container], 45, allow_nonzero=True)
        state = json.loads(command("state", ["inspect", "--format", "{{json .State}}", container]))
        if len(transcript) > 16384:
            raise RuntimeError("oversized launcher probe report")
        result.update(image=image, base_image=args.base_image, architecture=info["Architecture"],
                      kernel=command("kernel", ["info", "--format", "{{.KernelVersion}}"]).decode().strip(),
                      exit_code=state["ExitCode"], running=state["Running"],
                      probe_passed=not state["Running"] and REPORT.verify(transcript.decode(), state["ExitCode"]),
                      transcript_sha256=hashlib.sha256(transcript).hexdigest())
        if args.negative_fixture:
            lines = transcript.decode().splitlines()
            expected = [
                {"fixture_ready": True, "listening_39001": True, "listening_39002": True},
                {"check_exact": False},
            ]
            result["negative_fixture"] = args.negative_fixture
            result["refusal_passed"] = (not state["Running"] and state["ExitCode"] != 0
                                        and [json.loads(line) for line in lines] == expected)
            if not result["refusal_passed"]:
                raise RuntimeError("negative fixture did not fail before target execution")
        elif not result["probe_passed"]:
            raise RuntimeError("kernel probe did not pass; see suite.stdout")
    finally:
        try:
            if container:
                command("remove-container", ["rm", "-f", container])
                if command("absence", ["container", "ls", "-aq", "--filter", "name=^/" + name + "$"]).strip():
                    raise RuntimeError("owned container cleanup not confirmed")
                result["container_removed"] = True
            if staging:
                command("remove-staging", ["rm", "-f", staging])
            if image:
                command("remove-image", ["image", "rm", image])
                result["fixture_image_removed"] = True
        finally:
            (output / "result.json").write_text(json.dumps(result, indent=2, sort_keys=True))
            print(json.dumps({"artifacts": str(output.relative_to(ROOT)), **result}, sort_keys=True))


if __name__ == "__main__":
    main()
