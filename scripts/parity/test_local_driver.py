"""Compatibility placeholder: real target tests moved out of unit discovery.

Explicit local integration, only when authorized:
    python3 scripts/parity/integration_local_driver.py

Do not import that TestCase here: unittest would discover and execute it.
"""
import json


if __name__ == "__main__":
    print(json.dumps({
        "evidence_class": "local-target-integration", "status": "not_run",
        "reason": "select scripts/parity/integration_local_driver.py explicitly",
        "candidate_execution": "not_run", "cpa_execution": "not_run",
    }))
    raise SystemExit(1)
