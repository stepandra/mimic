"""Explicit process/network-free harness suite. Not runtime or parity evidence."""
from contextlib import ExitStack, contextmanager
import json
import os
import sys
import unittest
from unittest.mock import patch

MODULES = (
    "test_candidate", "test_candidate_dependencies", "test_reference_driver",
    "test_http_provider_driver",
)


def suite():
    return unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(name) for name in MODULES)


@contextmanager
def execution_guards():
    # Audit events also cover saved aliases/process replacement and connectionless
    # socket operations. This is accident protection for trusted Python tests,
    # not an OS sandbox for adversarial native extensions.
    enabled = [True]
    def audit(event, arguments):
        if enabled[0] and (
                event.startswith("socket.") or event in (
                    "subprocess.Popen", "os.system", "os.exec", "os.fork",
                    "os.forkpty", "os.posix_spawn")):
            raise AssertionError("safe unit suite forbids process/network audit event: " + event)
    sys.addaudithook(audit)
    def forbidden(*args, **kwargs):
        raise AssertionError("safe unit suite forbids process execution and network activity")
    try:
        with ExitStack() as guards:
            for name in ("subprocess.Popen", "os.system", "socket.socket.connect",
                         "socket.socket.connect_ex", "socket.socket.bind", "socket.getaddrinfo"):
                guards.enter_context(patch(name, side_effect=forbidden))
            for name in ("fork", "posix_spawn", "posix_spawnp"):
                if hasattr(os, name):
                    guards.enter_context(patch("os." + name, side_effect=forbidden))
            yield
    finally:
        enabled[0] = False


def main():
    with execution_guards():
        result = unittest.TextTestRunner(verbosity=2).run(suite())
    print(json.dumps({
        "evidence_class": "harness-unit", "tests": result.testsRun,
        "status": "passed" if result.wasSuccessful() else "failed",
        "candidate_build": "not_run", "candidate_runtime": "not_run",
        "cpa_execution": "not_run", "live_verified": "not_run",
    }, separators=(",", ":")))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
