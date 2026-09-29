#!/usr/bin/env python3
"""Live authorization preflight; execution stays blocked pending budget/egress enforcement."""

import argparse
import json
from pathlib import Path
import stat
from urllib.parse import urlsplit

REQUIRED = {"approved_by", "account_label", "endpoint", "model", "allowed_data",
            "max_requests", "max_input_tokens", "max_output_tokens",
            "max_cost_usd", "max_seconds"}


def validate(approval):
    if not isinstance(approval, dict) or set(approval) != REQUIRED:
        return "approval_fields_invalid"
    if any(not isinstance(approval[name], str) or not approval[name].strip()
           for name in ["approved_by", "account_label", "endpoint", "model"]):
        return "approval_identity_invalid"
    url = urlsplit(approval["endpoint"])
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment):
        return "explicit_https_endpoint_required"
    if approval["allowed_data"] != "synthetic-only":
        return "only_synthetic_test_data_supported"
    for name in ["max_requests", "max_input_tokens", "max_output_tokens", "max_seconds"]:
        if type(approval[name]) is not int or approval[name] <= 0:
            return "positive_integer_budgets_required"
    if type(approval["max_cost_usd"]) not in (int, float) or not (
            0 < approval["max_cost_usd"] <= 1):
        return "positive_cost_ceiling_at_most_one_dollar_required"
    return None


def preflight(approval_path=None, execute=False):
    result = {"schema": "mimic.native-clients/v1", "evidence_class": "real-provider/live",
              "status": "not_run", "requests_sent": 0, "credentials_read": False}
    if not execute:
        result["reason"] = "explicit_execution_opt_in_absent"
        return result
    result["status"] = "blocked"
    if approval_path is None:
        result["reason"] = "specific_operator_approval_required"
        return result
    # Only approval metadata is read. Never inspect ambient credentials or HOME.
    try:
        path = Path(approval_path)
        if path.is_symlink() or stat.S_IMODE(path.stat().st_mode) & 0o077:
            result["reason"] = "approval_must_be_private_regular_file"
            return result
        if not path.is_file() or path.stat().st_size > 4096:
            result["reason"] = "approval_file_invalid"
            return result
        error = validate(json.loads(path.read_text()))
    except (OSError, ValueError, TypeError):
        error = "approval_file_invalid"
    result["reason"] = error or "live_egress_and_token_cost_budget_enforcement_not_implemented"
    # An approval file alone is not human authorization. Specific authorization
    # in the thread and a reviewed enforcement adapter are both still required.
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--approval", type=Path)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    result = preflight(args.approval, args.execute)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 2 if result["status"] == "blocked" else 0


if __name__ == "__main__":
    raise SystemExit(main())
