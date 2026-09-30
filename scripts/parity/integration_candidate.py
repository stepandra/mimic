"""Explicit candidate build integration selector; never discovered by unit tests.

No flag overrides a containment blocker. With no --run this reports not_run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

import candidate


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args(argv)
    status, reason = "not_run", "explicit --run required"
    if args.run:
        if candidate.DESCENDANT_CONTAINMENT_BLOCKER:
            status, reason = "blocked", candidate.DESCENDANT_CONTAINMENT_BLOCKER
        else:
            # Retained minimal compiler integration, reachable only after a
            # reviewed containment backend exists and the operator opts in.
            root = candidate.build.BUILD / "candidate-integration"
            root.mkdir(parents=True, exist_ok=True, mode=0o700)
            attempt = Path(tempfile.mkdtemp(dir=root))
            source = attempt / "source"
            (source / "src").mkdir(parents=True)
            files = {"gleam.toml": 'name = "mimic"\nversion = "0.1.0"\n',
                     "manifest.toml": "packages = []\n[requirements]\n",
                     "src/mimic.gleam": "pub fn main() { Nil }\n"}
            for name, data in files.items():
                (source / name).write_text(data)
            manifest = {"files": {name: hashlib.sha256(data.encode()).hexdigest()
                                  for name, data in files.items()}}
            candidate.export(attempt, source)
            candidate.verify_source(source, manifest)
            if not (source / "build/erlang-shipment/mimic/ebin/mimic.beam").is_file():
                raise RuntimeError("fresh compiler output missing")
            status, reason = "passed", None
    print(json.dumps({"evidence_class": "candidate-build-integration", "status": status,
                      "reason": reason, "cpa_execution": "not_run", "live_verified": "not_run"}))
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
