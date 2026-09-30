"""Real CPA / assembled MIMIC gateway driver for unchanged buffered fixtures.

Not a mock target. Unsupported combinations stay blocked. Preparation stages
only executable artifacts; runtime children cannot read source/home/cache.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from urllib.parse import urlsplit

import local_driver
import candidate
import reference_build as build
import reference_sandbox as sandbox

ROOT = build.ROOT
BASE = "3e00808ff0fefbb6728edb1769c17139ef0fd93a"
STAGE = ROOT / "build/parity-reference/targets"
SUPPORTED = {
    "claude-messages": ("messages-v1", "messages"),
    "claude-chat": ("chat-v1", "chat_completions"),
}
# Measured during the first contained launch, then confirmed at main.go:826.
# Do not remove merely because outbound requests fail. The current requirement
# says background updates must be disabled, not simply network-contained.
CPA_STARTUP_BLOCKER = "pinned_cpa_unconditionally_starts_antigravity_version_updater"


def tree_hashes(directory):
    return {str(p.relative_to(directory)): build.digest(p)
            for p in sorted(directory.rglob("*")) if p.is_file()}


def prepare():
    provenance = json.loads((build.BUILD / "provenance.json").read_text())
    if (provenance["revision"] != build.REVISION or provenance["source_modified"]
            or provenance["archive_sha256"] != build.ARCHIVE_SHA256
            or provenance["executable_sha256"] != build.digest(build.BUILD / "cpa")):
        raise ValueError("unverified reference build")
    build.verify_source()
    if STAGE.exists():
        raise ValueError("target staging already exists; use a fresh build directory")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                       timeout=5).decode().strip()
    def verify_mimic_source():
        dirty = subprocess.check_output(["git", "diff", "HEAD", "--", "src", "vendor",
                                         "gleam.toml", "manifest.toml"], cwd=ROOT, timeout=5)
        if revision != BASE or dirty:
            raise ValueError("MIMIC source differs from supported assembled base")
    verify_mimic_source()
    # Build here, rather than trusting a potentially stale pre-existing shipment
    # and merely stamping it with the current source revision.
    build_argv = [shutil.which("mise") or "/missing/mise", "exec", "gleam@1.18.1",
                  "--", "gleam", "export", "erlang-shipment"]
    build_env = {key: value for key, value in os.environ.items()
                 if key in ("PATH", "HOME", "MISE_DATA_DIR")}
    build.command(build_argv, build_env, "mimic-export.log", cwd=ROOT)
    verify_mimic_source()
    STAGE.mkdir(mode=0o700)
    shutil.copyfile(build.BUILD / "cpa", STAGE / "cpa")
    (STAGE / "cpa").chmod(0o700)
    shipment = ROOT / "build/erlang-shipment"
    if not (shipment / "mimic/ebin/mimic.beam").is_file():
        raise ValueError("export the real MIMIC shipment first")
    # Explicit artifact extensions: no .git/.jj/source/operator state/cache.
    for source in shipment.glob("*/ebin/*"):
        if source.suffix not in (".beam", ".app") or source.is_symlink():
            continue
        dest = STAGE / "mimic" / source.relative_to(shipment)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
    manifest = {
        "schema": "mimic.reference-targets/v1", "cpa_revision": build.REVISION,
        "mimic_revision": revision, "files": tree_hashes(STAGE),
        "build_provenance_sha256": build.digest(build.BUILD / "provenance.json"),
        "mimic_build_argv": build_argv,
        "erl": str(Path(shutil.which("erl")).resolve()),
    }
    manifest_path = build.BUILD / "targets.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    config = {name: {
        "argv": [sys.executable, str(Path(__file__).resolve()), "--targets", str(manifest_path)],
        "revision": revision if name == "mimic" else build.REVISION,
    } for name in ("mimic", "cpa")}
    (build.BUILD / "drivers.json").write_text(json.dumps(config, indent=2) + "\n")
    print(build.BUILD / "drivers.json")


def validate_plan(plan):
    fixture = json.loads(plan["fixture_json"])
    if (plan["schema_version"] != 1 or fixture["schema_version"] != 1
            or plan["cpa_revision"] != build.REVISION
            or fixture["cpa_revision"] != build.REVISION
            or fixture["provenance"] != "synthetic"
            or hashlib.sha256(plan["fixture_json"].encode()).hexdigest() != plan["fixture_sha256"]):
        raise ValueError("stale/non-synthetic fixture")
    if plan["target"] not in ("cpa", "mimic"):
        raise ValueError("unknown target")
    revision = plan["target_revision"]
    valid_mimic = revision == BASE or (
        revision.startswith("candidate-sha256:")
        and candidate.HEX.fullmatch(revision.removeprefix("candidate-sha256:")) is not None)
    if (plan["target"] == "cpa" and revision != build.REVISION
            or plan["target"] == "mimic" and not valid_mimic):
        raise ValueError("target revision mismatch")
    if plan["phase"] not in ("exercise", "restart"):
        raise ValueError("unknown phase")
    supported = SUPPORTED.get(plan["capability_id"])
    if supported is None:
        return fixture, False
    expected_id, protocol = supported
    if ((plan["provider"], plan["auth_mode"], plan["input_protocol"], plan["upstream_mode"])
            != ("claude", "api_key", protocol, "messages_native")
            or fixture["id"] != expected_id):
        raise ValueError("capability/fixture binding mismatch")
    expected = (ROOT / "test/parity/fixtures" / (expected_id + ".json")).read_text()
    if plan["fixture_json"] != expected:
        raise ValueError("unsupported fixture revision/checks")
    return fixture, plan["phase"] == "exercise"


def validate_targets(path):
    raw = Path(path).read_bytes()
    manifest = json.loads(raw, object_pairs_hook=candidate.unique_object)
    if manifest["schema"] == "mimic.reference-targets/v2":
        manifest["_stage"] = candidate.validate_targets(path, manifest)
        manifest["_verified_manifest_sha256"] = hashlib.sha256(raw).hexdigest()
        return manifest
    if (manifest["schema"] != "mimic.reference-targets/v1"
            or manifest["cpa_revision"] != build.REVISION
            or manifest["mimic_revision"] != BASE
            or manifest["files"] != tree_hashes(STAGE)
            or manifest["build_provenance_sha256"] != build.digest(build.BUILD / "provenance.json")):
        raise ValueError("stale/partial target artifacts")
    provenance = json.loads((build.BUILD / "provenance.json").read_text())
    if (provenance["executable_sha256"] != build.digest(STAGE / "cpa")
            or provenance["revision"] != build.REVISION
            or provenance["source_modified"]
            or provenance["archive_sha256"] != build.ARCHIVE_SHA256):
        raise ValueError("fake or modified reference artifact")
    manifest["_verified_manifest_sha256"] = hashlib.sha256(raw).hexdigest()
    manifest["_stage"] = STAGE
    return manifest


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_ready(child, number):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError("actual target exited before readiness")
        try:
            with socket.create_connection(("127.0.0.1", number), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("actual target readiness deadline")


def cpa_config(directory, number, origin):
    # JSON is valid YAML. Pin custom API-key model; no OAuth accounts exist.
    return {
        "config-version": 8,
        "server": {"host": "127.0.0.1", "port": number, "discovery": {"enabled": False}},
        "management": {"secret-key": "", "disable-control-panel": True,
                       "disable-auto-update-panel": True},
        "access": {"api-keys": ["synthetic-client-key"]},
        "oauth": {"auth-dir": str(directory / "auth")},
        "api-keys": {"claude": [{
            "name": "synthetic-only", "base-url": origin, "request-retry": 0,
            "models": [{"name": "synthetic-model", "alias": "synthetic-model"}],
            "keys": [{"api-key": "synthetic-upstream-a", "cloak": {"mode": "never"}}],
        }]},
        "routing": {"retry": {"request-retry": 0}},
        "observability": {"logs": {"debug": False, "logging-to-file": False},
                          "usage": {"statistics-enabled": False}},
    }


def launch(plan, origin, manifest):
    if plan["target"] == "cpa" and CPA_STARTUP_BLOCKER:
        raise RuntimeError(CPA_STARTUP_BLOCKER)
    if (plan["target_revision"].startswith("candidate-sha256:")
            or manifest.get("candidate_manifest_sha256")):
        candidate.require_descendant_containment()
    state = Path(plan["state_dir"]).resolve()
    # Runner owns a fresh per-target state directory. Never accept a source/home
    # directory as a sandbox exception, even from a hand-written plan.
    results = (ROOT / "build/parity-results").resolve()
    if not state.is_relative_to(results) or state == results:
        raise ValueError("state must be private runner-owned build/parity-results descendant")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = state / "reference-runtime"
    directory.mkdir(mode=0o700)  # no silent reuse/reseed on exercise
    number = port()
    upstream = urlsplit(origin)
    if upstream.scheme != "http" or upstream.hostname != "127.0.0.1":
        raise ValueError("nonlocal fixture origin")
    for name in ("home", "tmp"):
        (directory / name).mkdir(mode=0o700)
    boundary = sandbox.LaunchPolicy(directory, sandbox.policy(directory, number, upstream.port))
    containment = sandbox.probe(boundary, ROOT / "AGENTS.md")
    log_path = directory / "target.log"
    log = log_path.open("wb")
    child = None
    try:
        if plan["target"] == "cpa":
            shutil.copyfile(manifest["_stage"] / "cpa", directory / "cpa")
            (directory / "cpa").chmod(0o700)
            config = directory / "config.yaml"
            config.write_text(json.dumps(cpa_config(directory, number, origin)))
            child = sandbox.start(boundary, [str(directory / "cpa"), "-config", str(config),
                                              "-local-model"], log)
        else:
            shutil.copytree(manifest["_stage"] / "mimic", directory / "shipment")
            (directory / "state").mkdir(mode=0o700)
            command = [manifest["erl"], "+S", "2:2", "-noshell", "-pa",
                       *map(str, sorted((directory / "shipment").glob("*/ebin"))),
                       "-eval", "'mimic@@main':run(mimic).", "-extra"]
            config = directory / "providers.json"
            config.write_text(json.dumps({
                "version": 1, "state_dir": str(directory / "state"), "listen_port": number,
                "accounts": [{"provider": "claude", "auth_mode": "api_key", "id": "synthetic",
                              "origin": origin, "models": ["synthetic-model"]}],
            }))
            client = directory / "client"
            credential = directory / "credential"
            client.write_text("synthetic-client-key")
            credential.write_text('{"api_key":"synthetic-upstream-a"}')
            for private in (client, credential, config):
                private.chmod(0o600)
            for args in (["key", "import", str(config), "synthetic", str(client)],
                         ["credential", "import", str(config), "synthetic", str(credential)]):
                child = sandbox.start(boundary, command + ["providers", *args], log)
                try:
                    if child.wait(timeout=8) != 0:
                        raise RuntimeError("gateway CLI provisioning failed")
                finally:
                    sandbox.stop(child)
            child = sandbox.start(boundary, command + ["providers", "serve", str(config)], log)
        wait_ready(child, number)
        (directory / "execution.json").write_text(json.dumps({
            "target": plan["target"], "pid": child.pid, "containment": containment,
            "target_manifest_sha256": manifest["_verified_manifest_sha256"],
            "launch_policy_sha256": boundary.sha256,
            "base_revision": manifest.get("base_revision", BASE),
            "candidate_manifest_sha256": manifest.get("candidate_manifest_sha256"),
            "live_provider": False, "fixture_sha256": plan["fixture_sha256"],
        }, indent=2))
        return child, {"port": number, "pid": child.pid}
    except BaseException:
        if child is not None:
            sandbox.stop(child)
        raise
    finally:
        log.close()


def run(plan, targets):
    fixture, supported = validate_plan(plan)
    checks = {name: False for name in fixture["required_checks"]}
    checks["assembled_ingress"] = False
    observations, diagnostics = {}, {"live_provider": False}
    status = "unsupported"
    if supported:
        manifest = validate_targets(targets)
        if plan["target"] == "mimic" and plan["target_revision"] != manifest["mimic_revision"]:
            raise ValueError("plan is bound to a different candidate/base shipment")
        diagnostics.update({
            "base_revision": manifest.get("base_revision", BASE),
            "candidate_manifest_sha256": manifest.get("candidate_manifest_sha256"),
        })
        if plan["target"] == "cpa" and CPA_STARTUP_BLOCKER:
            diagnostics["blocker"] = CPA_STARTUP_BLOCKER
            return result(plan, fixture, "failed", observations, checks, diagnostics)
        if manifest.get("candidate_manifest_sha256") and candidate.DESCENDANT_CONTAINMENT_BLOCKER:
            diagnostics["blocker"] = candidate.DESCENDANT_CONTAINMENT_BLOCKER
            return result(plan, fixture, "failed", observations, checks, diagnostics)
        try:
            observations, checks, extra = local_driver.exercise(
                plan, fixture, lambda p, origin: launch(p, origin, manifest))
            diagnostics.update(extra)
            status = "passed" if all(checks.get(n) is True for n in
                                    [*fixture["required_checks"], "assembled_ingress"]) else "failed"
        except (OSError, RuntimeError, ValueError, TimeoutError) as exc:
            # No arbitrary exception strings containing credentials/request bytes.
            diagnostics["blocker_type"] = type(exc).__name__
            status = "failed"
    return result(plan, fixture, status, observations, checks, diagnostics)


def result(plan, fixture, status, observations, checks, diagnostics):
    return {
        "schema_version": 1, "capability_id": plan["capability_id"],
        "fixture_id": fixture["id"], "fixture_sha256": plan["fixture_sha256"],
        "target": plan["target"], "target_revision": plan["target_revision"],
        "phase": plan["phase"], "status": status,
        "observations": local_driver.encode(observations),
        "checks": [{"name": n, "passed": v} for n, v in checks.items()],
        "diagnostics": diagnostics,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare", action="store_true")
    mode.add_argument("--candidate-acquire", action="store_true")
    parser.add_argument("--candidate-manifest", type=Path)
    parser.add_argument("--candidate-sha256")
    parser.add_argument("--candidate-source", type=Path)
    parser.add_argument("--targets", type=Path, default=build.BUILD / "targets.json")
    parser.add_argument("plan", nargs="?")
    args = parser.parse_args(argv)
    candidate_args = (args.candidate_manifest, args.candidate_sha256, args.candidate_source)
    if any(candidate_args) or args.candidate_acquire:
        if not all(candidate_args) or not (args.prepare or args.candidate_acquire) or args.plan:
            parser.error("candidate mode requires all three candidate flags and --prepare or --candidate-acquire")
        output = candidate.prepare(*candidate_args, acquire=args.candidate_acquire)
        if args.prepare:
            manifest = validate_targets(output)
            config = {name: {
                "argv": [sys.executable, str(Path(__file__).resolve()), "--targets", str(output)],
                "revision": manifest["mimic_revision"] if name == "mimic" else build.REVISION,
            } for name in ("mimic", "cpa")}
            output = output.with_name("drivers.json")
            output.write_text(json.dumps(config, indent=2) + "\n")
        print(output)
    elif args.prepare:
        prepare()
    else:
        with open(args.plan, encoding="utf-8") as source:
            print(local_driver.encode(run(json.load(source), args.targets)))


if __name__ == "__main__":
    main()
