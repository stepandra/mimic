"""Explicit synthetic OS controls; no CPA or MIMIC target executable is run.

python3 scripts/parity/integration_reference.py --run --group seatbelt
Other groups `go-env` and `same-pgid` remain separately selected. Same-PGID
cleanup is NOT detached-descendant containment.
"""
import argparse
import json
from pathlib import Path
import platform
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import reference_build as build
import reference_driver as driver
import reference_sandbox as sandbox


class GoEnvironmentTest(unittest.TestCase):
    def test_persisted_go_overlay_flags_are_not_honored(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(build, "BUILD", Path(temp)):
            go, env = build.environment()
            config_env = dict(env)
            config_env.pop("GOENV")
            config = Path(subprocess.check_output(
                [str(go), "env", "GOENV"], env=config_env, timeout=5).decode().strip())
            self.assertTrue(config.is_relative_to(temp))
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text("GOFLAGS=-overlay=/synthetic-not-executed.json\n")
            flags = subprocess.check_output([str(go), "env", "GOFLAGS"], env=env, timeout=5)
            self.assertEqual(flags.strip(), b"")
            self.assertEqual(env["GOENV"], "off")


class SameProcessGroupTest(unittest.TestCase):
    def test_same_pgid_cleanup_after_leader_exit_or_term(self):
        for leader_exits in (True, False):
            code = (
                "import os,signal,time\n"
                "pid=os.fork()\n"
                "if pid == 0:\n"
                " signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                " print(os.getpid(),flush=True)\n"
                " time.sleep(30)\n"
                "else:\n"
                + (" os._exit(0)\n" if leader_exits else " time.sleep(30)\n")
            )
            with self.subTest(leader_exits=leader_exits):
                child = subprocess.Popen([sys.executable, "-c", code],
                                         stdout=subprocess.PIPE, start_new_session=True)
                try:
                    with selectors.DefaultSelector() as selector:
                        selector.register(child.stdout, selectors.EVENT_READ)
                        self.assertTrue(selector.select(3))
                        descendant = int(child.stdout.readline())
                    if leader_exits:
                        child.wait(timeout=3)
                    sandbox.stop(child)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        status = subprocess.run(["ps", "-p", str(descendant), "-o", "stat="],
                                                capture_output=True, timeout=2)
                        if status.returncode != 0 or status.stdout.strip().startswith(b"Z"):
                            break
                        time.sleep(0.05)
                    else:
                        self.fail("same-PGID descendant survived cleanup")
                finally:
                    sandbox.stop(child)


class SeatbeltTest(unittest.TestCase):
    def test_provisioning_to_provisioning_to_server_keeps_policy_and_code_immutable(self):
        root = driver.ROOT / "build/parity-results"
        root.mkdir(exist_ok=True, parents=True)
        with tempfile.TemporaryDirectory(dir=root) as temp:
            directory = Path(temp).resolve()
            boundary = sandbox.LaunchPolicy(directory, sandbox.policy(directory, 43217, 43218))
            sandbox.probe(boundary, driver.ROOT / "AGENTS.md")
            shipment = directory / "shipment/mimic/ebin/mimic.beam"
            shipment.parent.mkdir(parents=True)
            shipment.write_bytes(b"synthetic-marker-not-executable")
            execution = directory / "execution.json"
            execution.write_text('{"synthetic":true}')
            protected = [directory / "sandbox.sb", directory / "containment.json", execution, shipment]
            original = [path.read_bytes() for path in protected]
            state = directory / "state"
            state.mkdir(mode=0o700)
            # A child-writable alias must not make immutable code writable.
            alias = state / "shipment-alias"
            alias.symlink_to(shipment)
            for phase in ("provision-client", "provision-account"):
                child = subprocess.Popen(
                    sandbox.argv(boundary, ["/usr/bin/tee", *map(str, [*protected, alias])]),
                    cwd=directory, env=sandbox.environment(directory),
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                try:
                    child.communicate(b"(version 1)(allow default)\n", timeout=5)
                    self.assertNotEqual(child.returncode, 0, phase)
                    self.assertEqual([path.read_bytes() for path in protected], original)
                finally:
                    sandbox.stop(child)
            # A third launch reads original staged bytes using the same parent
            # policy. No candidate program is executed in this synthetic test.
            server = subprocess.run(sandbox.argv(boundary, ["/bin/cat", str(shipment)]),
                                    cwd=directory, env=sandbox.environment(directory),
                                    capture_output=True, timeout=5)
            self.assertEqual(server.returncode, 0)
            self.assertEqual(server.stdout, original[-1])
            # Even a parent-side edit of the audit copy cannot affect launch.
            (directory / "sandbox.sb").write_text("(version 1)(allow default)")
            denied = subprocess.run(
                sandbox.argv(boundary, ["/bin/cat", str(driver.ROOT / "AGENTS.md")]),
                cwd=directory, env=sandbox.environment(directory), capture_output=True, timeout=5)
            self.assertNotEqual(denied.returncode, 0)
            self.assertEqual(denied.stdout, b"")
            writable = subprocess.run(
                sandbox.argv(boundary, ["/usr/bin/tee", str(state / "synthetic-state")]),
                input=b"synthetic", cwd=directory, env=sandbox.environment(directory),
                capture_output=True, timeout=5)
            self.assertEqual(writable.returncode, 0)
            self.assertEqual((state / "synthetic-state").read_bytes(), b"synthetic")

    def test_private_read_and_unapproved_listening_port_are_denied(self):
        root = driver.ROOT / "build/parity-results"
        root.mkdir(exist_ok=True, parents=True)
        with tempfile.TemporaryDirectory(dir=root) as temp:
            directory = Path(temp).resolve()
            with socket.socket() as upstream, socket.socket() as ingress:
                upstream.bind(("127.0.0.1", 0))
                upstream.listen(1)
                upstream.settimeout(2)
                ingress.bind(("127.0.0.1", 0))
                boundary = sandbox.LaunchPolicy(directory, sandbox.policy(
                    directory, ingress.getsockname()[1], upstream.getsockname()[1]))
                self.assertTrue(all(sandbox.probe(boundary, driver.ROOT / "AGENTS.md").values()))
                child = subprocess.Popen(sandbox.argv(boundary, [
                    "/usr/bin/curl", "--noproxy", "*", "--max-time", "2",
                    f"http://127.0.0.1:{upstream.getsockname()[1]}/",
                ]), cwd=directory, env=sandbox.environment(directory),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    connection, _ = upstream.accept()
                    with connection:
                        connection.recv(1024)
                        connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                    stdout, stderr = child.communicate(timeout=3)
                    self.assertEqual(child.returncode, 0, stderr)
                    self.assertEqual(stdout, b"ok")
                finally:
                    sandbox.stop(child)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--group", choices=("seatbelt", "go-env", "same-pgid"), default="seatbelt")
    args = parser.parse_args(argv)
    status, reason = "not_run", "explicit --run required"
    if args.run:
        if args.group == "seatbelt" and platform.system() != "Darwin":
            status, reason = "blocked", "macOS Seatbelt unavailable"
        elif args.group == "go-env" and not shutil.which("go"):
            status, reason = "blocked", "Go unavailable"
        else:
            case = {"seatbelt": SeatbeltTest, "go-env": GoEnvironmentTest,
                    "same-pgid": SameProcessGroupTest}[args.group]
            result = unittest.TextTestRunner(verbosity=2).run(
                unittest.defaultTestLoader.loadTestsFromTestCase(case))
            status, reason = ("passed" if result.wasSuccessful() else "failed"), None
    print(json.dumps({"evidence_class": "synthetic-os-integration", "group": args.group,
                      "status": status, "reason": reason, "candidate_execution": "not_run",
                      "cpa_execution": "not_run", "detached_descendants": "unverified"}))
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
