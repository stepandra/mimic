#!/usr/bin/env python3
"""Run synthetic native-QA unit contracts, never acquisition or native clients."""

import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def main():
    denied = []

    def audit(event, args):
        forbidden = event == "subprocess.Popen" or event.startswith((
            "os.exec", "os.spawn", "os.posix_spawn", "os.fork", "os.system",
        ))
        if event in {"socket.bind", "socket.connect", "socket.sendto"}:
            address = args[1]
            forbidden = not (
                isinstance(address, tuple) and address[0] == "127.0.0.1"
            )
        if event == "socket.getaddrinfo":
            forbidden = args[0] != "127.0.0.1"
        if event.startswith(("socket.gethostby", "socket.getnameinfo")):
            forbidden = True
        if forbidden:
            denied.append(event)
            raise AssertionError("native contract test attempted prohibited operation")

    # A regression guard around trusted unit tests, not a native-code sandbox.
    # Real clients require the separately reviewed container/egress boundary.
    sys.addaudithook(audit)
    directory = ROOT / "build/integration/native-contracts"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory) as private:
        os.chmod(private, 0o700)
        with (
            patch.dict(os.environ, {"TMPDIR": private, "PYTHONDONTWRITEBYTECODE": "1"}),
            patch.object(tempfile, "tempdir", private),
            patch.object(socket, "getfqdn", return_value="localhost"),
        ):
            suite = unittest.defaultTestLoader.discover(
                str(ROOT / "test/native_clients"), pattern="test_*.py"
            )
            result = unittest.TextTestRunner(verbosity=2).run(suite)
    passed = result.wasSuccessful() and result.testsRun > 0 and not denied and not result.skipped
    print(json.dumps({
        "scope": "native_client_unit_contracts",
        "tests": result.testsRun,
        "passed": passed,
        "synthetic": True,
        "native_client_executions": 0,
        "live_provider": False,
    }))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
