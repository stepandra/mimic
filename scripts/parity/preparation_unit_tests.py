"""Guarded F30–F34 preparation checks, never paired runtime/parity evidence."""
import json
import unittest

from safe_unit_tests import execution_guards


MODULES = (
    "test_f30_claude", "test_f31_codex", "test_f32_kimi",
    "test_f33_grok", "test_f34_devin",
)


def main():
    # Import the test modules inside the same process/network guard as execution.
    with execution_guards():
        tests = unittest.TestSuite(
            unittest.defaultTestLoader.loadTestsFromName(name) for name in MODULES
        )
        result = unittest.TextTestRunner(verbosity=2).run(tests)
    print(json.dumps({
        "evidence_class": "preparation-unit", "tests": result.testsRun,
        "status": "passed" if result.wasSuccessful() else "failed",
        "candidate_runtime": "not_run", "cpa_execution": "not_run",
        "native_client": "not_run", "live_verified": "not_run",
    }, separators=(",", ":")))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
